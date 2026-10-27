import { EventEmitter } from "node:events";
import { describe, it, expect, vi } from "vitest";
import { NotificationBridge, grantBytes, notificationControl, type NotificationClientMessage, notificationCategories } from "./notifications.js";
import { generateEd25519Keypair, ed25519Sign, ed25519Verify } from "./pairing/crypto.js";
import type { RelayClient } from "./transport/relay_client.js";

class FakeRelay extends EventEmitter {
  frames: Record<string, unknown>[] = [];
  error: string | undefined;
  open = true;
  reply = true;
  isOpen() { return this.open; }
  send(line: string) {
    const frame = JSON.parse(line); this.frames.push(frame);
    if (this.reply) queueMicrotask(() => this.emit("message", JSON.stringify({ type: "notification_registration", in_reply_to: frame.id, ok: !this.error, error: this.error })));
  }
  sendControl(frame: object) { this.send(JSON.stringify(frame)); }
  typed() { return this as unknown as RelayClient; }
}
function setup() {
  const relay = new FakeRelay(), identity = generateEd25519Keypair(), phone = generateEd25519Keypair();
  const phoneId = Buffer.from(phone.publicKey).toString("base64"), peer = Buffer.from(identity.publicKey).toString("base64");
  let paired = true;
  const bridge = new NotificationBridge({ relay: () => relay.typed(), identity: () => identity, room: () => "room-one", paired: async key => paired && key === phoneId });
  const msg: Extract<NotificationClientMessage, { type: "notify_register" }> = { type: "notify_register", id: "phone-request", device_id: "device-1", token: "ab".repeat(32), environment: "production", categories: ["input_needed", "task_finished", "task_failed"], show_pane_name: false, expires_at: Math.floor(Date.now()/1000)+86400, signature: "" };
  msg.signature = Buffer.from(ed25519Sign(phone.secretKey, grantBytes(peer, phoneId, msg))).toString("base64");
  return { relay, identity, phone, phoneId, peer, bridge, msg, unpair: () => { paired = false; } };
}
const settle = async () => { await new Promise(resolve => setTimeout(resolve, 0)); };

describe("notification pairing grants", () => {
  it("derives authority from paired phone, forwards bilateral signatures and original request id", async () => {
    const s=setup(); const reply=await s.bridge.handle(s.phoneId,s.msg);
    expect(reply).toMatchObject({ok:true,in_reply_to:"phone-request"});
    const grant=s.relay.frames[0].grant as {phone:string;peer:string;pi_signature:string};
    expect(grant.phone).toBe(s.phoneId); expect(grant.peer).toBe(s.peer);
    expect(ed25519Verify(s.identity.publicKey,grantBytes(s.peer,s.phoneId,s.msg),Buffer.from(grant.pi_signature,"base64"))).toBe(true);
    expect(grantBytes(s.peer,s.phoneId,s.msg).toString()).toBe("remote-pi-notify-device-v1\n"+JSON.stringify([s.peer,s.phoneId,"device-1",s.msg.token,"production",s.msg.categories,false,s.msg.expires_at]));
  });
  it("accepts all eight categories and binds credential_needed into the phone signature", async () => {
    const s=setup();s.msg.categories=[...notificationCategories];s.msg.signature=Buffer.from(ed25519Sign(s.phone.secretKey,grantBytes(s.peer,s.phoneId,s.msg))).toString("base64");
    expect(notificationCategories).toHaveLength(8);expect((await s.bridge.handle(s.phoneId,s.msg)).ok).toBe(true);
    expect((await s.bridge.handle(s.phoneId,{...s.msg,categories:s.msg.categories.filter(c=>c!=="credential_needed")})).error).toBe("invalid_grant");
    expect((await s.bridge.handle(s.phoneId,{...s.msg,categories:[...s.msg.categories,"input_needed"]})).error).toBe("invalid_grant");
  });
  it("does not let relay key possession, stale pairing, or body target select a recipient", async () => {
    const s=setup();s.unpair();expect((await s.bridge.handle(s.phoneId,s.msg)).error).toBe("not_paired");expect(s.relay.frames).toHaveLength(0);
    const other=setup();expect((await other.bridge.handle(s.phoneId,s.msg)).error).toBe("not_paired");
  });
  it.each(["token","device_id","environment","categories","expires_at","show_pane_name"])("rejects phone-proof tampering with %s", async field => {
    const s=setup(); const tampered={...s.msg,[field]:({token:"cd".repeat(32),device_id:"other-device",environment:"sandbox",categories:["review_ready"],expires_at:s.msg.expires_at+1,show_pane_name:true} as Record<string,unknown>)[field]};
    expect((await s.bridge.handle(s.phoneId,tampered as typeof s.msg)).error).toBe("invalid_grant");expect(s.relay.frames).toHaveLength(0);
  });
  it("reports disabled APNs and never returns optimistic registration success", async () => {
    const s=setup();s.relay.error="apns_disabled";expect(await s.bridge.handle(s.phoneId,s.msg)).toMatchObject({ok:false,error:"apns_disabled"});
    s.relay.open=false;expect((await s.bridge.handle(s.phoneId,s.msg)).error).toBe("relay_unavailable");
  });
  it("times out older relays and ignores forged inner peer replies", async () => {
    vi.useFakeTimers();try {
      const relay=new FakeRelay();relay.reply=false;const pending=notificationControl(relay.typed(),{type:"notification_activity",active:true});const id=relay.frames[0].id;
      relay.emit("message",JSON.stringify({peer:"stranger",ct:Buffer.from(JSON.stringify({type:"notification_registration",in_reply_to:id,ok:true})).toString("base64")}));
      await vi.advanceTimersByTimeAsync(12001);expect(await pending).toMatchObject({ok:false,error:"notification_timeout"});expect(relay.listenerCount("message")).toBe(0);
    } finally {vi.useRealTimers();}
  });
  it("caps in-flight controls and cleans up on close", async () => {
    const relay=new FakeRelay();relay.setMaxListeners(100);relay.reply=false;
    const requests=Array.from({length:32},()=>notificationControl(relay.typed(),{type:"notification_event"}));
    expect((await notificationControl(relay.typed(),{})).error).toBe("rate_limited");relay.emit("close");expect((await Promise.all(requests)).every(r=>!r.ok)).toBe(true);expect(relay.listenerCount("message")).toBe(0);
  });
});
describe("notification event lifecycle", () => {
  it("an aborted prompt does not suppress completion of a later run", async () => {
    const s=setup();s.bridge.start();s.bridge.promptOpened("orphan");s.bridge.cancelled();s.bridge.end();await settle();
    expect(s.relay.frames.some(f=>f.kind==="task_finished")).toBe(false);
    s.bridge.start();s.bridge.end();await settle();
    expect(s.relay.frames.some(f=>f.kind==="task_finished")).toBe(true);
  });
  it("notifies generic native UI waits without exposing titles and resumes completion after answer", async () => {
    const s=setup();
    const handlers=new Map<string,(e: {kind?:string;title?:string})=>void>();
    s.bridge.registerTool({on:(name:string,fn:any)=>handlers.set(name,fn),registerCommand:()=>{},registerTool:()=>{}} as any);
    s.bridge.start();
    handlers.get("ui_prompt_start")!({kind:"confirm",title:"DO NOT SHARE THIS TITLE"});
    await settle();
    expect(s.relay.frames.some(f=>f.kind==="input_needed")).toBe(true);
    expect(JSON.stringify(s.relay.frames)).not.toContain("DO NOT SHARE");
    handlers.get("ui_prompt_end")!({kind:"confirm"});
    s.bridge.end();await settle();
    expect(s.relay.frames.some(f=>f.kind==="task_finished")).toBe(true);
  });
  it("emits one completion on agent run end, never per tool invocation", async () => {
    const s=setup();s.bridge.start();s.bridge.end();s.bridge.end();await settle();
    expect(s.relay.frames.filter(f=>f.type==="notification_event").map(f=>f.kind)).toEqual(["task_finished"]);
  });
  it.each(["input_needed","credential_needed","task_failed"] as const)("does not announce success while %s", async kind => {
    const s=setup();s.bridge.start();await s.bridge.emit(kind);s.bridge.end();await settle();
    expect(s.relay.frames.filter(f=>f.type==="notification_event").map(f=>f.kind)).toEqual([kind]);
  });
  it("resolved asks no longer suppress completion or a subsequent terminal error", async () => {
    const done=setup();done.bridge.start();done.bridge.promptOpened("ask-1");await settle();done.bridge.promptResolved("ask-1");done.bridge.end();await settle();
    expect(done.relay.frames.filter(f=>f.type==="notification_event").map(f=>f.kind)).toEqual(["input_needed","task_finished"]);
    const failed=setup();failed.bridge.start();failed.bridge.promptOpened("ask-2");await settle();failed.bridge.promptResolved("ask-2");failed.bridge.observeAssistant("error");failed.bridge.end();await settle();
    expect(failed.relay.frames.filter(f=>f.type==="notification_event").map(f=>f.kind)).toEqual(["input_needed","task_failed"]);
  });
  it("unresolved asks suppress success but cannot hide a terminal failure", async () => {
    const waiting=setup();waiting.bridge.start();waiting.bridge.promptOpened("pending");await settle();waiting.bridge.end();await settle();
    expect(waiting.relay.frames.filter(f=>f.type==="notification_event").map(f=>f.kind)).toEqual(["input_needed"]);
    const failed=setup();failed.bridge.start();failed.bridge.promptOpened("pending");await settle();failed.bridge.observeAssistant("error");failed.bridge.end();await settle();
    expect(failed.relay.frames.filter(f=>f.type==="notification_event").map(f=>f.kind)).toEqual(["input_needed","task_failed"]);
  });
  it("intentional transport pause clears relay activity without losing a still-running task", async () => {
    const s=setup();s.bridge.start();s.bridge.pauseTransport();s.bridge.restoreActivity();await settle();
    expect(s.relay.frames.filter(f=>f.type==="notification_activity").map(f=>f.active)).toEqual([true,false,true]);s.bridge.end();await settle();
    expect(s.relay.frames.filter(f=>f.type==="notification_event").map(f=>f.kind)).toEqual(["task_finished"]);
  });
  it("notifies only a terminal observed error, not an error recovered within the run", async () => {
    const s=setup();s.bridge.start();s.bridge.observeAssistant("error");await settle();expect(s.relay.frames.filter(f=>f.type==="notification_event")).toHaveLength(0);
    s.bridge.observeAssistant("stop");s.bridge.end();await settle();expect(s.relay.frames.filter(f=>f.type==="notification_event").map(f=>f.kind)).toEqual(["task_finished"]);
    const terminal=setup();terminal.bridge.start();terminal.bridge.observeAssistant("error");terminal.bridge.end();await settle();expect(terminal.relay.frames.filter(f=>f.type==="notification_event").map(f=>f.kind)).toEqual(["task_failed"]);
  });
  it("publishes leased real call activity while the agent is idle", async () => {
    const relay=new FakeRelay();let call=true;
    const bridge=new NotificationBridge({relay:()=>relay.typed(),identity:()=>null,room:()=>"r",paired:async()=>false,callActive:()=>call});
    bridge.restoreActivity();await settle();expect(relay.frames[0]).toMatchObject({active:true,lease_seconds:90});call=false;bridge.restoreActivity();await settle();expect(relay.frames[1]).toMatchObject({active:false});
  });
  it("does not announce success on aborted runs", async () => {
    const s=setup();s.bridge.start();s.bridge.cancelled();s.bridge.end();await settle();expect(s.relay.frames.filter(f=>f.type==="notification_event")).toHaveLength(0);
  });
  it("explicit review and verified test failures send only category and event ids", async () => {
    const s=setup();await s.bridge.emit("review_ready");await s.bridge.emit("tests_failed");
    for(const f of s.relay.frames) expect(Object.keys(f).sort()).toEqual(["event_id","id","kind","type"]);
  });
  it("explicit credential command rejects secret arguments and shows notice even when APNs disabled", async () => {
    const relay=new FakeRelay();relay.error="apns_disabled";const notice=vi.fn();let handler:((args:string,ctx:unknown)=>Promise<void>)|undefined;
    const bridge=new NotificationBridge({relay:()=>relay.typed(),identity:()=>null,room:()=>"room",paired:async()=>false,credentialNotice:notice});
    const api={registerTool:vi.fn(),registerCommand:(_name:string,options:{handler:typeof handler})=>{handler=options.handler;}};
    bridge.registerTool(api as unknown as import("@earendil-works/pi-coding-agent").ExtensionAPI);
    const notify=vi.fn(),ctx={ui:{notify}};await handler!("synthetic-secret-do-not-echo",ctx);expect(relay.frames).toHaveLength(0);expect(notice).not.toHaveBeenCalled();expect(JSON.stringify(notify.mock.calls)).not.toContain("synthetic-secret-do-not-echo");
    await handler!("",ctx);expect(notice).toHaveBeenCalledWith();expect(relay.frames[0]).toMatchObject({kind:"credential_needed"});expect(notify).toHaveBeenLastCalledWith(expect.stringContaining("Phone push is unavailable"),"warning");
  });
  it("deduplicates accepted events but never hides disabled transport errors", async () => {
    const s=setup();s.relay.error="apns_disabled";expect((await s.bridge.emit("input_needed")).ok).toBe(false);expect((await s.bridge.emit("input_needed")).ok).toBe(false);
    s.relay.error=undefined;await s.bridge.emit("input_needed");await s.bridge.emit("input_needed");expect(s.relay.frames).toHaveLength(3);
  });
});
