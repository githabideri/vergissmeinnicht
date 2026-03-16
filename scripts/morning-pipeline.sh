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

DATE=$(date +%Y-%m-%d)
LOG_DIR="${LOG_DIR:-$REPO_DIR/logs}"
LOG="${LOG_DIR}/morning-pipeline-${DATE}.log"
AGENT_MEMORY_DIR="${AGENT_MEMORY_DIR:-$REPO_DIR/agents}"
SUMMARY_DIR="${SUMMARY_DIR:-$REPO_DIR/summaries}"
DRY_RUN="${1:-}"
STATUS="ok"
AGENT_NOTES_AVAILABLE=false

# Ensure directories
mkdir -p "$LOG_DIR"
mkdir -p "$SUMMARY_DIR"

# ──────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────

log() {
    echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"
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

        if timeout "$timeout_s" bash -c "$cmd" 2>&1 | tee -a "$LOG"; then
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
log "   Date: $DATE"
[ -n "$DRY_RUN" ] && log "   Mode: DRY-RUN"
log "════════════════════════════════════════"

# ── Phase 0: Warmup + Context Reset (parallel) ──

log ""
log "🔥 Phase 0: Warmup + Context Reset"

# Warmup Ping (background)
(
    run_with_retry "warmup-ping" 120 2 \
        "${WARMUP_CMD:-echo 'WARMUP_CMD not configured'}"
) &
WARMUP_PID=$!

# Context Reset (foreground, fast)
if [ -x "$SCRIPT_DIR/context-reset-stats.sh" ]; then
    "$SCRIPT_DIR/context-reset-stats.sh" 2>&1 | tee -a "$LOG" || \
        log "  ⚠️ Context reset failed (non-critical)"
else
    log "  ⚠️ context-reset-stats.sh not found"
fi

# Wait for warmup
if wait $WARMUP_PID; then
    log "  ✅ Warmup complete"
else
    log "  ⚠️ Warmup failed, continuing anyway"
fi

# ── Phase 1: Per-Agent Summaries (THE CORE) ──

log ""
log "📓 Phase 1: Per-Agent Summaries"

AGENTS="${AGENT_LIST:-}"
AGENT_NOTE_COUNT=0
AGENT_SKIP_COUNT=0

if [ -n "$AGENTS" ]; then
    PIDS=()

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
            # AGENT_SUMMARY_CMD should use $agent variable
            if eval "${AGENT_SUMMARY_CMD:-echo 'AGENT_SUMMARY_CMD not configured for $agent'}" 2>&1 | tee -a "$LOG"; then
                log "  ✅ $agent: note written"
                exit 0
            else
                log "  ❌ $agent: summary failed"
                exit 1
            fi
        ) &
        PIDS+=($!)
    done

    # Wait for all agent summaries
    for i in "${!PIDS[@]}"; do
        agent_name=$(echo "$AGENTS" | tr ' ' '\n' | sed -n "$((i+1))p")
        if wait "${PIDS[$i]}"; then
            AGENT_NOTE_COUNT=$((AGENT_NOTE_COUNT + 1))
        else
            exit_code=$?
            if [ "$exit_code" -eq 100 ]; then
                AGENT_SKIP_COUNT=$((AGENT_SKIP_COUNT + 1))
            fi
            # Don't fail pipeline for individual agent failures
        fi
    done

    log "  📊 Agent notes: ${AGENT_NOTE_COUNT} written, ${AGENT_SKIP_COUNT} skipped"

    if [ "$AGENT_NOTE_COUNT" -gt 0 ] || [ "$AGENT_SKIP_COUNT" -gt 0 ]; then
        AGENT_NOTES_AVAILABLE=true
    fi
else
    log "  ⚠️ AGENT_LIST empty, skipping per-agent summaries"
fi

# ── Phase 2: Daily Summary (aggregates agent notes) ──

log ""
log "📝 Phase 2: Daily Summary"

if [ "$AGENT_NOTES_AVAILABLE" = true ]; then
    if run_with_retry "daily-summary" 600 2 \
        "${SUMMARY_CMD:-echo 'SUMMARY_CMD not configured'}"; then
        log "  ✅ Daily summary complete"
    else
        log "  ❌ Daily summary FAILED — briefing will use fallback"
        STATUS="degraded"
    fi
else
    log "  ⚠️ No agent notes available, skipping summary"
    STATUS="degraded"
fi

# ── Phase 3: Briefing + Memory Sync (parallel) ──

log ""
log "📬 Phase 3: Briefing + Memory Sync"

# Morning Briefing (background)
(
    run_with_retry "morning-briefing" 300 2 \
        "${BRIEFING_CMD:-echo 'BRIEFING_CMD not configured'}"
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
                eval "${MEMORY_SYNC_CMD:-echo 'MEMORY_SYNC_CMD not configured for $agent'}" 2>&1 | tee -a "$LOG"
            fi
        ) &
    done
    wait
    log "  ✅ Memory sync complete"
fi

# Wait for briefing
if wait $BRIEFING_PID; then
    log "  ✅ Briefing complete"
else
    log "  ❌ Briefing FAILED"
    STATUS="degraded"
fi

# ── Phase 4: Status Report ──

log ""
log "📊 Phase 4: Status Report"
log "  Status: $STATUS"
log "  Duration: ${SECONDS}s"
log "  Agent notes: ${AGENT_NOTE_COUNT} written, ${AGENT_SKIP_COUNT} skipped"

if [ "$STATUS" = "degraded" ]; then
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

exit 0
