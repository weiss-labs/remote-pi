import { Type } from "typebox";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { CredentialBridge, MAX_LABEL, MAX_PURPOSE, MAX_REFERENCE } from "./bridge.js";

export const parameters = Type.Object({
  label: Type.String({ maxLength: MAX_LABEL, description: "Exact service/key label the user will recognise, e.g. 'Stripe secret key (live)'." }),
  reference: Type.String({ maxLength: MAX_REFERENCE, description: "Where it lives in 1Password: 'vault → item → field' or an exact op://vault/item/field reference. One scoped credential only; never the 1Password account password, Secret Key or a service-account token." }),
  purpose: Type.String({ maxLength: MAX_PURPOSE, description: "One short sentence on what this task uses it for." }),
});

export function registerCredentialTool(pi: ExtensionAPI, bridge: CredentialBridge): void {
  pi.registerTool({
    name: "request_credential",
    label: "Request private credential from phone",
    description: "Ask the paired phone for ONE scoped credential (API key, token, one service password) when the Mac's own 1Password/cache retrieval is blocked remotely. Name the exact 1Password vault, item and field; the user copies it from phone 1Password and it arrives end-to-end encrypted (the relay sees ciphertext). The value is NEVER returned here: it is written to a private 0600 file with a ~15 minute TTL and only the path comes back. Read it from an authorized subprocess (for example an env var set from the file inside the same command) without printing, echoing, logging or copying it. Do not tell the user to touch the Mac or ask for the 1Password account password/Secret Key. This blocks until the phone supplies, cancels, or 10 minutes pass. One request at a time; a wrong value needs a new explicit request. Transfer success is not provider validation. Never call for the outgoing-send/payment/release approvals, which stay on their own gates.",
    parameters,
    execute: async (_id, args, signal) => {
      const d = await bridge.request(args, signal);
      const expires = new Date(d.expires_at).toISOString();
      return {
        content: [{ type: "text", text:
          `Credential supplied privately: ${d.label}\nSource: ${d.reference}\nFile: ${d.path}\nExpires: ${expires} (file deleted then; mode 0600, this user only)\n` +
          `Use it from an authorized subprocess without printing it, e.g. inside the one command that needs it: VAR="$(cat ${d.path})" <command>. ` +
          `Do not cat, echo, log, commit or copy the value anywhere, and do not paste it into chat. A transfer ACK is not provider validation; if the provider rejects it, call request_credential again instead of reusing this file after expiry.` }],
        details: { path: d.path, reference: d.reference, expires_at: d.expires_at },
      };
    },
  });
}
