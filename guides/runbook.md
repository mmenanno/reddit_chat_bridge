# Runbook

Operating the bridge when it misbehaves. These are the common failure
modes and the recipes for getting back to a good state.

## First-principles checks

Before chasing specifics, answer these:

- Is the container running? `ssh unraid "docker ps | grep reddit_chat_bridge"`
- Is it healthy? `docker ps` shows `(healthy)` in the STATUS column once
  `/health` returns 200.
- What does the web UI dashboard show? The Matrix badge is the fastest
  tell for auth-level problems.
- What's in the container log?
  `ssh unraid "docker logs --tail 200 reddit_chat_bridge"`

## `M_UNKNOWN_TOKEN` — Reddit token expired or invalidated

Symptoms: dashboard shows **Matrix paused**, `#app-status` has
`🔴 @everyone Matrix auth failed`, no new Reddit messages appear in
Discord.

Fix:

1. On `/auth`, either:
   - (Preferred, if configured) do nothing — the supervisor auto-refreshes
     from the stored `reddit_session` cookie on its next tick.
   - Drag the **Reddit → Bridge JWT** bookmarklet from `/auth` onto your
     bookmarks bar if you haven't already. Click it on any logged-in
     reddit.com tab — the fresh JWT lands on your clipboard. Paste into
     the "Matrix access token" field → **Probe & save**.
2. Dashboard flips back to green within a few seconds; sync resumes.
3. No container restart needed — the Matrix client reads the current
   token from `AuthState` on each request.

## Discord channel manually deleted

Symptoms: the bridge posts a `NotFound` error for one specific conversation
but the others continue normally.

Short-term: the room's `Room` record still has the stale
`discord_channel_id`. The Phase 3 **reconcile** action will recreate it
automatically; for now:

1. In the SQLite DB (`/mnt/cache/appdata/reddit_chat_bridge/state.sqlite3`),
   `UPDATE rooms SET discord_channel_id = NULL WHERE discord_channel_id = '<deleted>';`
2. Next incoming message in that room triggers a fresh
   `ChannelIndex.ensure_channel` call and creates a new `#dm-<username>`.

## Bridge posts look stuck

Symptoms: `/sync` seems to advance but no Discord messages appear.

- Dashboard **Discord** indicator: is it green?
- `/actions` → **Test Discord** (Phase 2+) — when that lands, it'll be a
  one-click probe that round-trips to `#app-status`.
- For now, manually verify: is the bot still a member of the server? Is
  the bot token in `/settings` still valid (Discord rotates tokens when
  the admin hits **Reset Token**)?

## Apparent message loss across a restart

Symptoms: a Reddit message sent while the bridge was down didn't appear
after restart.

By design the bridge should never lose messages: the `sync_checkpoint`
row only advances *after* a batch posts successfully. If you truly saw
loss, something pathological happened. Capture:

- `docker logs` covering the outage window.
- The current `sync_checkpoint.next_batch_token`.
- A fresh `/sync` payload via `bin/spike_matrix_sync` to confirm the
  events are still retrievable from Reddit.

Then restore: clear the checkpoint with **Actions → Resync now**; the
next iteration pulls recent history and re-posts anything that isn't
already marked by `Room#last_event_id`.

## Resetting everything

Total nuke, rebuild from scratch:

1. Stop the container in Unraid UI.
2. `rm /mnt/cache/appdata/reddit_chat_bridge/state.sqlite3`
3. Start the container. You'll land on `/setup` again.
