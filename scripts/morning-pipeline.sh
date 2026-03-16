#!/bin/bash
# vergissmeinnicht — Morning Pipeline Orchestrator
#
# Single script that runs the complete daily pipeline:
# Phase 0: Warmup + Context Reset (parallel)
# Phase 1: Per-Agent Summaries (parallel per agent) ← THE CORE
# Phase 2: Daily Summary (aggregates agent notes)
# Phase 3: Briefing + Memory Sync (parallel)
# Phase 4: Status Report
#
# Usage: ./morning-pipeline.sh [--dry-run]
# Cron:  0 6 * * * /path/to/scripts/morning-pipeline.sh

set -uo pipefail
# NOTE: We intentionally do NOT use set -e here.
# The orchestrator handles failures gracefully per-phase,
# not crashing on the first non-zero exit code.
# See docs/design-decisions.md §5 (Graceful Degradation).

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

DATE=$(date +%Y-%m-%d)
YESTERDAY=$(date -d yesterday +%Y-%m-%d 2>/dev/null || date -v-1d +%Y-%m-%d)
LOG_DIR="${LOG_DIR:-$REPO_DIR/logs}"
LOG="${LOG_DIR}/morning-pipeline-${DATE}.log"
DEBUG_LOG="${LOG_DIR}/morning-pipeline-${DATE}-debug.log"
AGENT_MEMORY_DIR="${AGENT_MEMORY_DIR:-$REPO_DIR/agents}"
SUMMARY_DIR="${SUMMARY_DIR:-$REPO_DIR/summaries}"
DRY_RUN=""
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN="true"

# Track pipeline status via temp file — NOT a bash variable.
# Bash subshells (background processes) can't propagate variable changes
# to the parent. Using a temp file ensures set_degraded() works from
# any phase, even when running in a ( ) & background subshell.
STATUS_FILE=$(mktemp)
echo "ok" > "$STATUS_FILE"

AGENT_NOTES_AVAILABLE=false
PHASE_RESULTS=()

# Ensure directories
mkdir -p "$LOG_DIR"
mkdir -p "$SUMMARY_DIR"

# ──────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────

log() {
    echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"
}

set_degraded() {
    echo "degraded" > "$STATUS_FILE"
}

get_status() {
    cat "$STATUS_FILE"
}

run_with_retry() {
    local job_name="$1"
    local timeout_s="$2"
    local max_retries="${3:-2}"
    local cmd="$4"

    for attempt in $(seq 1 "$max_retries"); do
        if [ -n "$DRY_RUN" ]; then
            log "  [DRY-RUN] Would run: $job_name (timeout: ${timeout_s}s)"
            return 0
        fi

        if timeout "$timeout_s" bash -c "$cmd" >> "$DEBUG_LOG" 2>&1; then
            return 0
        fi

        if [ "$attempt" -lt "$max_retries" ]; then
            log "  ⚠️ $job_name attempt $attempt/$max_retries failed, retrying in 10s..."
            sleep 10
        fi
    done

    log "  ❌ $job_name FAILED after $max_retries attempts"
    return 1
}

# ──────────────────────────────────────────
# Pipeline
# ──────────────────────────────────────────

log "════════════════════════════════════════"
log "💙 vergissmeinnicht — Morning Pipeline"
log "   Date: $DATE (yesterday: $YESTERDAY)"
[ -n "$DRY_RUN" ] && log "   Mode: DRY-RUN"
log "════════════════════════════════════════"

# ── Phase 0: Warmup + Context Reset (parallel) ──

log ""
log "🔥 Phase 0: Warmup + Context Reset"

# Warmup Ping (background)
(
    log "  → Warmup ping..."
    if run_with_retry "warmup-ping" 120 2 \
        "${WARMUP_CMD:-echo 'WARMUP_CMD not configured'}"; then
        log "  ✅ Warmup complete"
    else
        log "  ⚠️ Warmup failed (non-critical)"
    fi
) &
WARMUP_PID=$!

# Context Reset (foreground, fast)
if [ -x "$SCRIPT_DIR/context-reset-stats.sh" ]; then
    log "  → Context reset..."
    if "$SCRIPT_DIR/context-reset-stats.sh" >> "$LOG" 2>&1; then
        log "  ✅ Context reset done"
    else
        log "  ⚠️ Context reset failed (non-critical)"
    fi
else
    log "  ⚠️ context-reset-stats.sh not found"
fi

# Wait for warmup
wait $WARMUP_PID || true
PHASE_RESULTS+=("phase0=ok")

# ── Phase 1: Per-Agent Summaries (THE CORE) ──

log ""
log "📓 Phase 1: Per-Agent Summaries"

AGENTS="${AGENT_LIST:-}"
AGENT_NOTE_COUNT=0
AGENT_SKIP_COUNT=0
AGENT_FAIL_COUNT=0

if [ -n "$AGENTS" ]; then
    PIDS=()
    AGENT_NAMES=()

    for agent in $AGENTS; do
        (
            NOTE_FILE="${AGENT_MEMORY_DIR}/${agent}/memory/${DATE}.md"

            # Skip if note already exists for today
            if [ -f "$NOTE_FILE" ] && [ -s "$NOTE_FILE" ]; then
                log "  ⏭️  $agent: note exists, skipping"
                exit 100  # Special exit code: skipped
            fi

            # Ensure directory exists
            mkdir -p "$(dirname "$NOTE_FILE")"

            log "  → $agent: summarizing sessions..."

            if [ -n "$DRY_RUN" ]; then
                log "  [DRY-RUN] Would create: $NOTE_FILE"
                exit 0
            fi

            # Run agent-specific summary command
            # AGENT_SUMMARY_CMD should use $agent and $YESTERDAY variables.
            # The prompt should explicitly tell the agent:
            #   - Which agent's work to summarize ($agent)
            #   - Where to find session data (sessions_list, session transcripts, MEMORY.md)
            #   - That it may be running as a localbot variant with a different agent ID
            if eval "${AGENT_SUMMARY_CMD:-echo 'AGENT_SUMMARY_CMD not configured for $agent'}" >> "$DEBUG_LOG" 2>&1; then
                log "  ✅ $agent: note written"
                exit 0
            else
                log "  ❌ $agent: summary failed"
                exit 1
            fi
        ) &
        PIDS+=($!)
        AGENT_NAMES+=("$agent")
    done

    # Wait for all agent summaries
    for i in "${!PIDS[@]}"; do
        wait "${PIDS[$i]}" 2>/dev/null
        exit_code=$?
        if [ "$exit_code" -eq 0 ]; then
            AGENT_NOTE_COUNT=$((AGENT_NOTE_COUNT + 1))
        elif [ "$exit_code" -eq 100 ]; then
            AGENT_SKIP_COUNT=$((AGENT_SKIP_COUNT + 1))
        else
            AGENT_FAIL_COUNT=$((AGENT_FAIL_COUNT + 1))
            log "  ⚠️ ${AGENT_NAMES[$i]} failed (pipeline continues)"
        fi
    done

    log "  📊 Results: ${AGENT_NOTE_COUNT} written, ${AGENT_SKIP_COUNT} skipped, ${AGENT_FAIL_COUNT} failed"
    PHASE_RESULTS+=("phase1=${AGENT_NOTE_COUNT}ok/${AGENT_FAIL_COUNT}fail/${AGENT_SKIP_COUNT}skip")

    if [ "$AGENT_NOTE_COUNT" -gt 0 ] || [ "$AGENT_SKIP_COUNT" -gt 0 ]; then
        AGENT_NOTES_AVAILABLE=true
    fi

    if [ "$AGENT_FAIL_COUNT" -gt 0 ]; then
        set_degraded
    fi
else
    log "  ⚠️ AGENT_LIST empty, skipping per-agent summaries"
    PHASE_RESULTS+=("phase1=skipped")
fi

# ── Phase 2: Daily Summary (aggregates agent notes) ──

log ""
log "📝 Phase 2: Daily Summary"

if [ "$AGENT_NOTES_AVAILABLE" = true ]; then
    log "  → Creating daily summary..."
    if run_with_retry "daily-summary" 600 2 \
        "${SUMMARY_CMD:-echo 'SUMMARY_CMD not configured'}"; then
        log "  ✅ Daily summary complete"
        PHASE_RESULTS+=("phase2=ok")
    else
        log "  ❌ Daily summary FAILED — briefing will use fallback"
        set_degraded
        PHASE_RESULTS+=("phase2=FAILED")
    fi
else
    log "  ⚠️ No agent notes available, skipping summary"
    set_degraded
    PHASE_RESULTS+=("phase2=skipped")
fi

# ── Phase 3: Briefing + Memory Sync (parallel) ──

log ""
log "📬 Phase 3: Briefing + Memory Sync"

# Morning Briefing (background)
(
    log "  → Briefing starting..."
    if run_with_retry "morning-briefing" 600 2 \
        "${BRIEFING_CMD:-echo 'BRIEFING_CMD not configured'}"; then
        log "  ✅ Briefing complete"
    else
        log "  ❌ Briefing FAILED"
        set_degraded
    fi
) &
BRIEFING_PID=$!

# Memory Sync (parallel per agent — trigger index updates)
if [ -n "$AGENTS" ]; then
    log "  → Memory sync starting..."
    for agent in $AGENTS; do
        (
            if [ -n "$DRY_RUN" ]; then
                log "    [DRY-RUN] Would sync: $agent"
            else
                eval "${MEMORY_SYNC_CMD:-echo 'MEMORY_SYNC_CMD not configured for $agent'}" >> "$DEBUG_LOG" 2>&1 || true
            fi
        ) &
    done
    wait
    log "  ✅ Memory sync complete"
fi

# Wait for briefing
if wait $BRIEFING_PID 2>/dev/null; then
    PHASE_RESULTS+=("phase3=ok")
else
    set_degraded
    PHASE_RESULTS+=("phase3=briefing-failed")
fi

# ── Phase 4: Status Report ──

FINAL_STATUS=$(get_status)

log ""
log "📊 Phase 4: Status Report"
log "  Status:       $FINAL_STATUS"
log "  Duration:     ${SECONDS}s"
log "  Agent notes:  ${AGENT_NOTE_COUNT} written, ${AGENT_SKIP_COUNT} skipped, ${AGENT_FAIL_COUNT} failed"
log "  Phases:       ${PHASE_RESULTS[*]}"

if [ "$FINAL_STATUS" = "degraded" ]; then
    log "  ⚠️ Pipeline completed with errors"
    if [ -n "${ALERT_CMD:-}" ] && [ -z "$DRY_RUN" ]; then
        bash -c "$ALERT_CMD" || true
    fi
else
    log "  ✅ Pipeline completed successfully"
fi

log ""
log "════════════════════════════════════════"
log "💙 Pipeline End: $(date +%H:%M:%S) (${SECONDS}s)"
log "════════════════════════════════════════"

# Cleanup
rm -f "$STATUS_FILE"

exit 0
