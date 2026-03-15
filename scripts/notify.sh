#!/bin/bash
# vergissmeinnicht — Matrix Notification Helper
#
# Sends a message to a Matrix room via Client API (curl).
# Always unencrypted. Supports --notice flag.
#
# Usage:
#   ./notify.sh -m "message" --room "!room:server"
#   ./notify.sh --notice -m "bot status" --room "!room:server"

set -euo pipefail

# ──────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

if [ -f "$REPO_DIR/config.env" ]; then
    # shellcheck source=/dev/null
    . "$REPO_DIR/config.env"
fi

HOMESERVER="${MATRIX_HOMESERVER:?MATRIX_HOMESERVER not set}"
TOKEN="${MATRIX_TOKEN:?MATRIX_TOKEN not set}"

# ──────────────────────────────────────────
# Parse Arguments
# ──────────────────────────────────────────

MSG=""
ROOM=""
NOTICE=false

while [ $# -gt 0 ]; do
    case "$1" in
        -m|--message) MSG="$2"; shift 2 ;;
        --room) ROOM="$2"; shift 2 ;;
        -n|--notice) NOTICE=true; shift ;;
        -h|--help)
            echo "Usage: notify.sh [--notice] -m \"message\" --room \"!room:server\""
            exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$MSG" ] || [ -z "$ROOM" ]; then
    echo "Error: -m and --room are required" >&2
    exit 1
fi

# ──────────────────────────────────────────
# Send
# ──────────────────────────────────────────

MSGTYPE="m.text"
[ "$NOTICE" = true ] && MSGTYPE="m.notice"

ROOM_ENC=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$ROOM'))")
TXN="vmn_$(date +%s%N)"
BODY=$(python3 -c "import json,sys; print(json.dumps({'msgtype':'$MSGTYPE','body':sys.argv[1]}))" "$MSG")

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
    "${HOMESERVER}/_matrix/client/v3/rooms/${ROOM_ENC}/send/m.room.message/${TXN}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$BODY")

if [ "$HTTP_CODE" -eq 200 ]; then
    exit 0
else
    echo "Error: HTTP $HTTP_CODE" >&2
    exit 1
fi
