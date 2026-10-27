import { describe, it, expect, vi } from "vitest";
import type { ExtensionAPI, ExtensionCommandContext } from "@earendil-works/pi-coding-agent";
import { NativeCommands, type CommandServerMessage, type CommandSender } from "./commands.js";

type Input = {text:string;source:"extension"};
type Handler = (args:string,ctx:ExtensionCommandContext)=>Promise<void>|void;
class FakeHost {
  commands: {name:string;description:string;source:"extension"|"skill"|"prompt"}[] = [];
  handlers = new Map<string,Handler>();
  inputs: ((e:Input)=>{action:"handled"}|undefined)[] = [];
  sent: {text:string;options:{expandPromptTemplates?:boolean;deliverAs?:string}}[] = [];
  modelInput: string[] = [];
  expanded: string[] = [];
  modern = true; hold = false; idle = true;
  reload = vi.fn(async()=>{}); confirm = vi.fn(async()=>false);
  ctx = {isIdle:()=>this.idle,hasPendingMessages:()=>false,reload:this.reload,ui:{confirm:this.confirm}} as unknown as ExtensionCommandContext;
  api = {
    registerCommand: (name:string,opts:{description:string;handler:Handler}) => {this.commands.push({name,description:opts.description,source:"extension"});this.handlers.set(name,opts.handler);},
    getCommands: ()=>this.commands.map(c=>({...c,sourceInfo:{path:"/private/never-send"}})),
    on: (_type:string,fn:(e:Input)=>{action:"handled"}|undefined)=>{this.inputs.push(fn);},
    sendUserMessage: (text:string,options:{expandPromptTemplates?:boolean;deliverAs?:string})=>{
      this.sent.push({text,options});if(this.hold)return;
      queueMicrotask(()=>{void this.dispatch(text,options);});
    },
  } as unknown as ExtensionAPI;
  async dispatch(text:string,options:{expandPromptTemplates?:boolean;deliverAs?:string}) {
    const name=text.slice(1).split(" ")[0],args=text.slice(name.length+2);
    if(this.modern&&options.expandPromptTemplates&&this.handlers.has(name)) {await this.handlers.get(name)!(args,this.ctx);return;}
    for(const hook of this.inputs) if(hook({text,source:"extension"})?.action==="handled")return;
    if(this.modern&&options.expandPromptTemplates&&this.commands.some(c=>c.name===name&&c.source!=="extension")) this.expanded.push(text);
    else this.modelInput.push(text);
  }
  add(name:string,handler:Handler=()=>{},source:"extension"|"skill"|"prompt"="extension") {
    this.commands.push({name,description:`Description of ${name}`,source});if(source==="extension")this.handlers.set(name,handler);
  }
}
function setup() {
  const host=new FakeHost(), replies:CommandServerMessage[]=[], sender:CommandSender={send:r=>{replies.push(r);}};
  let authorized=true,busy=false,provider="claude-bridge";
  const promptSubmitted=vi.fn();
  const bridge=new NativeCommands(host.api,{authorize:async()=>authorized,busy:()=>busy,provider:()=>provider,promptSubmitted});
  return {host,bridge,replies,sender,promptSubmitted,unpair:()=>{authorized=false;},busy:()=>{busy=true;host.idle=false;},provider:(p:string)=>{provider=p;}};
}
const settled=async()=>{await new Promise(r=>setTimeout(r,0));};
describe("live native Pi commands",()=>{
  it("lists live commands/descriptions without source paths and keeps provider aliases live",async()=>{
    const s=setup();s.host.add("claude-fast");s.host.add("codex-fast");s.host.add("skill:checkpointing-project-state",undefined,"skill");
    await s.bridge.handle("phone",s.sender,{type:"list_commands",id:"list1"});await settled();
    const first=s.replies[0];expect(first.type).toBe("commands_list");if(first.type!=="commands_list")return;
    expect(first.dispatch_supported).toBe(true);expect(first.commands.find(c=>c.name==="fast")).toMatchObject({available:true,source:"alias",busy_policy:"immediate"});
    expect(first.commands.find(c=>c.name==="checkpoint")).toMatchObject({available:true,busy_policy:"follow_up"});expect(JSON.stringify(first)).not.toContain("/private/");
    s.provider("openai-codex");s.host.add("new-command");await s.bridge.handle("phone",s.sender,{type:"list_commands",id:"list2"});await settled();
    const second=s.replies[1];if(second.type!=="commands_list")throw Error("list missing");expect(second.commands.some(c=>c.name==="new-command")).toBe(true);expect(second.commands.find(c=>c.name==="fast")?.description).toContain("/codex-fast");s.bridge.stop();
  });
  it("uses genuine registered handler dispatch with expansion enabled, never literal chat",async()=>{
    const s=setup(),run=vi.fn();s.host.add("claude-fast",run);
    await s.bridge.handle("phone",s.sender,{type:"command_execute",id:"fast1",name:"fast"});await settled();
    expect(run).toHaveBeenCalledTimes(1);expect(s.host.sent.at(-1)).toMatchObject({text:"/claude-fast",options:{expandPromptTemplates:true}});expect(s.host.modelInput).toEqual([]);
    expect(s.replies).toEqual([expect.objectContaining({status:"accepted",name:"fast"})]);s.bridge.stop();
  });
  it("older hosts consume private probes before any model input and report unsupported",async()=>{
    const s=setup();s.host.modern=false;s.host.add("claude-fast");
    await s.bridge.handle("phone",s.sender,{type:"list_commands",id:"old-list"});await settled();
    const list=s.replies[0];expect(list).toMatchObject({type:"commands_list",dispatch_supported:false});if(list.type==="commands_list")expect(list.commands.every(c=>!c.available)).toBe(true);
    await s.bridge.handle("phone",s.sender,{type:"command_execute",id:"old-exec",name:"fast"});await settled();expect(s.replies.at(-1)).toMatchObject({status:"rejected",code:"sdk_dispatch_unsupported"});expect(s.host.modelInput).toEqual([]);expect(s.host.sent).toHaveLength(1);s.bridge.stop();
  });
  it("reload calls native fresh command context, rejects busy, and deduplicates accepted requests",async()=>{
    const s=setup();s.busy();await s.bridge.handle("phone",s.sender,{type:"command_execute",id:"busy-reload",name:"reload"});await settled();expect(s.replies.at(-1)).toMatchObject({code:"busy",status:"rejected"});expect(s.host.reload).not.toHaveBeenCalled();s.bridge.stop();
    const idle=setup();await idle.bridge.handle("phone",idle.sender,{type:"command_execute",id:"reload1",name:"reload"});await settled();
    await idle.bridge.handle("phone",idle.sender,{type:"command_execute",id:"reload1",name:"reload"});await settled();expect(idle.host.reload).toHaveBeenCalledTimes(1);expect(idle.replies.every(r=>r.type==="command_result"&&r.status==="accepted")).toBe(true);expect(idle.host.modelInput).toEqual([]);idle.bridge.stop();
  });
  it("queues skill/template execution as native follow-up while busy without steering",async()=>{
    const s=setup();s.busy();s.host.add("skill:checkpointing-project-state",undefined,"skill");
    await s.bridge.handle("phone",s.sender,{type:"command_execute",id:"checkpoint1",name:"checkpoint",args:"save progress"});await settled();
    expect(s.host.sent.at(-1)).toMatchObject({text:"/skill:checkpointing-project-state save progress",options:{expandPromptTemplates:true,deliverAs:"followUp"}});expect(s.host.expanded).toHaveLength(1);expect(s.host.modelInput).toEqual([]);expect(s.promptSubmitted).not.toHaveBeenCalled();s.bridge.stop();
  });
  it("does not auto-approve or replace native command UI prompts",async()=>{
    const s=setup();let allowed:unknown;s.host.add("protected",async(_args,ctx)=>{allowed=await ctx.ui.confirm("Permission", "Allow?");});
    await s.bridge.handle("phone",s.sender,{type:"command_execute",id:"protected1",name:"protected"});await settled();expect(s.host.confirm).toHaveBeenCalledWith("Permission","Allow?");expect(allowed).toBe(false);expect(s.replies[0]).toMatchObject({status:"accepted"});s.bridge.stop();
  });
  it("rejects unpaired senders and unknown or injected commands before forwarding target text",async()=>{
    const s=setup();for(const [id,name,args] of [["unknown","not-loaded",undefined],["newline","reload","x\n/send"],["slash","/reload",undefined]] as const){await s.bridge.handle("phone",s.sender,{type:"command_execute",id,name,args});await settled();}
    expect(s.replies.every(r=>r.type==="command_result"&&r.status==="rejected")).toBe(true);expect(s.host.modelInput).toEqual([]);expect(s.host.sent.every(c=>c.text.startsWith("/remote-pi-native-dispatch "))).toBe(true);
    s.unpair();await s.bridge.handle("phone",s.sender,{type:"list_commands",id:"unpaired"});expect(s.replies.at(-1)).toMatchObject({code:"not_paired"});s.bridge.stop();
  });
  it("missing fast command or checkpoint skill stays honestly unavailable",async()=>{
    const s=setup();for(const name of ["fast","checkpoint"]){await s.bridge.handle("phone",s.sender,{type:"command_execute",id:name,name});await settled();expect(s.replies.at(-1)).toMatchObject({status:"rejected"});}expect(s.host.modelInput).toEqual([]);s.bridge.stop();
  });
  it("does not execute after pairing IO outlives the request deadline",async()=>{
    vi.useFakeTimers();try {
      const host=new FakeHost(),replies:CommandServerMessage[]=[];const run=vi.fn();host.add("claude-fast",run);
      let checks=0,release:((allowed:boolean)=>void)|undefined;
      const gate=new Promise<boolean>(resolve=>{release=resolve;});
      const bridge=new NativeCommands(host.api,{provider:()=>"claude-bridge",busy:()=>false,authorize:async()=>++checks===1?true:gate});
      await bridge.handle("phone",{send:r=>{replies.push(r);}},{type:"command_execute",id:"slow-auth",name:"fast"});
      await vi.advanceTimersByTimeAsync(12001);expect(replies[0]).toMatchObject({code:"dispatch_timeout"});release!(true);await vi.advanceTimersByTimeAsync(0);expect(run).not.toHaveBeenCalled();bridge.stop();
    }finally{vi.useRealTimers();}
  });
  it("caps pending work, rejects timeouts, and clears pending requests on replacement",async()=>{
    vi.useFakeTimers();try{const s=setup();s.host.hold=true;for(let i=0;i<16;i++)await s.bridge.handle("phone",s.sender,{type:"command_execute",id:`p${i}`,name:"reload"});
      await s.bridge.handle("phone",s.sender,{type:"command_execute",id:"overflow",name:"reload"});expect(s.replies.at(-1)).toMatchObject({code:"command_pending"});
      await vi.advanceTimersByTimeAsync(12001);expect(s.replies.filter(r=>r.type==="command_result"&&r.code==="dispatch_timeout")).toHaveLength(16);
      await s.bridge.handle("phone",s.sender,{type:"command_execute",id:"shutdown",name:"reload"});s.bridge.stop();expect(s.replies.at(-1)).toMatchObject({code:"session_changed"});expect(s.host.reload).not.toHaveBeenCalled();
    }finally{vi.useRealTimers();}
  });
});
