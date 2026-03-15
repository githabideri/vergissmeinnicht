#!/bin/bash
# vergissmeinnicht — Morning Pipeline Orchestrator
#
# Single script that runs the complete daily pipeline:
# Phase 0: Warmup + Context Reset (parallel)
# Phase 1: Daily Summary (sequential)
# Phase 2: Briefing + Memory Sync (parallel)
# Phase 3: Status Report
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
DRY_RUN="${1:-}"
STATUS="ok"
SUMMARY_AVAILABLE=false

# Ensure directories
mkdir -p "$LOG_DIR"
mkdir -p "${SUMMARY_DIR:-$REPO_DIR/summaries}"

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

# ── Phase 1: Daily Summary ──

log ""
log "📝 Phase 1: Daily Summary"

if run_with_retry "daily-summary" 600 2 \
    "${SUMMARY_CMD:-echo 'SUMMARY_CMD not configured'}"; then
    log "  ✅ Daily summary complete"
    SUMMARY_AVAILABLE=true
else
    log "  ❌ Daily summary FAILED — briefing will use fallback"
    STATUS="degraded"
fi

# ── Phase 2: Briefing + Memory Sync (parallel) ──

log ""
log "📬 Phase 2: Briefing + Memory Sync"

# Morning Briefing (background)
(
    run_with_retry "morning-briefing" 300 2 \
        "${BRIEFING_CMD:-echo 'BRIEFING_CMD not configured'}"
) &
BRIEFING_PID=$!

# Memory Sync (parallel per agent)
if [ "$SUMMARY_AVAILABLE" = true ]; then
    log "  → Memory sync starting..."

    AGENTS="${AGENT_LIST:-}"
    if [ -n "$AGENTS" ]; then
        for agent in $AGENTS; do
            (
                if [ -n "$DRY_RUN" ]; then
                    log "    [DRY-RUN] Would sync: $agent"
                else
                    ${MEMORY_SYNC_CMD:-echo "MEMORY_SYNC_CMD not configured for $agent"} 2>&1 | tee -a "$LOG"
                fi
            ) &
        done
        wait
        log "  ✅ Memory sync complete"
    else
        log "  ⚠️ AGENT_LIST empty, skipping memory sync"
    fi
else
    log "  ⚠️ Memory sync skipped (no summary)"
fi

# Wait for briefing
if wait $BRIEFING_PID; then
    log "  ✅ Briefing complete"
else
    log "  ❌ Briefing FAILED"
    STATUS="degraded"
fi

# ── Phase 3: Status Report ──

log ""
log "📊 Phase 3: Status Report"
log "  Status: $STATUS"
log "  Duration: ${SECONDS}s"

if [ "$STATUS" = "degraded" ]; then
    log "  ⚠️ Pipeline completed with errors"
    # Optional: send alert
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
