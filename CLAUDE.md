# reddit_chat_bridge — Project Context for Claude Code

Bridge between Reddit Chat (Matrix-based) and a dedicated Discord server. Long-running Ruby process hosted on Unraid (Unraid).

## Non-negotiable decisions

- **Not Rails.** Sinatra + Puma + ActiveRecord/ActiveSupport standalone. Do not introduce `rails`, `solid_queue`, `config/credentials.*`, or `config/master.key` without an explicit discussion with Michael. These were all rejected in planning.
- **Web UI is the admin surface.** No Thor CLI. Every admin action lives on `Admin::Actions` and is invoked by both web controllers and Discord slash command handlers. Never duplicate admin logic between the two entry points.
- **Matrix access token lives in the database**, not an env var. `AuthState` is the source of truth. Token updates flow through `/auth/reauth` in the UI or `/reauth` in Discord — never through redeploy.
- **Almost nothing is an env var.** All Discord + Matrix config is in `app_config`, editable via `/settings`. Supported env vars are `PORT`, `LOG_LEVEL`, `RACK_ENV` only. Database path is hardcoded to `/app/state/state.sqlite3`.
- **No voice/video support, ever.** Images yes; voice/video is permanently out of scope.
- **No simplecov, no honeybadger.** Don't add them back.

## Run / test / lint commands

```bash
bundle install
bin/start                        # boot web UI + background threads
bundle exec rake test            # full test suite
bundle exec rake test TEST=test/matrix/client_test.rb
bundle exec rubocop
bundle exec rubocop -a           # autocorrect
bin/tailwind-watch               # rebuild CSS on save during UI work (dev convenience)
```

## Testing conventions

- **TDD.** Write the failing test before the implementation.
- `ActiveSupport::TestCase` with `test "name" do … end` blocks.
- `mocha` for stubbing (`stubs`, `expects`, `any_instance`).
- `webmock` for HTTP. No test hits the real Matrix or Discord APIs.
- `rack-test` for controller and integration tests.
- Fixtures under `test/support/` — build them from captures taken during the Phase 0 spike.

## Architecture touchpoints

- `lib/bridge/application.rb` — wires threads + Puma + signal handlers. Read this first when making structural changes.
- `lib/admin/actions.rb` — single home for resync / reauth / backfill / reconcile. Both the web UI and Discord slash commands call into it.
- `lib/matrix/sync_loop.rb` — the long-poll /sync loop. Runs on its own thread; `lib/bridge/supervisor.rb` restarts it if it crashes.
- `lib/discord/gateway.rb` — Phase 2 only. Receives Discord messages to forward to Reddit.
- `lib/dedup/sent_registry.rb` — prevents Phase 2 echo loops. Consulted by `Matrix::SyncLoop` before posting a received event to Discord.

## Style

- `rubocop-mmenanno` is authoritative. No custom overrides unless justified in a comment.
- Small classes: ~150 LOC hard ceiling. If a service grows past that, it's doing too much — split it.
- Dependency injection: services that use HTTP take a `Faraday::Connection` (or equivalent) as a constructor arg. Tests substitute fakes; never patch globals.
- Value objects for IDs: `MatrixRoomId`, `MatrixEventId`, `DiscordChannelId`. Prevents string-type mix-ups.
- No silent fallbacks. Missing config crashes boot with a precise error. Token invalid triggers `#app-status` alert.

## Known gotchas

- `matrix_sdk` last shipped in 2022 and references Ruby 3.4 in its CI. Spike confirmed it loads on Ruby 4.0.2. If runtime issues appear, swap to a thin Faraday client.
- `discordrb` 3.7.2 is the latest on RubyGems; GitHub has newer. Loads cleanly on Ruby 4.0.2; emits a harmless libsodium warning about voice (which we don't support).
- Reddit's Matrix homeserver is `matrix.redditspace.com`. Auth is a Bearer JWT extracted from a logged-in browser DevTools session. **Token lifetime ≈ 24h** — reauth is a regular task. Expiry is visible in the JWT `exp` claim.
- **Reddit Matrix user IDs use the `t2_` account ID as the localpart**, e.g., `@t2_22jl0cs4s6:reddit.com`. Resolve to display names via `GET /_matrix/client/v3/profile/{user_id}` or the room's `m.room.member` state — cache the result.
- **Reddit ships custom event types** like `com.reddit.profile` in the room timeline. Filter to `m.room.message` and `m.room.member` only; log any other seen type so we can spot new ones.
- **`@t2_1qwk:reddit.com`** is a Reddit system/service account seen across multiple rooms. Prefix its messages with a distinct marker (`🤖 Reddit System` or similar) rather than silently dropping them in the MVP.
- Reddit chat rooms are not E2E-encrypted, so plain `/sync` returns plaintext events. No Olm/Megolm work required.
- Never pass the Matrix access token as a long shell positional arg — bash / LLM copy layers have mangled a character in the 1309-char JWT before. Always use a file (`MATRIX_ACCESS_TOKEN_FILE`) or the web UI paste field.
- Unraid: containers are managed through the Unraid web UI only. Never create/delete/recreate via CLI (container config lives in Unraid's XML templates, which the CLI doesn't know about).

## Process notes

- Approved plan and ongoing process/decision notes live in `docs/` (gitignored). Consult `docs/plan.md` for the full design.
- User-facing docs live in `guides/` (committed).
