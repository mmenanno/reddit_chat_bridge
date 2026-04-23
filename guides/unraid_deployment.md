# Deploying to Unraid

Creating the container via the Unraid web UI — the only supported path
(the project's CLAUDE.md gotcha is explicit: never `docker run` new
containers, their template XML is the source of truth).

## Prerequisites

- The image is published at `ghcr.io/mmenanno/reddit_chat_bridge:latest`
  by the `Release` workflow on every push to `main`.
- You've completed `guides/bot_setup.md` and have the Discord IDs handy
  (they go into the web UI after the container is up, not into the
  Unraid template).
- SSH access to the Unraid host: `ssh unraid`.

## 1. Add the container

Unraid UI → **Docker** → **Add Container**.

### Top section

| Field                     | Value                                                                                     |
| ------------------------- | ----------------------------------------------------------------------------------------- |
| **Name**                  | `reddit_chat_bridge`                                                                      |
| **Repository**            | `ghcr.io/mmenanno/reddit_chat_bridge:latest`                                              |
| **Registry URL**          | `https://github.com/mmenanno/reddit_chat_bridge/pkgs/container/reddit_chat_bridge`        |
| **Network Type**          | `Custom : proxynet` (shared with Traefik/TSDProxy like every other service)               |
| **Fixed IP address**      | *(leave blank)*                                                                           |
| **Use Tailscale**         | OFF (we expose via TSDProxy, not a sidecar tailscaled)                                    |
| **Console shell command** | `Shell`                                                                                   |
| **Privileged**            | OFF                                                                                       |
| **Icon URL**              | *(optional — e.g. the Reddit orange-R or a custom bridge icon)*                           |
| **WebUI**                 | `http://[IP]:[PORT:4567]/` (lets Unraid's "WebUI" action open the dashboard in a browser) |
| **Extra Parameters**      | *(leave blank)*                                                                           |
| **Post Arguments**        | *(leave blank)*                                                                           |

### Paths (Add another Path, Port, Variable… → Path)

The SQLite database and any future runtime state live under `/app/state`
inside the container. Map the Unraid appdata dir onto it so the DB
persists across container recreations:

| Name      | Container Path | Host Path                               | Access Mode |
| --------- | -------------- | --------------------------------------- | ----------- |
| `appdata` | `/app/state`   | `/mnt/cache/appdata/reddit_chat_bridge` | Read/Write  |

The container runs as uid/gid `1000:1000` (the `app` user baked into the
image). Before saving the template, create the appdata dir and match its
ownership so writes to the SQLite DB succeed:

```bash
ssh unraid "mkdir -p /mnt/cache/appdata/reddit_chat_bridge && chown -R 1000:1000 /mnt/cache/appdata/reddit_chat_bridge"
```

### Ports

TSDProxy reaches the container over the shared `proxynet` network by
container name, so publishing the port to the Unraid host is optional
— only add this if you want LAN access for debugging without going
through the tailnet.

| Name               | Container Port | Host Port | Protocol |
| ------------------ | -------------- | --------- | -------- |
| `web` *(optional)* | `4567`         | `4567`    | TCP      |

### Environment variables

Every secret goes into the web UI (`/settings` and `/auth`) after the
container is running — the container template itself doesn't need any
secrets. Only override an env var here if you want to deviate from the
defaults baked into the Dockerfile:

| Name        | Default                            | Override only if…                   |
| ----------- | ---------------------------------- | ----------------------------------- |
| `PORT`      | `4567`                             | You need a different internal port  |
| `LOG_LEVEL` | `info`                             | Debugging: bump to `debug`          |
| `RACK_ENV`  | `production` (from Dockerfile ENV) | *(don't) — staging isn't supported* |

### Labels (TSDProxy exposure)

Add one label per entry:

| Name                      | Value                |
| ------------------------- | -------------------- |
| `tsdproxy.enable`         | `true`               |
| `tsdproxy.name`           | `reddit-chat-bridge` |
| `tsdproxy.container_port` | `4567`               |

Once the container starts, TSDProxy picks up those labels and publishes
the web UI at `https://reddit-chat-bridge.<your-tailnet>.ts.net/`.

## 2. Apply

Hit **APPLY**. Unraid pulls the image from GHCR (~200–300 MB first time)
and starts the container. When the status column flips to
`running (healthy)` — the `/health` endpoint has come up — you're good.

Confirm via CLI:

```bash
ssh unraid "docker ps --filter name=reddit_chat_bridge --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
ssh unraid "docker logs --tail 50 reddit_chat_bridge"
```

Health tells you Puma is up and the DB is queryable; it intentionally
does NOT reflect Matrix or Discord connectivity, because those only get
working config after you finish the web UI wizard.

## 3. Finish setup in the web UI

1. Open `https://reddit-chat-bridge.<your-tailnet>.ts.net/`. First load
   lands on `/setup`.
2. Create the admin account (12+ char password).
3. `/settings` — paste the Discord IDs from `guides/bot_setup.md`. Save.
   (Matrix homeserver is hardcoded; the Matrix user ID is auto-discovered
   from `/account/whoami` after the first successful auth.)
4. `/auth` — paste your `reddit_session` cookie value (the long-lived
   path) or a fresh Matrix JWT (the short-lived fallback). The `/auth`
   page has a drag-to-bookmark helper for the JWT that skips DevTools
   entirely. Probe & save.
5. **Restart the container** once after the first save so config.ru
   picks up the now-complete config and spins up the background sync
   thread. Subsequent settings/token changes take effect live — only the
   first boot needs this extra step.

## 4. Updating later

The `Release` workflow re-publishes `:latest` on every merge to `main`
plus a `:<short-sha>` tag. Unraid's "Check for Updates" button picks up
the new `:latest` digest; hit **Update** and the container recreates
against the new image while the SQLite volume survives.

If something goes sideways with a new release, pin to a specific SHA by
editing the container's **Repository** field to
`ghcr.io/mmenanno/reddit_chat_bridge:<short-sha>`.

## Troubleshooting

- **Container won't start** — `docker logs` for Ruby-level errors (bad
  migration, malformed Gemfile.lock, etc.).
- **WebUI returns 502 via TSDProxy** — TSDProxy can't reach the
  container. Check that the container is actually on `proxynet`
  (`docker inspect reddit_chat_bridge | grep -A5 Networks`) and that the
  three `tsdproxy.*` labels are set.
- **"This site can't be reached" on the tailnet URL** — TSDProxy hasn't
  registered it yet. `docker logs tsdproxy` usually shows why (often a
  label typo or a restart loop).
- **Permission errors writing to /app/state** — the container runs as
  uid/gid `1000:1000`. Chown the appdata dir to match:
  `sudo chown -R 1000:1000 /mnt/cache/appdata/reddit_chat_bridge`.
