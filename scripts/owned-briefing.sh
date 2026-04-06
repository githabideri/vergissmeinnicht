#!/bin/bash
# vergissmeinnicht — generic room-owned daily briefing runner
#
# Machine-/deployment-specific values come from config.env (gitignored) or env vars.
# This keeps the repo reusable while allowing local room/agent wiring.

set -euo pipefail

DATE="${DATE_OVERRIDE:-$(date +%Y-%m-%d)}"
TARGET_DATE="${TARGET_DATE_OVERRIDE:-$(date -d yesterday +%Y-%m-%d 2>/dev/null || date -v-1d +%Y-%m-%d)}"
OC_DIR="${OC_DIR:-/opt/openclaw}"
OC_CMD="node ${OC_DIR}/openclaw.mjs"
WORKSPACE="${WORKSPACE:-/var/lib/clawdbot/workspace}"

BRIEFING_AGENT="${BRIEFING_AGENT:?Set BRIEFING_AGENT in config.env or env}"
BRIEFING_ROOM_ID="${BRIEFING_ROOM_ID:?Set BRIEFING_ROOM_ID in config.env or env}"
BRIEFING_SCOPE_LABEL="${BRIEFING_SCOPE_LABEL:-daily operational}"
BRIEFING_ARCHIVE_DIR="${BRIEFING_ARCHIVE_DIR:-${WORKSPACE}/agents/${BRIEFING_AGENT}/memory/briefings}"
BRIEFING_ARCHIVE_FILE="${BRIEFING_ARCHIVE_DIR}/${DATE}.md"
BRIEFING_PREV_FILE="${BRIEFING_ARCHIVE_DIR}/${TARGET_DATE}.md"
BRIEFING_TIMEOUT="${BRIEFING_TIMEOUT:-1200}"
BRIEFING_EXTRA_SOURCES="${BRIEFING_EXTRA_SOURCES:-}"
BRIEFING_FOCUS="${BRIEFING_FOCUS:-}"
BRIEFING_STYLE="${BRIEFING_STYLE:-Keep it concise and readable. Prefer short prose, not bullet spam. If a list is needed, keep it tiny.}"
BRIEFING_DELIVERY_INSTRUCTION="${BRIEFING_DELIVERY_INSTRUCTION:-Send the final briefing via the message tool to Matrix room ${BRIEFING_ROOM_ID} as the owning agent flow, not via servicebot.}"

mkdir -p "$BRIEFING_ARCHIVE_DIR"

PROMPT=$(cat <<EOF
Run the ${BRIEFING_SCOPE_LABEL} daily briefing for ${DATE}.

This briefing is for TODAY (${DATE}) and should be grounded in the completed prior day (${TARGET_DATE}).
Archive it before sending.

Archive file:
${BRIEFING_ARCHIVE_FILE}

Data sources to use if available:
1. Previous same-room briefing for dedup/style continuity: ${BRIEFING_PREV_FILE}
2. Use the cron tool to inspect jobs relevant to this briefing scope.
${BRIEFING_EXTRA_SOURCES}

Focus:
${BRIEFING_FOCUS}

Also include a compact section for quiet successful jobs, but ONLY if they really:
- ran successfully today
- are relevant to this briefing scope
- produced no separate actionable message

Required structure:
1. Short opening line
2. Main update
3. Quiet successful jobs (only if applicable)
4. Immediate watchpoints / open items (only if relevant)

Default brevity rule:
- Treat this as a room briefing, not a report.
- Prefer a compact operator-facing result over a complete recap.
- Only include the few things someone actually needs this morning.

Style:
${BRIEFING_STYLE}

Hard rules:
- No stale filler.
- Do not drift into daily-memory style chronology unless explicitly requested.
- Save the full final briefing markdown to ${BRIEFING_ARCHIVE_FILE}
- ${BRIEFING_DELIVERY_INSTRUCTION}
- After sending, reply NO_REPLY
EOF
)

cd "$OC_DIR"
timeout "$BRIEFING_TIMEOUT" $OC_CMD agent --agent "$BRIEFING_AGENT" --message "$PROMPT" --timeout "$BRIEFING_TIMEOUT"
