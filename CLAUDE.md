# reddit_chat_bridge — Project Context for Claude Code

Bridge between Reddit Chat (Matrix-based under the hood) and a dedicated Discord server. Long-running Ruby process hosted on Unraid (Unraid). Built slice-by-slice via TDD; the current state is a functional Phase 1 with auto-refresh. Phase 2 (Discord → Reddit outbound) is not built yet.

## Current state (April 2026)

**Phase 0 — spike:** ✅ complete. Proved Ruby 4.0.2 gem compatibility, Matrix `/sync` + `PUT /rooms/.../send` both work with a bearer JWT, and (in a later spike) that Reddit re-mints JWTs on demand when you GET `/chat/` without the `token_v2` cookie. See `docs/phase-0-spike.md` and `docs/token-refresh-spike.md`.

**Phase 1 — outbound + auto-refresh:** ✅ built and in production on Unraid. Receives Reddit chat events, posts to per-conversation Discord channels, refreshes the Matrix token automatically from stored Reddit session cookies.

**Phase 2 — inbound (Discord → Reddit):** ⛔ not started. Plan has the design; no code yet.

**Phase 3 — polish (archival, media, edit/redaction sync):** ⛔ explicitly deferred.

## Non-negotiable decisions

- **Not Rails.** Sinatra + Puma + standalone ActiveRecord/ActiveSupport. Do not introduce `rails`, `solid_queue`, `config/credentials.*`, or `config/master.key` without explicit discussion. These were rejected during planning for good reasons (mostly: the user wanted to avoid master-key pain when deploying GHCR images to Unraid).
- **Web UI is the admin surface.** No Thor CLI. Every admin op lives on `Admin::Actions` and is invoked by both web controllers and (future) Discord slash command handlers. Do not duplicate admin logic between entry points.
- **Matrix access token lives in the database**, not env vars. `AuthState.access_token` is source of truth. `Matrix::Client` takes a callable for access_token so token updates take effect on the next request without restarts.
- **Reddit session cookies live in the database encrypted at rest** (key derived from `AppConfig.session_secret` via `ActiveSupport::KeyGenerator`). `AuthState.reddit_cookie_jar` is the ciphertext; the reader decrypts on demand.
- **Almost nothing is an env var.** All Discord + Matrix config is in `app_config`, edited via `/settings`. Supported env vars: `PORT`, `LOG_LEVEL`, `RACK_ENV`. Database path hardcoded to `/app/state/state.sqlite3`.
- **No voice/video support, ever.** Images yes, eventually. Voice/video never.
- **No simplecov, no honeybadger.** They were dropped from scope.

## Run / test / lint commands

```bash
bundle install
bin/start                        # boots Puma; config.ru starts the supervisor if configured
bundle exec rake test            # full suite (215+ tests currently)
bundle exec rake test TEST=test/matrix/client_test.rb
bundle exec rubocop              # must be green for CI to pass
bundle exec rubocop -a           # autocorrect what you can

# Live spike scripts (need .env with real credentials):
dotenvx run -- bundle exec bin/spike_matrix_sync    # live Matrix /sync read
dotenvx run -- bundle exec bin/spike_matrix_send    # live Matrix send
dotenvx run -- bundle exec bin/spike_token_refresh  # Reddit-cookie → fresh JWT
```

The `.env` file is gitignored and holds real secrets. `.env.example` documents the schema.

## Testing conventions

- **TDD.** Write the failing test before the implementation. Always.
- `ActiveSupport::TestCase` with `test "name" do … end` blocks.
- `mocha` for stubbing (`stubs`, `expects`, `any_instance`).
  - **Prefer `expects` over `stubs` inside a single test.** `stubs` permits any
    call count (including zero), so if the code path changes and the method
    never gets hit, the stub silently goes unused — wasted setup, and a
    regression can hide behind it. `expects` asserts the method was actually
    called at least once, catching that drift.
  - `stubs` is fine in `setup` blocks and shared test helpers (`support/*.rb`,
    private `def event(...)` factories) where the same fake is reused across
    many tests and not every test exercises every stubbed method. Per-test
    behavior should use `expects`.
- **Time travel via `ActiveSupport::Testing::TimeHelpers`** (already
  included in `test_helper.rb`). Use `travel_to(time) do ... end`,
  `travel(duration)`, and `freeze_time`; never `Time.stubs(:current)`.
  The block form auto-restores at `end`, and these helpers cover `Time`,
  `Date`, and `DateTime` uniformly.
- **`setup do` / `teardown do`, not `def setup`.** Block form chains
  automatically — multiple `setup do` blocks (from `test_helper.rb`,
  from the file itself, and potentially from future concerns) all run
  in registration order. `def setup` needs manual `super`, and a missing
  one silently breaks isolation.
- `webmock` for all HTTP. No test hits the real Matrix / Discord / Reddit APIs; `WebMock.disable_net_connect!` is on in `test_helper.rb`.
- `rack-test` for controller / integration tests.
- Test DB is `:memory:` SQLite; each test runs inside a transaction that's rolled back at teardown, so the DB returns to its post-migration state between tests.
- `Bridge::Application.shutdown!` is called in teardown (it's a process-wide singleton that would otherwise leak between tests).

## Service graph (lib/)

```
lib/
├── models/                    # ActiveRecord models
│   ├── application_record.rb
│   ├── app_config.rb          # key/value store backing /settings
│   ├── auth_state.rb          # singleton: token, reddit cookie jar, paused state
│   ├── sync_checkpoint.rb     # singleton: Matrix next_batch token
│   ├── room.rb                # per-conversation: matrix_room_id ↔ discord_channel_id
│   ├── posted_event.rb        # idempotency cache: event_id → posted_at
│   └── admin_user.rb          # web-UI login, bcrypt passwords
├── matrix/
│   ├── client.rb              # Faraday; whoami, sync, send_message, profile
│   ├── event_normalizer.rb    # /sync body → NormalizedEvent value objects
│   └── sync_loop.rb           # one-shot /sync round-trip w/ checkpoint advance
├── discord/
│   ├── client.rb              # Faraday; create_channel, send_message, rename_channel
│   ├── channel_index.rb       # room → discord_channel_id, auto-creates
│   ├── poster.rb              # NormalizedEvent → Discord post (the dispatcher)
│   ├── admin_notifier.rb      # #app-status alerts
│   └── logger.rb              # #app-logs operational lines
├── auth/
│   └── refresh_flow.rb        # /chat/ mint + Matrix /login registration
├── admin/
│   └── actions.rb             # reauth / resync / set_reddit_cookies! / refresh_matrix_token!
├── retry/
│   └── backoff.rb             # exponential-backoff helper
└── bridge/
    ├── boot.rb                # AR connection + migrations
    ├── application.rb         # process-wide singleton wiring the graph
    ├── supervisor.rb          # runs SyncLoop#iterate forever + refresh tick
    └── web/app.rb             # Sinatra::Base subclass with all routes
```

## Database schema (migrations 0001–0007)

- `app_configs` (key, value) — /settings fields + session_secret
- `auth_state` (singleton row) — access_token + user_id + paused + reddit_cookie_jar (encrypted) + reddit_session_expires_at
- `sync_checkpoints` (singleton row) — next_batch_token + last_batch_at
- `rooms` — matrix_room_id (unique), discord_channel_id, counterparty_matrix_id, counterparty_username, last_event_id
- `admin_users` — username (unique), password_digest (bcrypt)
- `posted_events` — event_id (unique), room_id, posted_at (for idempotent Discord posting)

## Non-obvious Reddit/Matrix quirks discovered

- **Matrix user_ids use `@t2_<account_id>:reddit.com`**, not the display name. Username is resolved from `m.room.member.m.relations.com.reddit.profile.username` in the lazy-loaded state, or via `GET /_matrix/client/v3/profile/{user_id}` as a fallback.
- **Reddit ships custom event types**: `com.reddit.profile`, `com.reddit.chat.type`, `com.reddit.invite_spam_status`. `Matrix::EventNormalizer` filters to `m.room.message` + `m.room.member` only.
- **`@t2_1qwk:reddit.com` is Reddit's system/redactor bot**, listed in `m.room.create.redactors`. Posts from it are marked `is_system?` and prefixed `🤖 **Reddit**`.
- **Reddit's `/login` endpoint uses `type: "com.reddit.token"`** (not standard `m.login.password` / `m.login.token`). The request body is `{"type":"com.reddit.token","token":"<jwt>","initial_device_display_name":"..."}` and the JWT it sends is the same JWT that comes back as `access_token`. The /login call registers the JWT as a device session — without it, Matrix returns `M_UNKNOWN_TOKEN` when you use the JWT as a bearer.
- **Reddit mints Matrix JWTs in the SSR'd `/chat/` HTML.** The page embeds `<rs-app token="{json}">` where the JSON is `{token: "<jwt>", expires: <ms>}`. Omit `token_v2` from the outgoing cookie jar and Reddit's backend re-mints a fresh JWT. This is how `Auth::RefreshFlow` refreshes.
- **JWT lifetimes:** the Matrix access token JWT lives ~24h; the `reddit_session` JWT lives ~6 months. The refresh loop triggers when the Matrix JWT has <1h remaining; operator alert fires when the reddit_session has <7 days remaining.
- **Lazy-loaded member state:** on resume `/sync` requests, Matrix only ships `m.room.member` for users appearing in the timeline batch. For rooms where the first event we see is from us, the counterparty's member state might be absent. `Discord::Poster` falls back to `Matrix::Client#profile(user_id:)`.
- **Matrix room versions are `org.matrix.msc3929`** — custom Reddit MSC. No impact today; noted for future debugging.
- **Reddit chat is NOT end-to-end encrypted.** Plain `/sync` returns plaintext events. No Olm/Megolm work required.

## Discord API quirks

- **Content cap is 2000 chars.** `Discord::Poster` truncates and appends `…[truncated]`.
- **HTTP 400 ("Invalid Form Body") is not retryable.** `Discord::BadRequest` is caught in Poster, the event is marked posted (via `PostedEvent`), logged to `#app-logs`, and we skip forward. Otherwise the checkpoint never advances and the same bad event loops forever.
- **Rate limits:** Discord returns 429 with `retry_after` (seconds, as a float). `Discord::RateLimited` carries `retry_after_ms`. Poster respects it and retries up to 3 times.
- **Channel deletion recovery:** Poster catches `Discord::NotFound` on post, clears the stale `room.discord_channel_id`, and calls `ensure_channel` again to create a new channel. Idempotent.
- **Channel rename:** when `counterparty_username` resolves after the channel was created (e.g. first event lacked member state), Poster renames the Discord channel via `Discord::Client#rename_channel`.

## Architecture touchpoints

- `lib/bridge/application.rb` — wires threads + Puma + signal handlers. Read this first when making structural changes.
- `lib/admin/actions.rb` — single home for admin operations. Web controllers and (future) Discord slash commands both call into it.
- `lib/matrix/sync_loop.rb` — the long-poll /sync loop. Advances the checkpoint only after successful dispatch.
- `lib/bridge/supervisor.rb` — wraps SyncLoop with retry, token-expiry checks (refresh when <1h remains), and paused-state handling.
- `lib/discord/poster.rb` — all the defensive logic (truncation, idempotency, rate-limit retry, channel recovery, rename on username resolution). Expect more quirks to accumulate here.
- `lib/auth/refresh_flow.rb` — mints a fresh JWT via `/chat/` + registers it with Matrix via `/login`. Both steps are required.

## Style

- `rubocop-mmenanno` is authoritative. Configured as a rubocop plugin with `rubocop-minitest` / `rubocop-performance` / `rubocop-thread_safety`.
- Small classes: ~150 LOC hard ceiling. If a service grows past that, split it.
- Dependency injection: services that do HTTP take an injected `Faraday::Connection` (or equivalent); tests substitute fakes, no global patching.
- Value objects for IDs where they'd prevent confusion (e.g., `NormalizedEvent` as a `Data.define`).
- No silent fallbacks. Missing config = hard crash at boot with a precise error. Token invalid = loud alert, never a silent degrade.
- `rubocop:disable ThreadSafety/MutableClassInstanceVariable` is allowed in the web app (`lib/bridge/web/**/*.rb`) because Sinatra's route DSL turns request-scoped `@foo` into per-request instance vars that the static analyzer misreads.

## Known gotchas

- **`matrix_sdk` gem is in Gemfile but unused.** We use Faraday directly (decision from Phase 0 spike). Don't reintroduce matrix_sdk without discussion.
- **`discordrb` 3.7.2** is pinned; confirmed loads on Ruby 4.0.2. Voice support is irrelevant (libsodium warning on load is benign).
- **Tailwind v4 + DaisyUI**: Dockerfile's assets stage has a Node.js install because DaisyUI is a JS plugin and the standalone Tailwind CLI can't resolve `@plugin "daisyui"` without `node_modules/daisyui`. Node is only in the build stage; the runtime image has no Node.
- **Boot order matters for `require`s**: `config.ru` must call `Bridge::Boot.call` BEFORE `require "bridge/web/app"`, because the app's `configure` block reads `AppConfig` at class-load time (for the persisted session_secret). Same rule in `test_helper.rb`.
- **Never pass the Matrix access token as a shell positional arg.** Bash / LLM copy layers have mangled characters in the 1309-char JWT before. For local scripts use `dotenvx run -- …` with `.env`; in production use the web UI's `/auth` paste field.
- **Unraid container management goes through the Unraid web UI only.** Never create/delete/recreate containers via CLI (container config lives in Unraid's XML templates, which the CLI doesn't know about). Config changes like env vars go through the template edit form.
- **CI gates release.** Rubocop + minitest must pass before the GHCR image is published. If you locally `rubocop -a` and don't commit the autocorrected files, CI will fail (we've hit this twice).
- **docs/ is gitignored** (our working notes). `guides/` is committed for user-facing documentation.

## Infrastructure

- **Image:** `ghcr.io/mmenanno/reddit_chat_bridge:latest` (also tagged `:<short-sha>`) — published by `.github/workflows/ci.yml` on push to main after CI green.
- **Container:** deployed to Unraid (Unraid) via the web UI per `guides/unraid_deployment.md`. Runs as uid/gid `1000:1000`. SQLite on `/mnt/cache/appdata/reddit_chat_bridge/state.sqlite3` (mapped to `/app/state`).
- **Network:** on `proxynet`, exposed via TSDProxy labels (`tsdproxy.enable=true`, `tsdproxy.name=reddit-chat-bridge`, `tsdproxy.container_port=4567`) as `https://reddit-chat-bridge.<your-tailnet>.ts.net`.
- **Secrets model:** operator keeps cookies/tokens in 1Password (personal backup). At runtime, the web UI's `/auth` and `/settings` pages write them to SQLite. The Unraid template has no secrets in env vars.

## Pointers

- `docs/plan.md` — the full approved plan (gitignored; never out of date because nobody's overwriting it).
- `docs/phase-0-spike.md` — the original feasibility spike notes.
- `docs/token-refresh-spike.md` — the auto-refresh discovery work.
- `guides/bot_setup.md` — Discord app + server + roles + intents.
- `guides/extracting_matrix_token.md` — manual token fallback path.
- `guides/unraid_deployment.md` — Unraid template walkthrough.
- `guides/runbook.md` — operating the bridge when it misbehaves.

## What's next (open items)

- Warning alert at T-7 days before `reddit_session` expiry (the supervisor has `AuthState.reddit_session_expiring_soon?` — just needs a scheduled check that fires `admin_notifier.warn`). Not wired yet.
- Phase 2: Discord → Reddit outbound. Design in `docs/plan.md`.
- Discord slash commands (`/reauth`, `/resync`, etc.) — placeholders exist in the Discord server layout (`#commands` channel) but no handler code yet.
- Retroactive cleanup: existing channels named with opaque room_id slugs will self-heal on next message (Poster renames them), but operator can also delete them manually; 404-recovery creates replacements with correct names.
