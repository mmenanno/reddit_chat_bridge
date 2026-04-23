# reddit_chat_bridge

A self-hosted bridge between Reddit Chat and a dedicated Discord server. Every Reddit chat event — incoming messages, invites, your own outgoing messages — surfaces in Discord. Messages typed in Discord flow back to Reddit under your Reddit identity. Reddit Chat is Matrix under the hood (homeserver `matrix.redditspace.com`), so this is a specialized Matrix ↔ Discord bridge that happens to target Reddit.

**Status:** 1.0 shipped. Bidirectional, production-running, no active roadmap — future work is reactive (bug fixes, API-drift adjustments, occasional UX polish).

## What it does

**Reddit → Discord.** Reddit chat events land in per-conversation `#dm-*` channels under a "Reddit DMs" category. Each bubble posts via a channel-owned webhook so it shows the real Reddit user's display name + snoovatar instead of the bot. Images auto-embed; voice, video, and E2E encryption are out of scope forever.

**Discord → Reddit.** Messages you type in a `#dm-*` channel are relayed to Reddit; the original Discord bubble is replaced with a webhook repost under your Reddit identity so the channel reads uniformly.

**Chat lifecycle.** Incoming message requests from strangers land in `#message-requests` with Approve/Decline buttons. Archive deletes the Discord channel but keeps the Matrix link (auto-unarchives on next message). End chat (hide) is a local-only terminal state since Reddit's Matrix server refuses `/leave` on DM rooms.

## Stack

- Ruby 4.0.2, Sinatra + Puma (no Rails)
- Standalone ActiveRecord + ActiveSupport + SQLite
- Tailwind CSS v4 + DaisyUI v5 (standalone CLI, built into the Docker image)
- Faraday for Matrix + Discord REST; `websocket-client-simple` for the Discord gateway
- Mocha + WebMock + ActiveSupport::TestCase for tests (TDD, 480+ tests, parallel)

## Running locally

```bash
mise install                     # ensures Ruby 4.0.2
bundle install
npm ci                           # Tailwind + DaisyUI for the asset build
bin/setup-hooks                  # activates the pre-push VERSION-bump gate
bin/start                        # boots Puma + background supervisor if configured
bundle exec rake test            # full suite (parallel minitest)
bundle exec rubocop              # must be green for CI
```

First run: visit the web UI, create an admin account, fill `/settings` with the Discord IDs, then paste your `reddit_session` cookie (or a short-lived JWT via the `/auth` bookmarklet) on `/auth`. See `guides/` for step-by-step setup.

## Guides

User-facing documentation lives in [`guides/`](./guides/):

- `bot_setup.md` — creating the Discord bot, server layout, roles, intents
- `unraid_deployment.md` — filling out the Unraid container template (paths, ports, TSDProxy labels)
- `runbook.md` — operating the bridge when it misbehaves

## Deployment

CI publishes `ghcr.io/mmenanno/reddit_chat_bridge:latest`, `:v<version>`, and `:sha-<short>` on every push to `main`. The container runs as uid/gid `1000:1000`, persists state under `/app/state` (mapped to Unraid's appdata volume), and exposes its web UI on port 4567. A TSDProxy label puts it on your tailnet at `reddit-chat-bridge.<your-tailnet>.ts.net`. See [`guides/unraid_deployment.md`](./guides/unraid_deployment.md).

## License

MIT — see [`LICENSE`](./LICENSE).
