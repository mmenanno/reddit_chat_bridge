# reddit_chat_bridge — Project Context for Claude Code

Bridge between Reddit Chat (Matrix-based under the hood) and a dedicated Discord server. Long-running Ruby process hosted on Unraid (Unraid). Built slice-by-slice via TDD.

## Current state (April 2026)

**Phase 0 — spike:** ✅ complete. Proved Ruby 4.0.2 gem compatibility, Matrix `/sync` + `PUT /rooms/.../send` both work with a bearer JWT, and (in a later spike) that Reddit re-mints JWTs on demand when you GET `/chat/` without the `token_v2` cookie. See `docs/phase-0-spike.md` and `docs/token-refresh-spike.md`.

**Phase 1 — outbound (Reddit → Discord):** ✅ built and in production. Receives Reddit chat events, posts to per-conversation Discord channels via channel-owned webhooks (so each bubble looks like it came from the real Reddit user), refreshes the Matrix token automatically from stored Reddit session cookies, falls back to Reddit's public `/about.json` snoovatar when chat state has no avatar.

**Phase 2 — inbound (Discord → Reddit):** ✅ built. `OutboundDispatcher` relays operator messages from `#dm-*` channels to Reddit via `PUT /rooms/.../send`, registers the event id in `SentRegistry` so `/sync` echoes don't double-post, and replaces the original Discord-typed bubble with a webhook repost under the operator's Reddit identity so the channel reads uniformly.

**Phase 2.5 — chat lifecycle:** ✅ built.
- **Message requests:** strangers land in a pending `MessageRequest`; `#message-requests` channel surfaces each with Approve/Decline buttons. Approve joins the Matrix room; Decline leaves it (this works for invite-state rooms) and future DMs from the same user land as a fresh request.
- **Archive:** delete the Discord channel, keep the Matrix link, auto-unarchive on next message.
- **End chat (hide):** delete the channel, mark Room terminated, filter every future event for that matrix_room_id. Reddit's Matrix server refuses `/leave` on DM rooms (same limit their own "Hide chat" button has to live with), so this is a local-hide semantic with a Restore counterpart.

**Phase 3 — polish:** partial. Media URLs resolve (images auto-embed). Edit/redaction sync, voice, E2E encryption — still out of scope forever.

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
├── models/
│   ├── application_record.rb
│   ├── app_config.rb          # key/value store backing /settings
│   ├── auth_state.rb          # singleton: token, reddit cookie jar, paused state
│   ├── sync_checkpoint.rb     # singleton: Matrix next_batch token
│   ├── room.rb                # matrix_room_id ↔ discord_channel_id + webhook + archived_at + terminated_at + last_activity_at + counterparty_avatar_*
│   ├── posted_event.rb        # idempotency cache; cleared on archive / channel recreate
│   ├── event_log_entry.rb     # journal tail surfaced at /events
│   ├── outbound_message.rb    # SentRegistry store: Discord msg id → Matrix event id
│   ├── message_request.rb     # pending Reddit invite awaiting Approve/Decline
│   └── admin_user.rb          # web-UI login, bcrypt passwords
├── matrix/
│   ├── client.rb              # Faraday; whoami/sync/send_message/join_room/leave_room/profile/room_messages
│   ├── event_normalizer.rb    # /sync body → NormalizedEvent value objects (with sender_avatar_url)
│   ├── media_resolver.rb      # mxc:// → https:// download URL for auto-embed
│   ├── sync_loop.rb           # /sync round-trip; hands invites to InviteHandler, dispatch to Poster
│   └── invite_handler.rb      # rooms.invite → MessageRequest + notifier ping
├── discord/
│   ├── client.rb              # Faraday; channels, messages, webhooks, reorder, interactions, delete_message
│   ├── channel_index.rb       # room → discord_channel_id + discord_webhook_id/token, auto-creates both
│   ├── channel_reorderer.rb   # bulk PATCH /guilds/:id/channels — sorts #dm-* most-recent-first
│   ├── poster.rb              # Inbound dispatcher: NormalizedEvent → webhook post under Reddit identity
│   ├── outbound_dispatcher.rb # MESSAGE_CREATE → Matrix relay → delete original → webhook persona rewrite
│   ├── gateway.rb             # Websocket (IDENTIFY/HEARTBEAT/DISPATCH/INTERACTION_CREATE)
│   ├── interaction_handler.rb # Deferred-ACK orchestrator: types 5/6 ACK + async work + edit @original
│   ├── slash_command_router.rb    # /status /resync /reconcile /rebuild /refresh_token /ping /test_discord
│   │                              #  + per-#dm-*: /refresh /archive /endchat /room
│   ├── message_component_router.rb# button clicks (mr:approve:<id> / mr:decline:<id>)
│   ├── message_request_notifier.rb# posts embed + Approve/Decline buttons to #message-requests
│   ├── interaction_verifier.rb    # Ed25519 sig check for HTTP-delivered interactions
│   ├── admin_notifier.rb      # #app-status critical alerts
│   └── logger.rb              # #app-logs operational lines
├── reddit/
│   └── profile_client.rb      # /user/<name>/about.json → snoovatar URL (avatar fallback)
├── auth/
│   └── refresh_flow.rb        # /chat/ JWT mint + Matrix /login registration
├── admin/
│   ├── actions.rb             # single home for admin ops (web + slash commands both call into it)
│   └── reconciler.rb          # channel renames, backfill, archive/unarchive, end/restore, delete_all
├── dedup/
│   └── sent_registry.rb       # thin facade over OutboundMessage.posted_event?
├── retry/
│   └── backoff.rb             # exponential-backoff helper
└── bridge/
    ├── boot.rb                # AR connection + migrations
    ├── application.rb         # process-wide singleton wiring the graph + announce_online
    ├── journal.rb             # facade: writes EventLogEntry + forwards to admin_notifier/logger
    ├── supervisor.rb          # SyncLoop#iterate forever + refresh tick + T-7 cookie warning + prune
    └── web/app.rb             # Sinatra::Base subclass with all routes
```

## Database schema (migrations 0001–0016)

- `app_configs` (key, value) — /settings fields + session_secret + `discord_permissions_blocked_at` + `own_display_name` + `own_avatar_url` + `reddit_session_warned_expires_at`
- `auth_state` (singleton) — access_token, user_id, paused flag, reddit_cookie_jar (encrypted), reddit_session_expires_at
- `sync_checkpoints` (singleton) — next_batch_token, last_batch_at
- `rooms` — matrix_room_id (unique), discord_channel_id, discord_webhook_id + token, counterparty_matrix_id, counterparty_username, counterparty_avatar_url + _checked_at, counterparty_deleted_at, last_event_id, archived_at, terminated_at, last_activity_at, is_direct
- `admin_users` — username (unique), password_digest (bcrypt)
- `posted_events` — event_id (unique), room_id, posted_at
- `event_log_entries` — level, source, message, context (json), created_at (ring-buffer capped at 2000)
- `outbound_messages` — txn_id, discord_message_id, matrix_room_id, matrix_event_id, status, last_error
- `message_requests` — matrix_room_id (unique), inviter_matrix_id, inviter_username, inviter_avatar_url, preview_body, discord_message_id/channel_id, resolved_at, decision

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
- **Reddit's Matrix server refuses `/leave` on DM rooms** (`M_FORBIDDEN: You cannot leave this room`). Their own UI only offers "Hide chat" for the same reason. `Reconciler#end_chat!` best-efforts `/leave`, swallows the failure, and falls back to local termination (filter future events for that matrix_room_id at the Poster + InviteHandler).
- **Matrix `/leave` DOES work on invite-state rooms** — `MessageRequest`'s Decline path uses it successfully because the room is `rooms.invite`, not `rooms.join`.
- **Reddit's chat avatar may be missing even when a snoovatar exists.** `Reddit::ProfileClient` fetches `/user/<name>/about.json` and prefers `snoovatar_img`, falling back to `icon_img` only when it's not the `avatar_default_*.png` placeholder.

## Discord API quirks

- **Content cap is 2000 chars.** `Discord::Poster` truncates and appends `…[truncated]`.
- **HTTP 400 ("Invalid Form Body") is not retryable.** `Discord::BadRequest` is caught in Poster, the event is marked posted (via `PostedEvent`), logged to `#app-logs`, and we skip forward.
- **Slash command description length cap is 100 chars.** Exceeding any one blows up the bulk-register call with `Invalid Form Body`. Keep `COMMAND_DEFINITIONS` descriptions ≤~95 chars; em-dashes occasionally trip certain locales, so prefer ASCII hyphens in command descriptions defensively.
- **Rate limits:** Discord returns 429 with `retry_after` (seconds, as a float). `Discord::RateLimited` carries `retry_after_ms`. Poster respects it and retries up to 3 times.
- **Channel deletion recovery:** Poster catches `Discord::NotFound`, clears the stale webhook first (then channel if that also 404s), re-ensures, and retries. Idempotent.
- **Channel rename:** when `counterparty_username` resolves after the channel was created (e.g. first event lacked member state), Poster renames via `Discord::Client#rename_channel`. If rename returns 404 (manual delete), Reconciler's `rename_or_recreate!` clears PostedEvent for the room before recreating — otherwise backfill silently skips every event as "already posted."
- **Permissions needed on the bot role:**
  - `Manage Channels` — create/delete `#dm-*` channels
  - `Manage Webhooks` — create webhooks per channel for the persona rewrites
  - `Manage Messages` — delete the operator's Discord-typed bubble after outbound persona rewrite
  - `Send Messages`, `Embed Links`, `Attach Files`, `Read Message History`, `Use Slash Commands` — baseline
  When any are missing, Poster catches `Discord::AuthError`, sets `AppConfig["discord_permissions_blocked_at"]` (dashboard banner), records event as posted to avoid flood, warns once per batch.
- **Webhook-per-channel architecture:** every inbound message posts through the room's cached webhook so bubbles show the sender's Reddit display name + snoovatar, not the bot. Outbound dispatches also use the webhook to replace the operator's Discord bubble with their Reddit identity. Own-message username gets a `📤` suffix so it's visually distinct from the native Discord user if they're both in the channel.
- **Bulk channel reorder:** `PATCH /guilds/:id/channels` with `[{id, position}, ...]` — `Discord::ChannelReorderer` uses this to sort `#dm-*` most-recent-first on every material post. One call per sync batch, not per event.
- **Long-lived pages + `mix-blend-mode: overlay` + SVG `feTurbulence` on `position: fixed` full-viewport element** make Safari reclaim the tab for memory. The grain overlay in `tailwind.css` uses a pre-rasterized tile (`app/assets/grain.png`) without blend mode to avoid this.

## Architecture touchpoints

- `lib/bridge/application.rb` — wires threads (supervisor + gateway) + Puma + builds the service graph. `announce_online` emits a startup journal entry once per process. Read this first when making structural changes.
- `lib/admin/actions.rb` — single home for admin operations. Web controllers AND Discord slash commands both call into it. Never duplicate admin logic between entry points.
- `lib/admin/reconciler.rb` — per-room + bulk operations: rename, backfill, archive/unarchive, end_chat!/restore, delete_all_discord_channels!.
- `lib/matrix/sync_loop.rb` — the long-poll `/sync` loop. Advances the checkpoint only after successful dispatch. Hands invites to `InviteHandler` before handing timeline to the Poster.
- `lib/bridge/supervisor.rb` — wraps SyncLoop with retry, token-expiry auto-refresh (<1h left), T-7 cookie warning, hourly `PostedEvent.prune!`.
- `lib/bridge/journal.rb` — calls to it write a row to `event_log_entries` AND forward to `admin_notifier`/`logger`. Always prefer `@journal.info/warn/error/critical` over direct notifier calls.
- `lib/discord/poster.rb` — all the defensive logic: truncation, idempotency, rate-limit retry, webhook + channel 404 recovery, rename on username resolution, persona webhook with Reddit identity, auto-unarchive, terminated-room filter, AuthError → permissions-blocked flag + skip-to-avoid-flood, ChannelReorderer trigger at batch end.
- `lib/discord/outbound_dispatcher.rb` — Discord → Matrix relay. Records in SentRegistry so `/sync` echoes don't double-post. Reposts under the operator's Reddit persona (Matrix /profile → AppConfig cache → Reddit snoovatar → matrix_id localpart). Deletes the operator's original Discord bubble after the webhook repost.
- `lib/discord/channel_reorderer.rb` — sorts `#dm-*` most-recent-first via bulk reorder. Triggered from Poster (batch end) + OutboundDispatcher (per dispatch).
- `lib/discord/slash_command_router.rb` — global + per-#dm-* slash commands. `UNRESTRICTED_CHANNEL_COMMANDS` allow-list routes `/refresh /archive /endchat /room` past the `#commands`-only gate.
- `lib/discord/interaction_handler.rb` — sits between `Discord::Gateway` and the two routers. ACKs every interaction with a *deferred* callback (type 5 ephemeral for slash commands, type 6 for buttons) so the 3-second Discord deadline is met even when the router's work (Matrix `join_room`, reconciler operations, etc.) takes several seconds. The real response is PATCHed to `@original` via the 15-minute interaction-webhook window. Don't revert to the synchronous pattern — "This interaction failed" on Approve/Decline was caused by it.
- `lib/auth/refresh_flow.rb` — mints a fresh JWT via `/chat/` + registers it with Matrix via `/login`. Both steps are required.
- `app/views/layout.erb` — themed confirm dialog (all destructive forms use `data-confirm` attributes instead of `window.confirm`). Shift+R / Shift+C go through the same dialog via hidden forms.

## Style

- `rubocop-mmenanno` is authoritative. Configured as a rubocop plugin with `rubocop-minitest` / `rubocop-performance` / `rubocop-thread_safety`.
- Small classes: ~150 LOC hard ceiling. If a service grows past that, split it.
- Dependency injection: services that do HTTP take an injected `Faraday::Connection` (or equivalent); tests substitute fakes, no global patching.
- Value objects for IDs where they'd prevent confusion (e.g., `NormalizedEvent` as a `Data.define`).
- No silent fallbacks. Missing config = hard crash at boot with a precise error. Token invalid = loud alert, never a silent degrade.
- **Favor fixing rubocop violations over disabling them.** When a cop
  fires, the first move is to rewrite the code; if the cop is a bad fit
  for a whole pattern (not just one site), tune it in `.rubocop.yml`
  with a comment explaining why; inline `# rubocop:disable` is a last
  resort, only when the code really is the right shape and the cop's
  static analysis genuinely can't see it (e.g. `Thread.new` for a
  long-lived supervisor thread that has no pool equivalent).
  Every inline disable in the repo must have a nearby comment
  explaining why the cop's concern doesn't apply here.
- Current legitimate exemptions (project-level in `.rubocop.yml`):
  - `ThreadSafety/MutableClassInstanceVariable` excluded for Sinatra's
    `lib/bridge/web/**/*.rb` and `test/**/*.rb` — Sinatra routes and
    `setup do` blocks both run at instance level despite appearing
    class-level to static analysis.
  - `Metrics/ParameterLists: CountKeywordArgs: false` — every
    "too many params" hit in this codebase is DI constructors with
    all-keyword args, which are self-documenting; the cop's concern
    ("what does positional arg 6 mean?") doesn't apply.

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

Most of the original plan's open items are done. Remaining:

- **Phase 3 polish** — Reddit → Discord edit / redaction sync (if an operator edits or deletes on Reddit, we don't propagate).
- **Reddit cookie auto-rotation** — supervisor warns at T-7 days before `reddit_session` JWT expires, but the operator still has to paste a fresh cookie jar manually. An automated refresh path from a long-lived credential (if Reddit exposes one) would close this loop.
- **4-step setup wizard** — the plan originally spec'd a 4-step wizard (admin → Discord → Matrix → confirmation). We shipped step 1 + send the operator to `/settings` and `/auth`. Works; not a true wizard.
