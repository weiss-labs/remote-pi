import { createHash } from "node:crypto";
import { mkdtemp, mkdir, writeFile, rm, symlink, truncate, link } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { afterEach, describe, expect, it, vi } from "vitest";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { ArtifactBridge, ARTIFACT_CHUNK_SIZE, ARTIFACT_MAX_SIZE, toolImageUrl, type ArtifactServerMessage } from "./artifacts.js";

const cleanups: Array<() => Promise<unknown> | void> = [];
afterEach(async () => { vi.useRealTimers(); for (const clean of cleanups.splice(0).reverse()) await clean(); });
function assistant(manager: SessionManager, text: string): string {
  return manager.appendMessage({ role: "assistant", content: [{ type: "text", text }], api: "openai-responses", provider: "synthetic", model: "synthetic", usage: { input:0, output:0, cacheRead:0, cacheWrite:0, totalTokens:0, cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0} }, stopReason: "stop", timestamp: 0 });
}
async function setup() {
  const dir = await mkdtemp(join(tmpdir(), "rp-artifact-test-"));
  cleanups.push(() => rm(dir, { recursive:true, force:true }));
  const root = join(dir,"allowed"); await mkdir(root);
  let manager: SessionManager | null = SessionManager.inMemory(root);
  const sender = {}, other = {}; let paired = true;
  let authHook: (() => Promise<boolean>) | undefined;
  const bridge = new ArtifactBridge({ roots:[root], session:() => manager, authorize:async (owner,s) => owner === "owner" && s === sender && paired && (authHook ? await authHook() : true) });
  cleanups.push(() => bridge.reset());
  const pdf = Buffer.concat([Buffer.from("%PDF-1.4\n"), Buffer.alloc(ARTIFACT_CHUNK_SIZE + 19, 65), Buffer.from("\n%%EOF\n")]);
  async function file(name = "report.pdf", data = pdf, directory = root) {
    const path = join(directory,name); await writeFile(path,data); return {path,url:pathToFileURL(path).href};
  }
  async function opened(url: string) {
    const reply = await bridge.handle("owner",sender,{type:"artifact_open",id:"open",url});
    expect(reply?.type).toBe("artifact_opened");
    return reply as Extract<ArtifactServerMessage,{type:"artifact_opened"}>;
  }
  return {dir,root,sender,other,bridge,pdf,file,opened,get manager(){return manager!;},switchSession(){manager=SessionManager.inMemory(root);},noSession(){manager=null;},unpair(){paired=false;},hook(fn:()=>Promise<boolean>){authHook=fn;}};
}
const isError = (reply: ArtifactServerMessage | null) => expect(reply).toMatchObject({type:"artifact_error",code:"unavailable"});
describe("assistant-linked bounded previews", () => {
  it("serves an image block from a tool result on the active branch, and nothing else", async () => {
    const s=await setup();
    const png=Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aG1cAAAAASUVORK5CYII=","base64");
    s.manager.appendMessage({role:"toolResult",toolCallId:"call|1",toolName:"screenshot",content:[{type:"text",text:"ok"},{type:"image",data:png.toString("base64"),mimeType:"image/png"},{type:"image",data:Buffer.from("not png").toString("base64"),mimeType:"image/png"}],isError:false,timestamp:0} as never);
    const o=await s.opened(toolImageUrl("call|1",1));
    expect(o).toMatchObject({mime:"image/png",size:png.length,name:"image-2.png",sha256:createHash("sha256").update(png).digest("hex")});
    const c=await s.bridge.handle("owner",s.sender,{type:"artifact_chunk",id:"c",transfer_id:o.transfer_id,offset:0});
    expect(Buffer.from((c as {data:string}).data,"base64")).toEqual(png);
    expect(c).toMatchObject({eof:true});
    for (const url of [toolImageUrl("call|1",0),toolImageUrl("call|1",2),toolImageUrl("other",1),"pi-tool-image:call%7C1/../1"]) isError(await s.bridge.handle("owner",s.sender,{type:"artifact_open",id:"x",url}));
    isError(await s.bridge.handle("owner",s.other,{type:"artifact_open",id:"y",url:toolImageUrl("call|1",1)}));
    s.switchSession(); isError(await s.bridge.handle("owner",s.sender,{type:"artifact_open",id:"z",url:toolImageUrl("call|1",1)}));
  });
  it("reads a real temporary PDF linked in the actual SDK active branch, with bounded chunks and a final hash", async () => {
    const s=await setup(), f=await s.file(); assistant(s.manager,`[PDF](${f.url})`);
    const opened=await s.opened(f.url);
    expect(opened).toMatchObject({name:"report.pdf",mime:"application/pdf",size:s.pdf.length,sha256:createHash("sha256").update(s.pdf).digest("hex")});
    const chunks: Buffer[]=[];
    for(let offset=0;offset<opened.size;offset+=ARTIFACT_CHUNK_SIZE){
      const r=await s.bridge.handle("owner",s.sender,{type:"artifact_chunk",id:`chunk-${offset}`,transfer_id:opened.transfer_id,offset});
      expect(r?.type).toBe("artifact_chunk"); const c=r as Extract<ArtifactServerMessage,{type:"artifact_chunk"}>;
      const bytes=Buffer.from(c.data,"base64");expect(bytes.length).toBeLessThanOrEqual(ARTIFACT_CHUNK_SIZE);expect(c.eof).toBe(offset+bytes.length===opened.size);chunks.push(bytes);
    }
    expect(Buffer.concat(chunks)).toEqual(s.pdf);
    await s.bridge.handle("owner",s.sender,{type:"artifact_close",id:"cancel",transfer_id:opened.transfer_id});
    isError(await s.bridge.handle("owner",s.sender,{type:"artifact_chunk",id:"after",transfer_id:opened.transfer_id,offset:0}));
  });
  it("fails closed without authoritative history, with only user/tool links, and with an inactive branch", async () => {
    const s=await setup(), f=await s.file();
    s.manager.appendMessage({role:"user",content:f.url,timestamp:0});
    s.manager.appendMessage({role:"toolResult",toolCallId:"t",toolName:"read",content:[{type:"text",text:f.url}],isError:false,timestamp:0});
    isError(await s.bridge.handle("owner",s.sender,{type:"artifact_open",id:"user",url:f.url}));
    const before=assistant(s.manager,"No link here");assistant(s.manager,f.url);s.manager.branch(before);
    isError(await s.bridge.handle("owner",s.sender,{type:"artifact_open",id:"branch",url:f.url}));
    s.noSession();isError(await s.bridge.handle("owner",s.sender,{type:"artifact_open",id:"missing",url:f.url}));
  });
  it("does not accept a prefix/subpath match or a URL only in a thinking/tool block", async () => {
    const s=await setup(),f=await s.file();assistant(s.manager,`${f.url}.png`);
    isError(await s.bridge.handle("owner",s.sender,{type:"artifact_open",id:"prefix",url:f.url}));
  });
  it.each([".hidden.pdf","password.pdf","credentials.pdf","api-key.pdf","id_rsa.pdf","AuthKey_synthetic.p8.pdf","pass\u200bword.pdf","config.pdf","report.txt"])("refuses hidden/secret/unsupported file %s even when assistant linked", async name => {
    const s=await setup(),f=await s.file(name);assistant(s.manager,f.url);
    const reply=await s.bridge.handle("owner",s.sender,{type:"artifact_open",id:"denied",url:f.url});isError(reply);expect(JSON.stringify(reply)).not.toContain(s.dir);
  });
  it("refuses root escape, symlink escape, hidden symlink destinations, hardlinks, directories, and oversized files", async () => {
    const s=await setup(),outside=await s.file("outside.pdf",s.pdf,s.dir),hidden=await s.file(".hidden.pdf");
    const escape=join(s.root,"escape.pdf"),alias=join(s.root,"alias.pdf");await symlink(outside.path,escape);await symlink(hidden.path,alias);
    const big=await s.file("big.pdf");await truncate(big.path,ARTIFACT_MAX_SIZE+1);
    const hard=join(s.root,"hard.pdf");await link(outside.path,hard);
    for(const path of [outside.path,escape,alias,hard,s.root,big.path]){
      const url=pathToFileURL(path).href;assistant(s.manager,url);
      isError(await s.bridge.handle("owner",s.sender,{type:"artifact_open",id:"denied",url}));
    }
  });
  it.each(["https://example.invalid/file.pdf","file://remotehost/allowed.pdf","file:///tmp/report.pdf?x=1","file:///tmp/report.pdf#secret"])("refuses nonlocal or decorated URLs %s", async url => {
    const s=await setup();assistant(s.manager,url);isError(await s.bridge.handle("owner",s.sender,{type:"artifact_open",id:"denied",url}));
  });
  it.each([
    ["pixel.png",Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aG1cAAAAASUVORK5CYII=","base64"),"image/png"],
    ["pixel.gif",Buffer.from("R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==","base64"),"image/gif"],
    ["pixel.jpg",Buffer.from([255,216,255,224,0,16,74,70,73,70,0,1]),"image/jpeg"],
    ["pixel.webp",Buffer.from("RIFFxxxxWEBPVP8 xxx"),"image/webp"],
    ["mockup.html",Buffer.from("\uFEFF\n  <!doctype html><p>hi</p>"),"text/html"],
    ["page.htm",Buffer.from("<html></html>"),"text/html"],
  ] as const)("requires matching image signatures for %s", async (name,data,mime) => {
    const s=await setup(),f=await s.file(name,data);assistant(s.manager,f.url);expect((await s.opened(f.url)).mime).toBe(mime);
    await writeFile(f.path,Buffer.from("not an image"));isError(await s.bridge.handle("owner",s.sender,{type:"artifact_open",id:"invalid",url:f.url}));
  });
  it("denies another owner, replacement channel and revoked pairing on every operation", async () => {
    const s=await setup(),f=await s.file();assistant(s.manager,f.url);const t=await s.opened(f.url);
    for(const type of ["artifact_open","artifact_chunk","artifact_close"] as const){
      const msg={type,id:"foreign",url:f.url,transfer_id:t.transfer_id,offset:0};
      isError(await s.bridge.handle("other-owner",s.sender,msg));isError(await s.bridge.handle("owner",s.other,msg));
    }
    s.unpair();isError(await s.bridge.handle("owner",s.sender,{type:"artifact_chunk",id:"revoked",transfer_id:t.transfer_id,offset:0}));
  });
  it.each([-1,0.5,NaN,Infinity,Number.MAX_SAFE_INTEGER])("rejects invalid chunk offset %s", async offset => {
    const s=await setup(),f=await s.file();assistant(s.manager,f.url);const t=await s.opened(f.url);
    isError(await s.bridge.handle("owner",s.sender,{type:"artifact_chunk",id:"bad-offset",transfer_id:t.transfer_id,offset}));
  });
  it("invalidates pinned reads after a same-size source mutation or replacement", async () => {
    const s=await setup(),f=await s.file();assistant(s.manager,f.url);const t=await s.opened(f.url);
    const changed=Buffer.from(s.pdf);changed[15]=66;await writeFile(f.path,changed);
    isError(await s.bridge.handle("owner",s.sender,{type:"artifact_chunk",id:"changed",transfer_id:t.transfer_id,offset:0}));
  });
  it.each(["reset","switch","branch","disconnect"])("invalidates transfers on %s",async mode=>{
    const s=await setup(),f=await s.file();const before=assistant(s.manager,"Before link");assistant(s.manager,f.url);const t=await s.opened(f.url);
    if(mode==="reset")s.bridge.reset();else if(mode==="switch")s.switchSession();else if(mode==="branch")s.manager.branch(before);else s.bridge.detach("owner");
    isError(await s.bridge.handle("owner",s.sender,{type:"artifact_chunk",id:"stale",transfer_id:t.transfer_id,offset:0}));
  });
  it("bounds handles, expires them and releases a canceled slot",async()=>{
    const s=await setup(),f=await s.file();assistant(s.manager,f.url);const handles=[];
    for(let i=0;i<4;i++)handles.push(await s.opened(f.url));
    isError(await s.bridge.handle("owner",s.sender,{type:"artifact_open",id:"fifth",url:f.url}));
    await s.bridge.handle("owner",s.sender,{type:"artifact_close",id:"close",transfer_id:handles[0].transfer_id});await s.opened(f.url);
    vi.useFakeTimers();vi.setSystemTime(Date.now()+120001);
    isError(await s.bridge.handle("owner",s.sender,{type:"artifact_chunk",id:"expired",transfer_id:handles[1].transfer_id,offset:0}));
  });
  it("bounds in-flight calls and cancels an opening read on session reset",async()=>{
    const s=await setup(),f=await s.file();assistant(s.manager,f.url);
    let release!:()=>void;const gate=new Promise<void>(r=>release=r);s.hook(async()=>{await gate;return true;});
    const pending=s.bridge.handle("owner",s.sender,{type:"artifact_open",id:"pending",url:f.url});
    const pending2=s.bridge.handle("owner",s.sender,{type:"artifact_open",id:"pending2",url:f.url});
    isError(await s.bridge.handle("owner",s.sender,{type:"artifact_open",id:"overflow",url:f.url}));s.bridge.reset();release();
    isError(await pending);isError(await pending2);
  });
  it("refuses a source mutation during hashing and a revoked or switched in-flight open",async()=>{
    for(const mode of ["mutate","revoke","switch"]){
      const s=await setup(),f=await s.file();assistant(s.manager,f.url);let count=0;
      s.hook(async()=>{if(++count===2){if(mode==="mutate")await writeFile(f.path,Buffer.concat([s.pdf,Buffer.from("changed")]));else if(mode==="revoke")s.unpair();else s.bridge.reset();}return true;});
      isError(await s.bridge.handle("owner",s.sender,{type:"artifact_open",id:"interrupted",url:f.url}));
    }
  });
  it("cancels a chunk while its post-read authorization is suspended",async()=>{
    const s=await setup(),f=await s.file();assistant(s.manager,f.url);const t=await s.opened(f.url);
    let count=0,release!:()=>void,entered!:()=>void;const gate=new Promise<void>(r=>release=r),atGate=new Promise<void>(r=>entered=r);
    s.hook(async()=>{if(++count===2){entered();await gate;}return true;});
    const pending=s.bridge.handle("owner",s.sender,{type:"artifact_chunk",id:"read",transfer_id:t.transfer_id,offset:0});await atGate;
    await s.bridge.handle("owner",s.sender,{type:"artifact_close",id:"close",transfer_id:t.transfer_id});release();isError(await pending);
  });
});
