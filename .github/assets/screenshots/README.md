# Screenshots

Repo-only images referenced from the main `README.md`'s Screenshots section. Not bundled into the Docker image.

## Current files

| Filename | Source view |
| -------- | ----------- |
| `dashboard.png` | Admin web UI, `/` (overview tiles + status) |
| `bot-setup-wizard.png` | Admin web UI, `/guide/bot-setup` (onboarding wizard hero + stepper) |
| `auth.png` | Admin web UI, `/auth` (Reddit session cookie paste flow + manual JWT fallback) |
| `actions.png` | Admin web UI, `/actions` (operator controls and slash command surface) |
| `dm-channel.png` | Discord, a bridged `#dm-*` channel with persona-rewritten messages under each sender's Reddit identity |
| `message-requests-discord.png` | Discord, a message-request card in `#message-requests` showing inviter identity and Approve/Decline workflow |

Web-UI screenshots are scripted: spin up an isolated bridge instance against a temp DB, drive Playwright against `localhost:4568`, capture viewport at 1440x900.

Discord-side screenshots are captured manually since the bot operates inside a real guild. Reddit usernames and avatars must be blurred or substituted before committing.

## When refreshing

When credentials, Discord IDs, or real usernames are visible in a screenshot, redact or substitute them before committing. PNGs are preferred over JPEGs for the UI's text rendering.
