import { describe,it,expect } from "vitest";
import { CREDENTIAL_INSTRUCTIONS,isDirectOpInvocation,isOpAuthorizationTimeout } from "./credential_blocker.js";

const failed=(command="op read --account my.1password.com 'op://Business/Example/password'",text="[ERROR] 2026/10/27 14:32:01 authorization timeout")=>({toolName:"bash",input:{command},isError:true,content:[{type:"text",text}],structuredContent:{exit_code:1}});
describe("narrow observed op credential blocker",()=>{
  it.each([
    "op read --account my.1password.com 'op://Business/Example/password'",
    "/opt/homebrew/bin/op --account=my.1password.com inject -i .env.1password",
    "OP_ACCOUNT=my.1password.com op whoami",
    "env OP_ACCOUNT=my.1password.com op item get 'Example item'",
    "command /usr/local/bin/op signin --account my.1password.com",
  ])("recognizes only supported direct argv: %s",command=>{expect(isDirectOpInvocation(command)).toBe(true);expect(isOpAuthorizationTimeout(failed(command))).toBe(true);});
  it.each([
    "echo 'op read x'", "printf '[ERROR] authorization timeout'", "op run -- bash -c 'printf error'",
    "op read x && printf error", "op read x | cat", "op read x > file", "op read $(printf x)",
    "op read x\nprintf error", "python -c 'op read x'", "/tmp/op read x", "op read 'unterminated", "op read x # comment",
  ])("does not infer nested scripts, arbitrary output or other executables: %s",command=>{expect(isDirectOpInvocation(command)).toBe(false);expect(isOpAuthorizationTimeout(failed(command))).toBe(false);});
  it("requires a real failed result and exact op error signature",()=>{
    expect(isOpAuthorizationTimeout({...failed(),isError:false})).toBe(false);
    expect(isOpAuthorizationTimeout({...failed(),structuredContent:{exit_code:0}})).toBe(false);
    expect(isOpAuthorizationTimeout({...failed(),toolName:"read"})).toBe(false);
    for(const output of ["authorization timeout","[ERROR] authorization timeout mentioned in docs","[ERROR] item not found","Please log in to account","[ERROR] permission denied"]){expect(isOpAuthorizationTimeout(failed(undefined,output))).toBe(false);}
    expect(isOpAuthorizationTimeout(failed(undefined,"[ERROR] authorization timeout"))).toBe(true);
    expect(isOpAuthorizationTimeout(failed(undefined,"[ERROR] 2026/10/27 14:32:01 authorization timeout.\r\nCommand exited with code 1"))).toBe(true);
  });
  it("works with older SDK result shape and never mutates or retains tool input/output",()=>{
    const event=failed();const old={...event,structuredContent:undefined};const before=JSON.stringify(old);
    Object.freeze(old);Object.freeze(old.input);Object.freeze(old.content);expect(isOpAuthorizationTimeout(old)).toBe(true);expect(JSON.stringify(old)).toBe(before);
    expect(CREDENTIAL_INSTRUCTIONS).toContain("cannot be unlocked from the phone");expect(CREDENTIAL_INSTRUCTIONS).toContain("Never paste");expect(CREDENTIAL_INSTRUCTIONS).toContain("request_credential");expect(CREDENTIAL_INSTRUCTIONS).not.toContain("op://");
  });
  it("bounds inspection and does not guess from a far-away or malformed output",()=>{
    expect(isOpAuthorizationTimeout(failed(undefined,"x".repeat(9000)+"\n[ERROR] authorization timeout"))).toBe(false);
    expect(isOpAuthorizationTimeout(null)).toBe(false);expect(isOpAuthorizationTimeout({toolName:"bash",isError:true,input:{command:"op read x"},content:[{type:"image",text:"[ERROR] authorization timeout"}]})).toBe(false);
  });
});
