# Security Policy

## Supported versions

Only the latest release is supported. There is no LTS lane.

| Version | Supported |
| ------- | --------- |
| `:latest` GHCR image (current `main`) | yes |
| Any older `:v<version>` GHCR image | no |

Bug fixes and security fixes are applied to `main` and rolled into the next image tag. If you are running an older image, the fix is to update.

## Reporting a vulnerability

Please report security issues privately through GitHub's private vulnerability reporting form:

[Open a private vulnerability report](https://github.com/mmenanno/reddit_chat_bridge/security/advisories/new)

Do not file a public issue or pull request for a security report. The link above is end-to-end private between you and the maintainer.

You can expect an acknowledgement within 7 days. This is a single-maintainer reactive project, so timelines for fixes vary with severity and the maintainer's availability. Critical issues get prompt attention.

## In scope

- Theft, leakage, or unintended exposure of credentials stored by the bridge: the Discord bot token, Matrix access token, and the Reddit `reddit_session` cookie jar (encrypted at rest in SQLite).
- Authentication or authorization bypass on the admin web UI.
- Weakening of the at-rest encryption used for the Reddit cookie jar (key derivation from `AppConfig.session_secret` via `ActiveSupport::KeyGenerator`).
- Remote code execution or unintended file system access from the running container.
- Dependency CVEs that meaningfully affect the running container (i.e. exploitable in the request paths the bridge actually exercises).
- Bugs that allow a Discord operator without admin web UI access to extract bridge state or credentials.

## Out of scope

- The operator typing or pasting their own Reddit cookie or Discord token into the admin web UI on a machine the operator controls.
- Loss of access to the host filesystem holding `/app/state/state.sqlite3`. SQLite is plain on disk; whoever can read the volume can read every credential modulo the cookie-jar encryption.
- Reports that depend on the operator running the container with `--network host`, exposing the web UI to the public internet without a reverse proxy, or otherwise diverging from the deployment guide.
- Social engineering, phishing, or compromise of the operator's Reddit account.
- Reddit, Matrix, or Discord platform issues not caused by this bridge. Report those to the respective platform.

## Hardening already in place

- Reddit cookie jar is encrypted at rest with a key derived from `AppConfig.session_secret` (auto-generated on first boot if not supplied via `SESSION_SECRET`).
- Admin web UI requires bcrypt-protected login.
- Discord interactions are signature-verified with Ed25519 when delivered over HTTP.
- No secrets land in environment variables; all runtime config is database-backed and scoped to the operator's volume.
