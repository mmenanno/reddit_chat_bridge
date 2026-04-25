# Screenshots

Repo-only images referenced from the main `README.md`'s Screenshots section. Not bundled into the Docker image.

## Expected files

| Filename | Source view |
| -------- | ----------- |
| `dashboard.png` | Admin web UI, `/` (dashboard) |
| `bot-setup-wizard.png` | Admin web UI, `/guide/bot-setup` |
| `message-requests.png` | Either `/requests` in the admin UI, or the `#message-requests` Discord channel showing Approve/Decline buttons on a card |
| `dm-channel.png` | A live `#dm-*` Discord channel showing the webhook persona rewrite (Reddit display name + snoovatar on operator-typed messages) |

## Capture notes

Web UI shots can be scripted with Playwright against a running dev server (`bin/start` on `:4567`). Discord-side shots (`message-requests.png`, `dm-channel.png`) have to be captured manually since the bot operates inside a real guild.

PNGs are preferred over JPEGs for the UI's text rendering. Aim for 2x retina capture (typically 2560 wide on a 1280-CSS-pixel viewport) so the screenshots stay sharp on high-DPI displays.

When credentials, Discord IDs, or real usernames are visible in a screenshot, redact or substitute them before committing.
