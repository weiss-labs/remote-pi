# Private fork push rollout

## Credentials and signing

- Apple team AH8UQ54A3J, bundle ai.weisslabs.remotepi, App Store Connect app 6826925709.
- Dedicated APNs key ID 8QWVC3VS24, production only, topic-restricted to this bundle. Never use the ASC upload key to sign APNs JWTs.
- Key's source of truth: Business 1Password **document** `Remote Pi - APNs production key 8QWVC3VS24`, ID `etantukpy4fjo3jn4nfn3xrkay`. Restore with `op document get etantukpy4fjo3jn4nfn3xrkay --account my.1password.com --out-file <private path>`; chmod 600. Not a credential field; do not invent an op://credential reference.
- Derived Mac file: `~/.appstoreconnect/apns/AuthKey_8QWVC3VS24.p8` (0600); VPS private mount `/root/remote-pi-relay/secrets/apns.p8` (0600).
- Replacement profiles, created without deleting old profiles: `Remote Pi WL App Store Push` (JBGA2X533W), `Remote Pi WL Direct Push` (QDUY8VXDU5). App Store profile decoded and confirmed `aps-environment=production`.

## Deployment

Existing personal VPS `srv811922.hstgr.cloud`, container `remote-pi-relay` on `root_default`, Traefik host relay.srv811922.hstgr.cloud, existing `/data` mount from `/root/remote-pi-relay/data`. Preserve mesh.db and notifications.db. No community push service or Firebase.

The new container adds read-only `/run/secrets` mount and env variables listed in pi-extension/docs/notifications.md. Update-recipient allowlist is exact paired Mac:phone, not all team users. Save the previous container/image for rollback before swapping; never run two production containers against the same SQLite database. Existing vps-health entry watches this container + site.

Deploy relay first, immutable extension via `pi-extension/build-release.sh` second, then `app/ship-testflight.sh`. Running panes need to load the new release before they can register phones or produce notifications. Do not interrupt active panes or assume rewriting a loader changes a running process.

## Evidence so far (not device proof)

- Integrated app: 601 serial tests + analyzer passed; native foreground policy 7 cases passed.
- Integrated extension: 830 tests/3 skipped (maxWorkers1) and tsc passed.
- Integrated Rust tests passed. Additional test ensures simultaneous requests from different rooms are not suppressed by a device-category throttle.
- Apple HTTP/2 credential check with an invalid all-zero synthetic token returned BadDeviceToken, not auth failure.
- Isolated staging container on loopback 33001 accepted a bilateral signed all-eight-category synthetic registration and credential-needed event, then Apple invalid-token response removed that synthetic device from SQLite. No user notification was sent. Staging container removed afterward.
- Independent integration review and live physical-device proof still required. APNs accepted does not equal banner displayed; Focus/user permissions can suppress it.

## Credential UX boundary

Credential-needed is a distinct high-priority alert. No passwords, API keys, or recovery codes belong in chat/logs/push payloads. Phone 1Password cannot approve a Mac biometric prompt. Scoped unattended credentials (already used by Pi Voice) are the preferred integration setup. Do not claim that a generic sign-in instructions dialog implements secure phone-to-Mac credential transfer.
