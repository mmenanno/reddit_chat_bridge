# Discord bot + server setup

Before the bridge can post anything, you need a Discord application, a bot
identity for it, a dedicated Discord server laid out in a specific way,
and a handful of IDs copied into the `/settings` page.

## 1. Create the dedicated Discord server

Create a new Discord server (or reuse an existing personal one) named
**Reddit Chat Bridge**. Enable Developer Mode so you can right-click to
copy IDs: **User Settings → Advanced → Developer Mode**.

Build this layout:

- **📥 Reddit DMs** *(category)* — the bridge auto-creates `#dm-<username>`
  channels under this category; you don't pre-create any.
- **🔧 Admin** *(category)*
  - `#app-status` — critical alerts from the bridge. `@everyone` ping on
    fatal errors only.
  - `#app-logs` — info/warn lines (a rolling operational log).
  - `#commands` — Phase 2 slash-command surface. Set permissions to
    restrict it to the `@BotAdmin` role you'll create below.

Create a `@BotAdmin` role and assign it to yourself. Deny the `@everyone`
role access to `#commands`; allow `@BotAdmin`.

## 2. Create the Discord application + bot

1. Open the [Discord Developer Portal](https://discord.com/developers/applications).
2. **New Application** → name it **Reddit Chat Bridge** (matches the
   dedicated server name; Discord display-names are title-case with spaces).
3. In the left sidebar, click **Bot** → **Add Bot**.
4. Under **Privileged Gateway Intents**, toggle on **Message Content Intent**
   (Phase 2 needs this; harmless to enable now).
5. Click **Reset Token** under the bot's name to reveal the bot token. Copy
   it — you'll paste it into the bridge's `/settings` page in step 4.

## 3. Invite the bot to your server

Still in the Developer Portal:

1. **OAuth2 → URL Generator**
2. Scopes: check **bot** and **applications.commands**
3. Bot Permissions: check **Manage Channels**, **Send Messages**,
   **Embed Links**, **Attach Files**, **Read Message History**, and
   **Use Slash Commands**. (The Discord permission was renamed from
   "Use Application Commands" — same capability, newer label.)
4. Copy the generated URL and open it in a browser. Pick the Reddit Chat
   Bridge server and authorize.

The bot will appear in your server's member list, offline until the bridge
container is running and configured.

## 4. Wire the IDs into the bridge

Back in the Discord client (Developer Mode on):

- Right-click the server name → **Copy Server ID** → this is your
  `discord_guild_id`.
- Right-click the **📥 Reddit DMs** category → **Copy Channel ID** →
  `discord_dms_category_id`.
- Right-click each admin channel → **Copy Channel ID** →
  `discord_admin_status_channel_id`, `discord_admin_logs_channel_id`,
  `discord_admin_commands_channel_id`.

Open the bridge's web UI at
`https://reddit-chat-bridge.<your-tailnet>.ts.net/settings` and paste
each ID into the matching field, along with the bot token from step 2.
Hit **Save**.

## 5. Confirm the bot can talk

With config saved, the bridge should be able to post startup banners to
`#app-status`. If you don't see `🟢 reddit_chat_bridge started`:

- Check the container logs on Unraid:
  `ssh unraid "docker logs --tail 100 reddit_chat_bridge"`.
- Common causes: token typo, guild ID belongs to a different server, bot
  wasn't actually invited, bot lacks permission on the category.
