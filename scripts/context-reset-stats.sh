#!/bin/bash
# vergissmeinnicht — Context Reset Stats
#
# Sends activity stats to Matrix rooms as m.notice messages.
# Only sends to rooms where human activity > 0.
#
# Usage: ./context-reset-stats.sh
# Called by: morning-pipeline.sh (Phase 0)

set -euo pipefail

# ──────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# Load config
if [ -f "$REPO_DIR/config.env" ]; then
    # shellcheck source=/dev/null
    . "$REPO_DIR/config.env"
fi

# Yesterday's date
DATE=$(date -d yesterday +%Y-%m-%d 2>/dev/null || date -v-1d +%Y-%m-%d)
YESTERDAY_START=$(date -d "$DATE" +%s 2>/dev/null || date -jf "%Y-%m-%d" "$DATE" +%s)
YESTERDAY_START_MS=$((YESTERDAY_START * 1000))

HOMESERVER="${MATRIX_HOMESERVER:?MATRIX_HOMESERVER not set}"
TOKEN="${MATRIX_TOKEN:?MATRIX_TOKEN not set}"
PLANNING_ROOM="${PLANNING_ROOM:-planning}"

# ──────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────

url_encode() {
    python3 -c "import urllib.parse; print(urllib.parse.quote('$1'))"
}

json_escape() {
    python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$1"
}

send_notice() {
    local room_id="$1"
    local message="$2"
    local room_enc
    room_enc=$(url_encode "$room_id")
    local txn="vmn_$(date +%s%N)"
    local body
    body=$(json_escape "$message")

    curl -sf -X PUT \
        "${HOMESERVER}/_matrix/client/v3/rooms/${room_enc}/send/m.room.message/${txn}" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"msgtype\":\"m.notice\",\"body\":${body}}" > /dev/null
}

get_room_stats() {
    local room_id="$1"
    local room_enc
    room_enc=$(url_encode "$room_id")

    local messages
    messages=$(curl -sf "${HOMESERVER}/_matrix/client/v3/rooms/${room_enc}/messages?dir=b&limit=200" \
        -H "Authorization: Bearer ${TOKEN}" 2>/dev/null || echo '{"chunk":[]}')

    echo "$messages" | jq -r --arg start "$YESTERDAY_START_MS" '
        [.chunk[]
         | select(.origin_server_ts >= ($start | tonumber))
         | select(.origin_server_ts < (($start | tonumber) + 86400000))
        ] | {
            total: length,
            human: [.[] | select(.sender | test("@(m|martin|admin):"))] | length,
            tokens: (length * 50)
        } | "\(.total) \(.human) \(.tokens)"
    '
}

# ──────────────────────────────────────────
# Main
# ──────────────────────────────────────────

# Parse MATRIX_ROOMS array (format: "!room_id:server|name")
if [ -z "${MATRIX_ROOMS:-}" ]; then
    echo "[$(date +%H:%M:%S)] No MATRIX_ROOMS configured, skipping context reset"
    exit 0
fi

for room_entry in "${MATRIX_ROOMS[@]}"; do
    ROOM_ID="${room_entry%%|*}"
    ROOM_NAME="${room_entry##*|}"

    # Get stats
    read -r TOTAL HUMAN TOKENS <<< "$(get_room_stats "$ROOM_ID" 2>/dev/null || echo "0 0 0")"

    # Only send if human activity > 0
    if [ "${HUMAN:-0}" -gt 0 ]; then
        BOT=$((TOTAL - HUMAN))

        if [ "$ROOM_NAME" = "$PLANNING_ROOM" ]; then
            # Long format for planning room
            MESSAGE="🌅 Context reset — $DATE

Activity yesterday:
• ${ROOM_NAME}: ${TOTAL} messages (${HUMAN} human, ${BOT} bot, ~${TOKENS} tokens)

📝 Daily note: memory/${DATE}.md"
        else
            # Short format for other rooms
            MESSAGE="🌅 ${ROOM_NAME}: ${TOTAL} msg (${HUMAN} human, ~${TOKENS}tok) 💾 memory/${DATE}.md"
        fi

        send_notice "$ROOM_ID" "$MESSAGE"
        echo "[$(date +%H:%M:%S)] ✅ Sent to $ROOM_NAME ($TOTAL msg, $HUMAN human)"
    else
        echo "[$(date +%H:%M:%S)] ⏭️  Skipped $ROOM_NAME (no human activity)"
    fi
done

exit 0
