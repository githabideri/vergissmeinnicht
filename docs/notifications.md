# Notification System

## Overview

vergissmeinnicht uses a lightweight Matrix bot for sending notifications to team channels. The bot sends **unencrypted** messages via the Matrix Client API (curl), avoiding the complexity of E2EE key management.

## Setup

### 1. Create a Bot User

On your Matrix homeserver (Synapse):

```bash
# Register a bot user
register_new_matrix_user -c /etc/matrix-synapse/homeserver.yaml

# Username: servicebot
# Password: (generate a strong password)
# Admin: no
```

### 2. Get an Access Token

```bash
curl -X POST "https://matrix.example.com/_matrix/client/v3/login" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "m.login.password",
    "user": "servicebot",
    "password": "YOUR_PASSWORD"
  }' | jq -r '.access_token'
```

Save the token in your config:

```bash
# config.env
MATRIX_TOKEN="syt_your_token_here"
MATRIX_HOMESERVER="https://matrix.example.com"
```

### 3. Join Rooms

Invite the bot to your rooms, then accept:

```bash
ROOM="!encoded_room_id:server"
curl -X POST "https://${MATRIX_HOMESERVER}/_matrix/client/v3/join/${ROOM}" \
  -H "Authorization: Bearer ${MATRIX_TOKEN}"
```

### 4. Configure Room List

In `config.env`:

```bash
# Format: "!room_id:server|friendly_name"
MATRIX_ROOMS=(
  "!abc123:matrix.example.com|planning"
  "!def456:matrix.example.com|engineering"
  "!ghi789:matrix.example.com|monitoring"
)
```

## Message Types

### m.notice (Recommended for Bots)

```bash
curl -sf -X PUT \
  "https://${HOMESERVER}/_matrix/client/v3/rooms/${ROOM}/send/m.room.message/${TXN}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"msgtype":"m.notice","body":"Activity stats..."}'
```

**m.notice** is the Matrix convention for bot/automated messages:
- Displayed slightly differently in clients (often dimmed)
- Other bots typically ignore m.notice to prevent loops
- Won't trigger AI agent responses

### m.text (For Important Alerts)

```bash
# Same as above but with "m.text" — treated as a regular message
-d '{"msgtype":"m.text","body":"⚠️ Pipeline FAILED"}'
```

Use m.text sparingly — only for alerts that need human attention.

## The Notification Script

`scripts/notify.sh` is a minimal wrapper around curl:

```bash
#!/bin/bash
# Usage: notify.sh [--notice] -m "message" --room "!room:server"

# Reads MATRIX_TOKEN and MATRIX_HOMESERVER from config.env
# Sends via Matrix Client API (always unencrypted)
# Supports --notice flag for m.notice type
```

### Why Unencrypted?

1. **Simplicity** — E2EE requires managing Olm/Megolm sessions, device keys, and key backup
2. **Reliability** — Encrypted messages can fail silently if keys rotate
3. **Readability** — Admin can always read bot messages on the server
4. **Bot convention** — Status messages don't need encryption

**If your rooms require encryption**, consider:
- Making bot rooms unencrypted (separate from private rooms)
- Using a Matrix SDK with E2EE support (matrix-nio, matrix-commander)
- Accepting that some clients may not display unencrypted messages in encrypted rooms

## Context Reset Format

### Short Format (Agent Channels)

```
🌅 engineering: 24 msg (12 human, ~1200tok) 💾 memory/2026-03-14.md
```

### Long Format (Planning Channel)

```
🌅 Context reset — 2026-03-14

Activity yesterday:
• planning: 24 messages (12 human, 12 bot, ~1200 tokens)
• engineering: 156 messages (45 human, 111 bot, ~7800 tokens)
• monitoring: 8 messages (bot only, ~400 tokens)

📝 Daily note: memory/2026-03-14.md
```

### Conditional Sending

Only sends to rooms where **human activity > 0**. Bot-only rooms are skipped — no spam.

## Troubleshooting

### Messages Not Appearing

1. **Check Synapse has the message:**
   ```bash
   curl "https://${HOMESERVER}/_matrix/client/v3/rooms/${ROOM}/messages?dir=b&limit=5" \
     -H "Authorization: Bearer ${TOKEN}" | jq '.chunk[].content.body'
   ```

2. **Token expired?**
   ```bash
   curl "https://${HOMESERVER}/_matrix/client/v3/account/whoami" \
     -H "Authorization: Bearer ${TOKEN}"
   # Should return {"user_id":"@servicebot:server"}
   ```

3. **Bot not in room?**
   ```bash
   curl "https://${HOMESERVER}/_matrix/client/v3/joined_rooms" \
     -H "Authorization: Bearer ${TOKEN}" | jq '.joined_rooms[]'
   ```

4. **Client sync issue?** — Hard refresh (Ctrl+Shift+R) in Element

### 401 Unauthorized

Token is missing or expired. Generate a new one (see Setup step 2).

### Messages Visible on Server but Not in Client

This can happen when sending **unencrypted messages to encrypted rooms**. Some clients filter them. Solutions:
- Use unencrypted rooms for bot notifications
- Check client settings for "show unencrypted messages"
- Verify with a different Matrix client
