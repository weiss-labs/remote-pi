/** A deliberately narrow observer. Never executes op, changes a tool or retains output. */
export const CREDENTIAL_INSTRUCTIONS = "This pane needs a credential or sign-in. On the affected Mac, unlock or sign in to 1Password and approve the request, then retry the blocked step from this pane. The phone cannot unlock desktop 1Password. Do not paste passwords, tokens or secret values into chat.";

const OP = new Set(["op", "/opt/homebrew/bin/op", "/usr/local/bin/op", "/usr/bin/op"]);
const VERBS = new Set(["read", "inject", "item", "document", "vault", "account", "whoami", "signin"]);
const TIMEOUT = /^\[ERROR\](?: \d{4}\/\d{2}\/\d{2} \d{2}:\d{2}:\d{2})? authorization timeout\.?$/;

/** Only simple POSIX argv forms. Scripts, redirections and child commands are not inferred. */
export function isDirectOpInvocation(command: unknown): boolean {
  if (typeof command !== "string" || command.length > 8192 || /[\r\n;&|<>$`()\\#]/.test(command)) return false;
  const words: string[] = [];
  let i=0;
  while (i<command.length) {
    while (command[i]===" "||command[i]==="\t") i++;
    if (i>=command.length) break;
    let word="";
    if (command[i]==='"'||command[i]==="'") {
      const quote=command[i++];
      while (i<command.length&&command[i]!==quote) word+=command[i++];
      if (i>=command.length) return false;
      i++;
      if (i<command.length&&command[i]!==" "&&command[i]!=="\t") return false;
    } else {
      while (i<command.length&&command[i]!==" "&&command[i]!=="\t") {
        if (command[i]==='"'||command[i]==="'") return false;
        word+=command[i++];
      }
    }
    words.push(word);if(words.length>256)return false;
  }
  let at=0;
  if (words[at]==="env"||words[at]==="/usr/bin/env") at++;
  if (/^OP_ACCOUNT=[A-Za-z0-9._@-]+$/.test(words[at]??"")) at++;
  if (words[at]==="command") at++;
  if (!OP.has(words[at++]??"")) return false;
  // Only known global account flags may precede the command verb.
  while (at<words.length&&words[at].startsWith("-")) {
    if (words[at]==="--account") {at+=2;continue;}
    if (words[at].startsWith("--account=")) {at++;continue;}
    return false;
  }
  return VERBS.has(words[at]??""); // In particular, op run can execute arbitrary children and is excluded.
}
function record(value:unknown):Record<string,unknown>|null {return value!==null&&typeof value==="object"?value as Record<string,unknown>:null;}

/** Uses the public tool_result event, not arbitrary stdout keyword matching. */
export function isOpAuthorizationTimeout(event: unknown): boolean {
  const e=record(event),input=record(e?.input);
  if (e?.toolName!=="bash"||e.isError!==true||!isDirectOpInvocation(input?.command)) return false;
  const structured=record(e.structuredContent);
  if (structured?.exit_code!==undefined&&(!Number.isInteger(structured.exit_code)||structured.exit_code===0)) return false;
  if (!Array.isArray(e.content)) return false;
  let budget=8192;
  for (const part of e.content.slice(0,8)) {
    const p=record(part);
    if (p?.type!=="text"||typeof p.text!=="string") continue;
    const bounded=p.text.slice(0,budget);budget-=bounded.length;
    if (bounded.split("\n").some(line=>TIMEOUT.test(line.endsWith("\r")?line.slice(0,-1):line))) return true;
    if (budget<=0) break;
  }
  return false;
}
