# Extracting the Reddit Matrix access token

Reddit's chat is built on Matrix (homeserver `matrix.redditspace.com`),
but Reddit doesn't publish an auth endpoint you can call programmatically.
The bridge works around this the way every community Reddit-Matrix client
does: you extract an existing bearer token from your logged-in browser
session and paste it into the bridge's `/auth` page.

Tokens last roughly 24 hours (Reddit issues them as short-lived JWTs with
an `exp` claim). When the bridge hits `M_UNKNOWN_TOKEN`, you repeat this
procedure and paste the fresh value. The bridge probes the new token via
`whoami` before saving, so a bad paste never clobbers a working token.

## Procedure

1. **Open chat.reddit.com** in a logged-in session. Any browser is fine.
2. Open DevTools. **Network** tab.
3. In the filter bar, type `matrix`. This narrows the list to the
   `/_matrix/client/*` traffic your browser is making to the Reddit Matrix
   server.
4. Click any chat, or any existing request that's already in the list —
   `whoami`, `sync`, or `messages` all work. You want any row whose path
   starts with `_matrix/client/`.
5. In the request detail, switch to the **Headers** tab.
6. Scroll to **Request Headers** → find `Authorization`. The value looks
   like `Bearer eyJhbGciOi…` (a long JWT, often 1000+ characters).
7. Right-click the value → **Copy value** (the exact wording varies by
   browser).

## Paste it into the bridge

1. Open the bridge's web UI → **Auth** → **Replace the token**.
2. Paste into the textarea. The `Bearer ` prefix is harmless — the bridge
   strips it either way.
3. Click **Probe & save**. If Reddit accepts the token, the bridge calls
   `/account/whoami`, learns your canonical `@t2_…:reddit.com` user id,
   and saves both to the `auth_state` row. The sync loop resumes on its
   next tick.

## When it goes wrong

- **"Reddit rejected that token"** — the token was mangled during copy, or
  it's already invalidated. Re-extract (step 1 above), paste again. Don't
  keep pasting the same bad value.
- **"Couldn't reach Reddit"** — network-level problem. Check whether
  chat.reddit.com loads at all.
- **"Matrix user ID in settings differs from the server's"** — only
  surfaces in logs; the bridge always trusts the `whoami` response. Go to
  **Settings** and update `matrix_user_id` if you want the two to agree.

## Security note

The access token is the full key to your Reddit chat account. Treat it
like a password. The `/auth` page runs over HTTPS via TSDProxy; the token
is stored in the SQLite `auth_state` row on Unraid's `appdata` volume
(not synced to any cloud service by default).
