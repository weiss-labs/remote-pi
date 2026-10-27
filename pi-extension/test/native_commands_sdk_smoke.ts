/** Isolated, model-free compatibility smoke. No live pane or resources are reloaded.
 * Usage: tsx test/native_commands_sdk_smoke.ts /absolute/sdk/dist/index.js supported|unsupported
 */
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { NativeCommands, type CommandServerMessage } from "../src/actions/commands.js";

const sdkPath=process.argv[2], expected=process.argv[3];
assert(sdkPath && ["supported","unsupported"].includes(expected), "SDK module path and expected capability required");
const sdk=await import(pathToFileURL(sdkPath).href) as typeof import("@earendil-works/pi-coding-agent");
const cwd=await mkdtemp(join(tmpdir(),"remote-pi-command-sdk-"));
let bridge:NativeCommands|undefined, calls=0, reloads=0;
const replies:CommandServerMessage[]=[];
const settingsManager=sdk.SettingsManager.inMemory({autoRetryEnabled:false});
const resourceLoader=new sdk.DefaultResourceLoader({cwd,agentDir:cwd,settingsManager,noExtensions:true,noSkills:true,noPromptTemplates:true,noThemes:true,
  extensionFactories:[(pi:ExtensionAPI)=>{
    bridge=new NativeCommands(pi,{busy:()=>false,provider:()=>"claude-bridge",authorize:async()=>true});
    pi.registerCommand("claude-fast",{description:"Synthetic handler for isolated native-dispatch proof",handler:async()=>{calls++;}});
  }],
});
try {
  await resourceLoader.reload();
  const {session}=await sdk.createAgentSession({cwd,agentDir:cwd,settingsManager,resourceLoader,sessionManager:sdk.SessionManager.inMemory(),tools:[]});
  try {
    await session.bindExtensions({commandContextActions:{
      waitForIdle:async()=>{},newSession:async()=>({cancelled:false}),fork:async()=>({cancelled:false}),navigateTree:async()=>({cancelled:false}),switchSession:async()=>({cancelled:false}),reload:async()=>{reloads++;},
    }});
    assert(bridge,"Inline extension must load in isolated SDK session");
    const sender={send:(reply:CommandServerMessage)=>{replies.push(reply);}};
    const wait=async(count:number)=>{for(let i=0;i<200&&replies.length<count;i++)await new Promise(r=>setTimeout(r,5));assert(replies.length>=count,"SDK response timed out");};
    await bridge.handle("synthetic-phone",sender,{type:"list_commands",id:"list"});await wait(1);
    const list=replies[0];assert.equal(list.type,"commands_list");assert(list.type==="commands_list");assert.equal(list.dispatch_supported,expected==="supported");
    await bridge.handle("synthetic-phone",sender,{type:"command_execute",id:"fast",name:"fast"});await wait(2);
    await bridge.handle("synthetic-phone",sender,{type:"command_execute",id:"reload",name:"reload"});await wait(3);
    await new Promise(r=>setTimeout(r,10));
    assert.equal(calls,expected==="supported"?1:0);assert.equal(reloads,expected==="supported"?1:0);
    assert.equal(session.messages.length,0,"No probe or raw slash text may enter model conversation");
    console.log(JSON.stringify({sdk:sdkPath,expected,native_handler_calls:calls,isolated_reload_spy_calls:reloads,model_messages:session.messages.length,results:replies.map(r=>r.type==="commands_list"?{type:r.type,supported:r.dispatch_supported}:{type:r.type,status:r.status,code:r.code})}));
  }finally{bridge?.stop();session.dispose();}
}finally{await rm(cwd,{recursive:true,force:true});}
