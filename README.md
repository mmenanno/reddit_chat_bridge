# reddit_chat_bridge

A self-hosted bridge between Reddit Chat and a dedicated Discord server. Every Reddit chat event — incoming messages, invites, and your own outgoing messages — surfaces in Discord. Later: replies typed in Discord flow back to Reddit.

**Status:** Phase 0 — feasibility spike. Not yet functional.

Reddit Chat is built on Matrix (homeserver `matrix.redditspace.com`), so this is really a specialized Matrix ↔ Discord bridge that happens to point at Reddit's homeserver.

## Stack

- Ruby 4.0.2, Sinatra + Puma
- ActiveRecord + ActiveSupport standalone (no Rails)
- Tailwind CSS v4 (standalone CLI) + DaisyUI v5
- SQLite persistence
- Matrix SDK (or Faraday fallback — TBD in spike)
- discordrb (or websocket-client-simple fallback — TBD in spike)
- Mocha + Webmock + ActiveSupport::TestCase for tests (TDD)

## Guides

User-facing documentation lives in [`guides/`](./guides/):

- `bot_setup.md` — creating the Discord bot, configuring the server, roles, intents
- `extracting_matrix_token.md` — pulling the Reddit Matrix access token from your browser
- `runbook.md` — operating the bridge; what to do when things go wrong

## Development

```bash
mise install                # ensure Ruby 4.0.2
bundle install
bin/start                   # boots web UI + background threads
bundle exec rake test
bundle exec rubocop
```

## Deployment

Builds to `ghcr.io/mmenanno/reddit_chat_bridge:latest` on merge to `main`. Runs on Unraid (Unraid) via the usual container-template flow, exposed on the tailnet through TSDProxy at `reddit-chat-bridge.<your-tailnet>.ts.net`.
