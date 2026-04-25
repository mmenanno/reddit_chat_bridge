# Deploying reddit_chat_bridge

The bridge is a single Docker container that runs as uid/gid `1000:1000`, exposes a web UI on port 4567, and persists everything to SQLite under `/app/state`. Any host that can run a Docker container 24/7 will work.

## Prerequisites

- Docker (any reasonably recent release).
- A persistent host directory for the SQLite database. Anything you control is fine: `./state`, `/var/lib/reddit_chat_bridge`, your NAS appdata share, etc.
- A way to reach port 4567 from your browser. LAN, Tailscale, a reverse proxy, an SSH tunnel — your call. The bridge does not do its own TLS termination.

## Option A: `docker run`

```bash
mkdir -p ./state
sudo chown 1000:1000 ./state

docker run -d \
  --name reddit_chat_bridge \
  --restart unless-stopped \
  --user 1000:1000 \
  -p 4567:4567 \
  -v "$PWD/state:/app/state" \
  ghcr.io/mmenanno/reddit_chat_bridge:latest
```

The `chown` matters: the container runs as uid/gid `1000:1000`, and SQLite needs to be able to write to the volume. If the host directory is owned by another user, you'll see permission errors in `docker logs`.

## Option B: `docker compose`

The repo ships a working [`docker-compose.yml`](../docker-compose.yml) at the root. Either copy it next to your other compose files, or clone the repo and run it in place:

```bash
mkdir -p ./state
sudo chown 1000:1000 ./state
docker compose up -d
```

Tail the logs to confirm boot:

```bash
docker compose logs -f reddit_chat_bridge
```

Health is reported via Docker's healthcheck (`/health` on port 4567). `docker ps` shows `(healthy)` once Puma is up and the database is queryable.

## First-run setup

1. Open `http://<your-host>:4567/`. First load lands on `/setup`.
2. Create the admin account (12+ character password).
3. The wizard at `/guide/bot-setup` walks through Discord application creation, builds an invite URL with the right permissions baked in, and live-tracks which configuration fields are still missing. Save when it goes green.
4. On `/auth`, paste your `reddit_session` cookie (preferred, ~6 month lifetime) or a fresh Matrix JWT (short-lived, ~24h fallback). The drag-to-bookmark helper on `/auth` grabs a JWT from any logged-in reddit.com tab without DevTools. Probe and save.
5. **Restart the container once** so the supervisor picks up the now-complete config and starts the background sync thread:

   ```bash
   docker restart reddit_chat_bridge
   # or
   docker compose restart reddit_chat_bridge
   ```

   Subsequent settings or token changes take effect live; only the first boot needs this.

## Updating

The `:latest` tag is republished on every push to `main` after CI passes. Pull and recreate:

```bash
docker compose pull
docker compose up -d
```

The `state/` volume survives the recreation; the SQLite database (with all your settings, room links, dedup state, and encrypted Reddit cookies) is preserved.

### Pinning to a specific version

The CI workflow tags every release as `:v<version>` (read from the `VERSION` file) and `:sha-<short>`. To pin, set the `image:` line in your compose file or `docker run` to the specific tag:

```yaml
image: ghcr.io/mmenanno/reddit_chat_bridge:v1.11.0
```

Useful when a `:latest` rollout misbehaves and you want to roll back without waiting for a fix.

## Reverse proxy and Tailscale

The bridge ships only the web port; how you expose it is up to you. A few patterns that work:

- **Local network only.** `docker run -p 4567:4567` and access via `http://<host-lan-ip>:4567/` from your LAN. Don't do this on a publicly-routable host.
- **Tailscale sidecar.** Add a Tailscale or Headscale container alongside the bridge, or run the host on Tailscale and access via the host's tailnet hostname.
- **Reverse proxy (Traefik / Caddy / nginx).** Put the bridge on a Docker network shared with your reverse proxy and route a hostname to `reddit_chat_bridge:4567`. Caddy automation handles TLS automatically.

The bridge has no built-in auth proxy or IP allow-list, so don't expose it raw to the public internet. The admin login (`/login`) is bcrypt-protected, but it's a single-account login form — keep it on a trusted network.

## Configuration

| Env var | Default | Notes |
| ------- | ------- | ----- |
| `PORT` | `4567` | Web UI bind port. |
| `RACK_ENV` | `production` | Don't override for production. |
| `SESSION_SECRET` | auto-generated | Optional. If unset, a value is generated on first boot and persisted in the database. |

Everything else (Discord bot token, application ID, guild ID, channel IDs, operator user IDs, Reddit auth) lives in the SQLite database and is edited through the web UI.

## Troubleshooting

- **`(unhealthy)` in `docker ps`** — check `docker logs` for Ruby-level errors. Common causes: bad volume permissions (chown to `1000:1000`), corrupt database, port collision.
- **Web UI loads but says "no Matrix connection"** — expected before `/auth` has been completed. Finish the first-run setup.
- **Permission errors writing to `/app/state`** — `sudo chown -R 1000:1000 <your-state-dir>` and recreate the container.
- **Reddit auth keeps failing** — the cookie may have expired or been invalidated by Reddit (logging out anywhere triggers this). Grab a fresh `reddit_session` cookie from a logged-in browser tab and paste it on `/auth`.
- **Discord posts aren't appearing** — check `/settings` for the right channel IDs, verify the bot is in the server, and confirm the role has the permissions the wizard listed (Manage Channels, Manage Webhooks, Manage Messages, Send Messages, Embed Links, Read Message History, Use Slash Commands).

## Note for Unraid users

Unraid containers should be created via the Unraid web UI (Docker → Add Container) so the template XML is the source of truth, but everything else in this guide applies. The mappings to set:

- **Repository:** `ghcr.io/mmenanno/reddit_chat_bridge:latest`
- **Path:** Container `/app/state` → Host `/mnt/user/appdata/reddit_chat_bridge` (or wherever your appdata lives)
- **Port:** Container `4567` → Host `4567` (optional if you reach the container via a proxy on the same Docker network)
- **uid/gid:** the container runs as `1000:1000`. Chown the appdata dir to match before the first start, or you'll see SQLite write errors.
