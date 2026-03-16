#!/bin/bash
# vergissmeinnicht — Morning Pipeline Orchestrator
#
# Single-Agent Prefix Cache architecture (see docs/design-decisions.md #11, #12):
#   - ONE agent writes ALL per-agent summaries → system prompt cached once
#   - "Sacrifice agent" warmup primes the prefix cache before parallel burst
#   - MEMORY.md excerpts pre-injected into prompts → no hallucinated "no activity"
#
# Phases:
#   0: Sacrifice Agent warmup + Context Reset (parallel)
#   1: Per-Agent Summaries (parallel, all through SUMMARY_AGENT)
#   2: Daily Summary (aggregates agent notes)
#   3: Briefing + Memory Sync (parallel)
#   4: Status Report
#
# Usage:  ./morning-pipeline.sh [--dry-run]
# Cron:   0 6 * * * /path/to/morning-pipeline.sh

set -uo pipefail
# NOTE: No set -e. Orchestrator handles failures per-phase.

# ──────────────────────────────────────────
# Configuration (load from config.env if present)
# ──────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

if [ -f "$REPO_DIR/config.env" ]; then
    # shellcheck source=/dev/null
    . "$REPO_DIR/config.env"
fi

DATE=$(date +%Y-%m-%d)
YESTERDAY=$(date -d yesterday +%Y-%m-%d 2>/dev/null || date -v-1d +%Y-%m-%d)

# Paths (override via config.env)
LOG_DIR="${LOG_DIR:-$REPO_DIR/logs}"
OC_DIR="${OC_DIR:-/opt/openclaw}"
OC_CMD="node ${OC_DIR}/openclaw.mjs"
WORKSPACE="${WORKSPACE:-$REPO_DIR}"
AGENT_DIR="${AGENT_DIR:-$WORKSPACE/agents}"
SUMMARY_DIR="${SUMMARY_DIR:-$WORKSPACE/summaries}"
LOG="${LOG_DIR}/morning-pipeline-${DATE}.log"
DEBUG_LOG="${LOG_DIR}/morning-pipeline-${DATE}-debug.log"

# Single-Agent strategy: ALL summaries through one agent (prefix cache)
SUMMARY_AGENT="${SUMMARY_AGENT:-localbot-planning}"

# Agent list (override via config.env)
if [ -z "${AGENTS+x}" ]; then
    AGENTS=(agent1 agent2 agent3)  # Replace with your agent names
fi

# Agent workspace paths — override for agents with special mounts
# Example: AGENT_WORKSPACE[mox]="/path/to/mounted/lxc/mox"
declare -A AGENT_WORKSPACE

# Session transcripts path pattern
OC_HOME="${OC_HOME:-$HOME/.openclaw}"

# Timeouts
WARMUP_TIMEOUT="${WARMUP_TIMEOUT:-120}"
AGENT_SUMMARY_TIMEOUT="${AGENT_SUMMARY_TIMEOUT:-300}"
DAILY_SUMMARY_TIMEOUT="${DAILY_SUMMARY_TIMEOUT:-600}"
BRIEFING_TIMEOUT="${BRIEFING_TIMEOUT:-600}"
MEMORY_SYNC_TIMEOUT="${MEMORY_SYNC_TIMEOUT:-60}"

DRY_RUN=""
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN="true"

mkdir -p "$LOG_DIR" "$SUMMARY_DIR"

# ──────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

agent_workspace() {
    local agent="$1"
    echo "${AGENT_WORKSPACE[$agent]:-${AGENT_DIR}/${agent}}"
}

# Pre-inject MEMORY.md excerpt for a date (Design Decision #12)
memory_excerpt() {
    local agent="$1" date="$2"
    local memory_md
    memory_md="$(agent_workspace "$agent")/MEMORY.md"
    [ -f "$memory_md" ] && grep -B2 -A20 "$date" "$memory_md" 2>/dev/null | head -60
}

oc_agent() {
    local agent="$1" message="$2" timeout_s="${3:-180}"
    if [ -n "$DRY_RUN" ]; then
        log "    [DRY-RUN] openclaw agent --agent $agent (timeout: ${timeout_s}s)"
        return 0
    fi
    cd "$OC_DIR" && timeout "$timeout_s" $OC_CMD agent \
        --agent "$agent" --message "$message" --timeout "$timeout_s" \
        --json >> "$DEBUG_LOG" 2>&1
}

# Status tracking (temp file for subshell propagation)
STATUS_FILE=$(mktemp)
echo "ok" > "$STATUS_FILE"
set_degraded() { echo "degraded" > "$STATUS_FILE"; }
get_status() { cat "$STATUS_FILE"; }
PHASE_RESULTS=()

# ──────────────────────────────────────────

log "════════════════════════════════════════"
log "💙 vergissmeinnicht — Morning Pipeline"
log "   Date: $DATE (yesterday: $YESTERDAY)"
log "   Agent: $SUMMARY_AGENT (single-agent prefix cache)"
log "   Targets: ${AGENTS[*]}"
[ -n "$DRY_RUN" ] && log "   Mode: DRY-RUN"
log "════════════════════════════════════════"

# ══════════════════════════════════════════
# Phase 0: Sacrifice Agent + Context Reset
# ══════════════════════════════════════════

log ""
log "🔥 Phase 0: Sacrifice Agent + Context Reset"

(
    log "  → Priming prefix cache via $SUMMARY_AGENT..."
    if oc_agent "$SUMMARY_AGENT" "System check: list directories in ${AGENT_DIR}/" "$WARMUP_TIMEOUT"; then
        log "  ✅ Prefix cache primed"
    else
        log "  ⚠️ Warmup failed (non-critical)"
    fi
) &
WARMUP_PID=$!

# Optional: context reset script
if [ -x "$SCRIPT_DIR/context-reset-stats.sh" ]; then
    log "  → Context reset..."
    "$SCRIPT_DIR/context-reset-stats.sh" >> "$LOG" 2>&1 && log "  ✅ Context reset" || log "  ⚠️ Context reset failed"
fi

wait $WARMUP_PID || true
PHASE_RESULTS+=("phase0=ok")

# ══════════════════════════════════════════
# Phase 1: Per-Agent Summaries (THE CORE)
# ══════════════════════════════════════════

log ""
log "📓 Phase 1: Per-Agent Summaries (all via $SUMMARY_AGENT)"

AGENT_NOTE_COUNT=0
AGENT_SKIP_COUNT=0
AGENT_FAIL_COUNT=0
AGENT_PIDS=()
AGENT_NAMES=()

# Shared prompt prefix — IDENTICAL for all → prefix cache gold
SHARED_PREFIX='Write a daily memory note for an OpenClaw agent. Details follow at the end.

## Investigation Checklist (MANDATORY)
Use the Read tool on ALL paths below. Do NOT skip steps. Do NOT claim files do not exist without reading them.

Step 1: Read the agent MEMORY.md (path below) — search for the target date
Step 2: List and read files in the agent memory/ directory
Step 3: List session transcripts: ls -la <sessions_path>/*.jsonl — check timestamps

## Output Rules
- Save to the output path below (use Write tool)
- Start with: # <DATE> Daily Note — <AGENT>
- Use ## headers. Include specifics (files, errors, metrics).
- Skip routine (heartbeats, NO_REPLY).
- Active days: 100-500 words. Quiet days: 30-50 words.
- NEVER claim "no MEMORY.md" without reading it. If PRE-LOADED excerpt exists, note MUST reflect it.

---
AGENT-SPECIFIC DETAILS:
'

for agent in "${AGENTS[@]}"; do
    AGENT_WS=$(agent_workspace "$agent")
    NOTE_FILE="${AGENT_WS}/memory/${DATE}.md"
    SESSIONS_DIR="${OC_HOME}/agents/${agent}/sessions"

    if [ -f "$NOTE_FILE" ] && [ -s "$NOTE_FILE" ]; then
        log "  ⏭️  $agent ($(wc -c < "$NOTE_FILE")B)"
        AGENT_SKIP_COUNT=$((AGENT_SKIP_COUNT + 1))
        continue
    fi

    log "  → $agent"

    TAIL="Agent: ${agent}
Date: ${YESTERDAY}
Paths:
  MEMORY.md:        ${AGENT_WS}/MEMORY.md
  Memory dir:       ${AGENT_WS}/memory/
  Sessions:         ${SESSIONS_DIR}/
  Output:           ${NOTE_FILE}"

    EXCERPT=$(memory_excerpt "$agent" "$YESTERDAY")
    if [ -n "$EXCERPT" ]; then
        TAIL="${TAIL}

=== PRE-LOADED MEMORY.md excerpt for ${YESTERDAY} ===
(From ${AGENT_WS}/MEMORY.md — file EXISTS)
${EXCERPT}
=== END ===
Your note MUST reflect this content."
    fi

    (
        oc_agent "$SUMMARY_AGENT" "${SHARED_PREFIX}${TAIL}" "$AGENT_SUMMARY_TIMEOUT" || exit 1
    ) &
    AGENT_PIDS+=($!)
    AGENT_NAMES+=("$agent")
done

for i in "${!AGENT_PIDS[@]}"; do
    if wait "${AGENT_PIDS[$i]}" 2>/dev/null; then
        NF="$(agent_workspace "${AGENT_NAMES[$i]}")/memory/${DATE}.md"
        if [ -f "$NF" ] && [ -s "$NF" ]; then
            AGENT_NOTE_COUNT=$((AGENT_NOTE_COUNT + 1))
            log "  ✅ ${AGENT_NAMES[$i]} ($(wc -c < "$NF")B)"
        else
            AGENT_FAIL_COUNT=$((AGENT_FAIL_COUNT + 1))
            log "  ⚠️ ${AGENT_NAMES[$i]}: OK but no file"
        fi
    else
        AGENT_FAIL_COUNT=$((AGENT_FAIL_COUNT + 1))
        log "  ⚠️ ${AGENT_NAMES[$i]} failed"
    fi
done

log "  📊 Results: ${AGENT_NOTE_COUNT} written, ${AGENT_SKIP_COUNT} skipped, ${AGENT_FAIL_COUNT} failed"
PHASE_RESULTS+=("phase1=${AGENT_NOTE_COUNT}ok/${AGENT_FAIL_COUNT}fail/${AGENT_SKIP_COUNT}skip")

AGENT_NOTES_AVAILABLE=false
[ "$AGENT_NOTE_COUNT" -gt 0 ] || [ "$AGENT_SKIP_COUNT" -gt 0 ] && AGENT_NOTES_AVAILABLE=true
[ "$AGENT_FAIL_COUNT" -gt 0 ] && set_degraded

# ══════════════════════════════════════════
# Phase 2: Daily Summary
# ══════════════════════════════════════════

log ""
log "📝 Phase 2: Daily Summary"

if [ "$AGENT_NOTES_AVAILABLE" = true ]; then
    log "  → Creating summary (via $SUMMARY_AGENT)..."
    SUMMARY_PROMPT="Create the shared daily summary for ${YESTERDAY}.
Read per-agent notes from: agents/*/memory/${DATE}.md
Aggregate into: summaries/${DATE}.md

Format:
# ${DATE} Daily Memory
## New Today  [grouped by topic]
## Decisions & Outcomes
## Open Items  [3+ day items get (since MM-DD)]

Rules: Read previous summary for dedup. 200-400 words max."

    if oc_agent "$SUMMARY_AGENT" "$SUMMARY_PROMPT" "$DAILY_SUMMARY_TIMEOUT"; then
        log "  ✅ Summary complete"
        PHASE_RESULTS+=("phase2=ok")
    else
        log "  ❌ Summary FAILED"
        set_degraded
        PHASE_RESULTS+=("phase2=FAILED")
    fi
else
    log "  ⚠️ No notes available, skipping"
    set_degraded
    PHASE_RESULTS+=("phase2=skipped")
fi

# ══════════════════════════════════════════
# Phase 3: Briefing + Memory Sync
# ══════════════════════════════════════════

log ""
log "📬 Phase 3: Briefing + Memory Sync"

(
    log "  → Briefing..."
    BRIEFING_PROMPT="Morning briefing for ${DATE}.
Sources: summaries/${DATE}.md, agent notes, weather (if available).
Section 1: Your Day (highlights, pending)
Section 2: System Health
Keep under 300 words. Archive to: summaries/briefings/${DATE}.md"

    if oc_agent "$SUMMARY_AGENT" "$BRIEFING_PROMPT" "$BRIEFING_TIMEOUT"; then
        log "  ✅ Briefing complete"
    else
        log "  ❌ Briefing FAILED"
        set_degraded
    fi
) &
BRIEFING_PID=$!

log "  → Memory sync..."
SYNC_PIDS=()
for agent in "${AGENTS[@]}"; do
    ( oc_agent "$SUMMARY_AGENT" "Run memory_search for '${agent} daily sync ${DATE}'." "$MEMORY_SYNC_TIMEOUT" || true ) &
    SYNC_PIDS+=($!)
done
for pid in "${SYNC_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
log "  ✅ Memory sync done"

wait $BRIEFING_PID 2>/dev/null && PHASE_RESULTS+=("phase3=ok") || { set_degraded; PHASE_RESULTS+=("phase3=briefing-failed"); }

# ══════════════════════════════════════════
# Phase 4: Status Report
# ══════════════════════════════════════════

FINAL_STATUS=$(get_status)

log ""
log "📊 Phase 4: Status Report"
log "  Status:  $FINAL_STATUS"
log "  Duration: ${SECONDS}s"
log "  Notes:   ${AGENT_NOTE_COUNT} written, ${AGENT_SKIP_COUNT} skipped, ${AGENT_FAIL_COUNT} failed"
log "  Phases:  ${PHASE_RESULTS[*]}"

[ "$FINAL_STATUS" = "degraded" ] && log "  ⚠️ Completed with errors" || log "  ✅ All phases OK"

log ""
log "════════════════════════════════════════"
log "💙 Pipeline End: $(date +%H:%M:%S) (${SECONDS}s)"
log "════════════════════════════════════════"

rm -f "$STATUS_FILE"
exit 0
