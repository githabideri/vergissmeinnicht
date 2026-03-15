#!/bin/bash
# vergissmeinnicht — Pipeline Health Check
#
# Independent verification that the morning pipeline completed.
# Run 1 hour after pipeline (e.g., 08:00 if pipeline runs at 07:00).
#
# Usage: ./pipeline-healthcheck.sh
# Cron:  0 7 * * * /path/to/scripts/pipeline-healthcheck.sh

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
SUMMARY_DIR="${SUMMARY_DIR:-$REPO_DIR/summaries}"
ERRORS=()

# ──────────────────────────────────────────
# Checks
# ──────────────────────────────────────────

# Check 1: Daily summary exists and is non-empty
SUMMARY_FILE="${SUMMARY_DIR}/${DATE}.md"
if [ ! -f "$SUMMARY_FILE" ]; then
    ERRORS+=("❌ Daily summary missing: ${DATE}.md")
elif [ ! -s "$SUMMARY_FILE" ]; then
    ERRORS+=("⚠️ Daily summary is empty: ${DATE}.md")
fi

# Check 2: Pipeline log exists and completed
PIPELINE_LOG="${LOG_DIR}/morning-pipeline-${DATE}.log"
if [ ! -f "$PIPELINE_LOG" ]; then
    ERRORS+=("❌ Pipeline log missing (pipeline didn't run?)")
elif ! grep -q "Pipeline End" "$PIPELINE_LOG" 2>/dev/null; then
    ERRORS+=("❌ Pipeline did not complete (check log)")
elif grep -q "degraded" "$PIPELINE_LOG" 2>/dev/null; then
    ERRORS+=("⚠️ Pipeline completed with degraded status")
fi

# Check 3: Duration within budget
if [ -f "$PIPELINE_LOG" ]; then
    DURATION=$(grep -oP 'Duration: \K[0-9]+' "$PIPELINE_LOG" 2>/dev/null || echo "0")
    if [ "$DURATION" -gt 900 ]; then  # 15 minutes
        ERRORS+=("⚠️ Pipeline took ${DURATION}s (budget: 900s)")
    fi
fi

# ──────────────────────────────────────────
# Report
# ──────────────────────────────────────────

if [ ${#ERRORS[@]} -gt 0 ]; then
    echo "⚠️ Health Check FAILED ($DATE)"
    printf '%s\n' "${ERRORS[@]}"

    # Optional: send alert via Matrix
    if [ -n "${ALERT_CMD:-}" ]; then
        MESSAGE="⚠️ vergissmeinnicht health check failed ($DATE):"$'\n'"$(printf '%s\n' "${ERRORS[@]}")"
        bash -c "$ALERT_CMD" <<< "$MESSAGE" || true
    fi

    exit 1
else
    echo "✅ Health Check PASSED ($DATE)"
    [ -f "$PIPELINE_LOG" ] && echo "   Duration: ${DURATION:-?}s"
    exit 0
fi
