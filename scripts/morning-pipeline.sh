#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# 💙 vergissmeinnicht — Morning Pipeline (Production-Ready)
#
# Single Orchestrator for the daily agent pipeline.
#
# Phases:
#   0: Warmup + Context Reset (parallel)
#   1: Per-Agent Summaries (parallel per agent)  ← THE CORE
#   2: Shared Daily Summary (aggregates agent notes for target date)
#   3: Morning Briefing + Memory Sync (parallel)
#   4: Status Report
#
# Date semantics:
#   - DATE         = today / pipeline run date / briefing archive date
#   - TARGET_DATE  = yesterday / the day being summarized
#
# Usage:  ./morning-pipeline.sh [--dry-run]
# Cron:   0 6 * * * /path/to/vergissmeinnicht/scripts/morning-pipeline.sh
# ═══════════════════════════════════════════════════════════════

set -uo pipefail
# NOTE: We intentionally do NOT use set -e here.
# The orchestrator handles failures gracefully per-phase,
# not crashing on the first non-zero exit code.

# ──────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

if [ -f "$REPO_DIR/config.env" ]; then
    # shellcheck source=/dev/null
    . "$REPO_DIR/config.env"
fi

DATE="${DATE_OVERRIDE:-$(date +%Y-%m-%d)}"
TARGET_DATE="${TARGET_DATE_OVERRIDE:-${YESTERDAY_OVERRIDE:-$(date -d yesterday +%Y-%m-%d 2>/dev/null || date -v-1d +%Y-%m-%d)}}"
PREVIOUS_TARGET_DATE="${PREVIOUS_TARGET_DATE_OVERRIDE:-$(date -d "$TARGET_DATE -1 day" +%Y-%m-%d 2>/dev/null || python3 -c "from datetime import datetime, timedelta; print((datetime.strptime('${TARGET_DATE}', '%Y-%m-%d') - timedelta(days=1)).strftime('%Y-%m-%d'))")}"

# Paths
LOG_DIR="${LOG_DIR:-$REPO_DIR/logs}"
LOG="${LOG_DIR}/morning-pipeline-${DATE}.log"
DEBUG_LOG="${LOG_DIR}/morning-pipeline-${DATE}-debug.log"
TASKS_LOG="${LOG_DIR}/morning-pipeline-${DATE}-tasks.tsv"
PHASES_LOG="${LOG_DIR}/morning-pipeline-${DATE}-phases.tsv"
OC_DIR="${OC_DIR:-/opt/openclaw}"
WORKSPACE="${WORKSPACE:-$REPO_DIR}"
AGENT_DIR="${AGENT_DIR:-$WORKSPACE/agents}"
SUMMARY_DIR="${SUMMARY_DIR:-$WORKSPACE/memory}"
BRIEFING_DIR="${BRIEFING_DIR:-$SUMMARY_DIR/briefings}"
OC_HOME="${OC_HOME:-$HOME/.openclaw}"

# OC CLI helper — all OC commands go through this
OC_CMD="node ${OC_DIR}/openclaw.mjs"

# vLLM configuration (informational logging only)
VLLM_URL="${VLLM_URL:-unset}"
VLLM_MODEL="${VLLM_MODEL:-unset}"

# Single-Agent Prefix Cache Strategy
SUMMARY_AGENT="${SUMMARY_AGENT:-localbot-planning}"

# Agent list from config.env may define a bash array; fallback to AGENT_LIST string.
if declare -p AGENTS >/dev/null 2>&1; then
    :
elif [ -n "${AGENT_LIST:-}" ]; then
    read -r -a AGENTS <<< "$AGENT_LIST"
else
    AGENTS=(agent1 agent2 agent3)
fi

# Agent workspace paths — config.env may define an associative array override.
if ! declare -p AGENT_WORKSPACE >/dev/null 2>&1; then
    declare -A AGENT_WORKSPACE=()
fi

# Measurement / tuning knobs
SUMMARY_BATCH_SIZE="${SUMMARY_BATCH_SIZE:-8}"

# Timeouts (seconds)
WARMUP_TIMEOUT="${WARMUP_TIMEOUT:-120}"
AGENT_SUMMARY_TIMEOUT="${AGENT_SUMMARY_TIMEOUT:-1200}"
DAILY_SUMMARY_TIMEOUT="${DAILY_SUMMARY_TIMEOUT:-1200}"
BRIEFING_TIMEOUT="${BRIEFING_TIMEOUT:-1200}"
MEMORY_SYNC_TIMEOUT="${MEMORY_SYNC_TIMEOUT:-60}"

# Optional alert command (shell snippet, defined in config.env)
ALERT_CMD="${ALERT_CMD:-}"

DRY_RUN=""
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN="true"

# ──────────────────────────────────────────
# Setup
# ──────────────────────────────────────────

mkdir -p "$LOG_DIR" "$SUMMARY_DIR" "$BRIEFING_DIR"

printf 'ts_epoch\tts_iso\tkind\tname\tstatus\tduration_s\tnote\n' > "$TASKS_LOG"
printf 'ts_epoch\tts_iso\tphase\tstatus\tduration_s\tnote\n' > "$PHASES_LOG"

# ──────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────

log() {
    echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"
}

now_epoch() {
    date +%s
}

record_task() {
    local kind="$1" name="$2" status="$3" duration="$4" note="${5:-}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$name" "$status" "$duration" "$note" >> "$TASKS_LOG"
}

record_phase() {
    local phase="$1" status="$2" duration="$3" note="${4:-}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$phase" "$status" "$duration" "$note" >> "$PHASES_LOG"
}

agent_workspace() {
    local agent="$1"
    echo "${AGENT_WORKSPACE[$agent]:-${AGENT_DIR}/${agent}}"
}

memory_excerpt() {
    local agent="$1"
    local date="$2"
    local memory_md
    memory_md="$(agent_workspace "$agent")/MEMORY.md"
    if [ -f "$memory_md" ]; then
        grep -B2 -A20 "$date" "$memory_md" 2>/dev/null | head -60
    fi
}

session_file_count() {
    local dir="$1"
    if [ -d "$dir" ]; then
        find "$dir" -maxdepth 1 -type f -name '*.jsonl' | wc -l | tr -d ' '
    else
        echo 0
    fi
}

file_sha() {
    local file="$1"
    if [ -f "$file" ]; then
        sha256sum "$file" | awk '{print $1}'
    else
        echo "missing"
    fi
}

header_ok() {
    local file="$1"
    local expected_date="$2"
    [ -f "$file" ] || return 1
    head -n 1 "$file" | grep -q "# ${expected_date}"
}

oc_agent() {
    local agent="$1"
    local message="$2"
    local timeout_s="${3:-180}"

    if [ -n "$DRY_RUN" ]; then
        log "    [DRY-RUN] openclaw agent --agent $agent (timeout: ${timeout_s}s)"
        return 0
    fi

    cd "$OC_DIR" && timeout "$timeout_s" $OC_CMD agent \
        --agent "$agent" \
        --message "$message" \
        --timeout "$timeout_s" \
        --json >> "$DEBUG_LOG" 2>&1
}

STATUS_FILE=$(mktemp)
echo "ok" > "$STATUS_FILE"
set_degraded() { echo "degraded" > "$STATUS_FILE"; }
get_status() { cat "$STATUS_FILE"; }
PHASE_RESULTS=()

# ──────────────────────────────────────────
# Pipeline Start
# ──────────────────────────────────────────

log "════════════════════════════════════════"
log "💙 vergissmeinnicht — Morning Pipeline"
log "   Run date:      $DATE"
log "   Target date:   $TARGET_DATE"
log "   Previous day:  $PREVIOUS_TARGET_DATE"
log "   Agents:        ${AGENTS[*]}"
log "   Summary agent: $SUMMARY_AGENT"
log "   vLLM:          $VLLM_URL ($VLLM_MODEL)"
log "   Batch size:    $SUMMARY_BATCH_SIZE"
[ -n "$DRY_RUN" ] && log "   Mode:          DRY-RUN"
log "════════════════════════════════════════"

# ══════════════════════════════════════════
# Phase 0: Warmup + Context Reset
# ══════════════════════════════════════════

log ""
log "🔥 Phase 0: Warmup + Context Reset"
PHASE0_START=$(now_epoch)

(
    local_start=$(now_epoch)
    log "  → Priming prefix cache via $SUMMARY_AGENT..."
    if oc_agent "$SUMMARY_AGENT" "System check: list agent directories in ${AGENT_DIR}/" "$WARMUP_TIMEOUT"; then
        log "  ✅ Prefix cache primed"
        record_task "phase0" "warmup" "ok" "$(( $(now_epoch) - local_start ))"
    else
        log "  ⚠️ Warmup failed — vLLM may be cold (non-critical)"
        record_task "phase0" "warmup" "failed" "$(( $(now_epoch) - local_start ))"
    fi
) &
WARMUP_PID=$!

if [ -x "$SCRIPT_DIR/context-reset-stats.sh" ]; then
    log "  → Context reset..."
    _ctx_start=$(now_epoch)
    if "$SCRIPT_DIR/context-reset-stats.sh" >> "$LOG" 2>&1; then
        log "  ✅ Context reset done"
        record_task "phase0" "context-reset" "ok" "$(( $(now_epoch) - _ctx_start ))"
    else
        log "  ⚠️ Context reset failed (non-critical)"
        record_task "phase0" "context-reset" "failed" "$(( $(now_epoch) - _ctx_start ))"
    fi
else
    log "  ⏭️ Context reset skipped (missing script)"
fi

wait $WARMUP_PID || true
PHASE_RESULTS+=("phase0=ok")
record_phase "phase0" "ok" "$(( $(now_epoch) - PHASE0_START ))"

# ══════════════════════════════════════════
# Phase 1: Per-Agent Summaries
# ══════════════════════════════════════════

log ""
log "📓 Phase 1: Per-Agent Summaries"
PHASE1_START=$(now_epoch)

AGENT_CREATE_COUNT=0
AGENT_UPDATE_COUNT=0
AGENT_UNCHANGED_COUNT=0
AGENT_FAIL_COUNT=0
AGENT_PIDS=()
AGENT_NAMES=()
AGENT_MODES=()
AGENT_STARTS=()
AGENT_TARGETS=()
AGENT_BEFORE_SHA=()
AGENT_SESSION_COUNTS=()

SHARED_PROMPT_PREFIX='Write or update a per-agent daily memory note for an OpenClaw agent. Agent-specific details follow at the end.

## Core rule
The target date is the COMPLETED PREVIOUS DAY, not today.
You are summarizing activity for <TARGET_DATE> and writing to the exact output file given below.

## Investigation Checklist (MANDATORY)
You MUST use the Read tool on the paths given below. Do NOT skip steps. Do NOT claim files do not exist without trying to read them.

Step 1: Read the agent MEMORY.md (exact path below) — search for the target date
Step 2: List and read files in the agent memory/ directory (exact path below)
Step 3: List session transcripts: ls -la <sessions_path>/*.jsonl — check timestamps, read relevant ones
Step 4: If the output file already exists, read it first and preserve valid content

## Output Rules
- Save to the exact output path given below
- If the output file exists: UPDATE it carefully, do not blindly overwrite
- If the output file does not exist: create it
- Preserve good existing content; merge in new facts from session logs
- Avoid duplicate bullets, duplicate sections, and repeated facts
- Start with: # <TARGET_DATE> Daily Note — <AGENT>
- Use ## headers for topics
- Include specific details (file names, error messages, decisions, metrics)
- Skip routine (heartbeats, health checks, NO_REPLY)
- Active days: 100-500 words. Genuinely quiet days: 30-50 words.
- For quiet days: "Verified quiet: checked MEMORY.md (path), sessions (path), no activity for <TARGET_DATE>."

CRITICAL: NEVER claim "no MEMORY.md exists" without reading it. NEVER write "no activity" without ALL steps.
If a PRE-LOADED excerpt is provided below, the note MUST reflect that content.

---
AGENT-SPECIFIC DETAILS:
'

for agent in "${AGENTS[@]}"; do
    AGENT_WS=$(agent_workspace "$agent")
    TARGET_FILE="${AGENT_WS}/memory/${TARGET_DATE}.md"
    SESSIONS_DIR="${OC_HOME}/agents/${agent}/sessions"
    MODE="create"
    [ -f "$TARGET_FILE" ] && MODE="update"
    BEFORE_SHA=$(file_sha "$TARGET_FILE")
    SESSION_COUNT=$(session_file_count "$SESSIONS_DIR")

    log "  → $agent (${MODE}; target=${TARGET_DATE}; sessions=${SESSION_COUNT}; file=${TARGET_FILE})"

    AGENT_TAIL="Agent: ${agent}
Target date: ${TARGET_DATE}
Mode: ${MODE}

Paths:
  MEMORY.md:           ${AGENT_WS}/MEMORY.md
  Memory directory:    ${AGENT_WS}/memory/
  Session transcripts: ${SESSIONS_DIR}/
  Output file:         ${TARGET_FILE}"

    if [ -f "$TARGET_FILE" ]; then
        AGENT_TAIL="${AGENT_TAIL}
  Existing output:     ${TARGET_FILE} (READ THIS FIRST BEFORE WRITING)"
    fi

    EXCERPT=$(memory_excerpt "$agent" "$TARGET_DATE")
    if [ -n "$EXCERPT" ]; then
        AGENT_TAIL="${AGENT_TAIL}

=== PRE-LOADED: MEMORY.md excerpts mentioning ${TARGET_DATE} ===
(Read from ${AGENT_WS}/MEMORY.md — this file EXISTS)
${EXCERPT}
=== END EXCERPT ===

IMPORTANT: The above PROVES this agent had activity on ${TARGET_DATE}. Your note MUST reflect it."
    fi

    (
        if oc_agent "$SUMMARY_AGENT" "${SHARED_PROMPT_PREFIX}${AGENT_TAIL}" "$AGENT_SUMMARY_TIMEOUT"; then
            exit 0
        else
            exit 1
        fi
    ) &

    AGENT_PIDS+=($!)
    AGENT_NAMES+=("$agent")
    AGENT_MODES+=("$MODE")
    AGENT_STARTS+=("$(now_epoch)")
    AGENT_TARGETS+=("$TARGET_FILE")
    AGENT_BEFORE_SHA+=("$BEFORE_SHA")
    AGENT_SESSION_COUNTS+=("$SESSION_COUNT")

    if [ "${#AGENT_PIDS[@]}" -ge "$SUMMARY_BATCH_SIZE" ]; then
        for i in "${!AGENT_PIDS[@]}"; do
            DURATION="$(( $(now_epoch) - ${AGENT_STARTS[$i]} ))"
            TARGET_FILE="${AGENT_TARGETS[$i]}"
            AFTER_SHA=$(file_sha "$TARGET_FILE")
            SIZE=0
            [ -f "$TARGET_FILE" ] && SIZE=$(wc -c < "$TARGET_FILE")
            HEADER_STATUS="bad-header"
            header_ok "$TARGET_FILE" "$TARGET_DATE" && HEADER_STATUS="ok"

            if wait "${AGENT_PIDS[$i]}" 2>/dev/null; then
                if [ -f "$TARGET_FILE" ] && [ -s "$TARGET_FILE" ]; then
                    if [ "${AGENT_BEFORE_SHA[$i]}" = "missing" ]; then
                        AGENT_CREATE_COUNT=$((AGENT_CREATE_COUNT + 1))
                        log "  ✅ ${AGENT_NAMES[$i]} created (${SIZE}B; header=${HEADER_STATUS})"
                        record_task "summary" "${AGENT_NAMES[$i]}" "created" "$DURATION" "sessions=${AGENT_SESSION_COUNTS[$i]};size=${SIZE};header=${HEADER_STATUS}"
                    elif [ "${AGENT_BEFORE_SHA[$i]}" = "$AFTER_SHA" ]; then
                        AGENT_UNCHANGED_COUNT=$((AGENT_UNCHANGED_COUNT + 1))
                        log "  ✅ ${AGENT_NAMES[$i]} unchanged (${SIZE}B; header=${HEADER_STATUS})"
                        record_task "summary" "${AGENT_NAMES[$i]}" "unchanged" "$DURATION" "sessions=${AGENT_SESSION_COUNTS[$i]};size=${SIZE};header=${HEADER_STATUS}"
                    else
                        AGENT_UPDATE_COUNT=$((AGENT_UPDATE_COUNT + 1))
                        log "  ✅ ${AGENT_NAMES[$i]} updated (${SIZE}B; header=${HEADER_STATUS})"
                        record_task "summary" "${AGENT_NAMES[$i]}" "updated" "$DURATION" "sessions=${AGENT_SESSION_COUNTS[$i]};size=${SIZE};header=${HEADER_STATUS}"
                    fi
                    if [ "$HEADER_STATUS" != "ok" ]; then
                        set_degraded
                    fi
                else
                    AGENT_FAIL_COUNT=$((AGENT_FAIL_COUNT + 1))
                    log "  ⚠️ ${AGENT_NAMES[$i]}: agent returned OK but no file written"
                    record_task "summary" "${AGENT_NAMES[$i]}" "no-file" "$DURATION" "sessions=${AGENT_SESSION_COUNTS[$i]}"
                fi
            else
                AGENT_FAIL_COUNT=$((AGENT_FAIL_COUNT + 1))
                log "  ❌ ${AGENT_NAMES[$i]} failed"
                record_task "summary" "${AGENT_NAMES[$i]}" "failed" "$DURATION" "sessions=${AGENT_SESSION_COUNTS[$i]};mode=${AGENT_MODES[$i]}"
            fi
        done
        AGENT_PIDS=()
        AGENT_NAMES=()
        AGENT_MODES=()
        AGENT_STARTS=()
        AGENT_TARGETS=()
        AGENT_BEFORE_SHA=()
        AGENT_SESSION_COUNTS=()
    fi
done

for i in "${!AGENT_PIDS[@]}"; do
    DURATION="$(( $(now_epoch) - ${AGENT_STARTS[$i]} ))"
    TARGET_FILE="${AGENT_TARGETS[$i]}"
    AFTER_SHA=$(file_sha "$TARGET_FILE")
    SIZE=0
    [ -f "$TARGET_FILE" ] && SIZE=$(wc -c < "$TARGET_FILE")
    HEADER_STATUS="bad-header"
    header_ok "$TARGET_FILE" "$TARGET_DATE" && HEADER_STATUS="ok"

    if wait "${AGENT_PIDS[$i]}" 2>/dev/null; then
        if [ -f "$TARGET_FILE" ] && [ -s "$TARGET_FILE" ]; then
            if [ "${AGENT_BEFORE_SHA[$i]}" = "missing" ]; then
                AGENT_CREATE_COUNT=$((AGENT_CREATE_COUNT + 1))
                log "  ✅ ${AGENT_NAMES[$i]} created (${SIZE}B; header=${HEADER_STATUS})"
                record_task "summary" "${AGENT_NAMES[$i]}" "created" "$DURATION" "sessions=${AGENT_SESSION_COUNTS[$i]};size=${SIZE};header=${HEADER_STATUS}"
            elif [ "${AGENT_BEFORE_SHA[$i]}" = "$AFTER_SHA" ]; then
                AGENT_UNCHANGED_COUNT=$((AGENT_UNCHANGED_COUNT + 1))
                log "  ✅ ${AGENT_NAMES[$i]} unchanged (${SIZE}B; header=${HEADER_STATUS})"
                record_task "summary" "${AGENT_NAMES[$i]}" "unchanged" "$DURATION" "sessions=${AGENT_SESSION_COUNTS[$i]};size=${SIZE};header=${HEADER_STATUS}"
            else
                AGENT_UPDATE_COUNT=$((AGENT_UPDATE_COUNT + 1))
                log "  ✅ ${AGENT_NAMES[$i]} updated (${SIZE}B; header=${HEADER_STATUS})"
                record_task "summary" "${AGENT_NAMES[$i]}" "updated" "$DURATION" "sessions=${AGENT_SESSION_COUNTS[$i]};size=${SIZE};header=${HEADER_STATUS}"
            fi
            if [ "$HEADER_STATUS" != "ok" ]; then
                set_degraded
            fi
        else
            AGENT_FAIL_COUNT=$((AGENT_FAIL_COUNT + 1))
            log "  ⚠️ ${AGENT_NAMES[$i]}: agent returned OK but no file written"
            record_task "summary" "${AGENT_NAMES[$i]}" "no-file" "$DURATION" "sessions=${AGENT_SESSION_COUNTS[$i]}"
        fi
    else
        AGENT_FAIL_COUNT=$((AGENT_FAIL_COUNT + 1))
        log "  ❌ ${AGENT_NAMES[$i]} failed"
        record_task "summary" "${AGENT_NAMES[$i]}" "failed" "$DURATION" "sessions=${AGENT_SESSION_COUNTS[$i]};mode=${AGENT_MODES[$i]}"
    fi
done

log "  📊 Results: ${AGENT_CREATE_COUNT} created, ${AGENT_UPDATE_COUNT} updated, ${AGENT_UNCHANGED_COUNT} unchanged, ${AGENT_FAIL_COUNT} failed"
PHASE_RESULTS+=("phase1=${AGENT_CREATE_COUNT}create/${AGENT_UPDATE_COUNT}update/${AGENT_UNCHANGED_COUNT}same/${AGENT_FAIL_COUNT}fail")
record_phase "phase1" "$([ "$AGENT_FAIL_COUNT" -gt 0 ] && echo degraded || echo ok)" "$(( $(now_epoch) - PHASE1_START ))" "created=${AGENT_CREATE_COUNT};updated=${AGENT_UPDATE_COUNT};unchanged=${AGENT_UNCHANGED_COUNT};failed=${AGENT_FAIL_COUNT};target=${TARGET_DATE}"

AGENT_NOTES_AVAILABLE=false
if [ $((AGENT_CREATE_COUNT + AGENT_UPDATE_COUNT + AGENT_UNCHANGED_COUNT)) -gt 0 ]; then
    AGENT_NOTES_AVAILABLE=true
fi

if [ "$AGENT_FAIL_COUNT" -gt 0 ]; then
    set_degraded
fi

# ══════════════════════════════════════════
# Phase 2: Shared Daily Summary
# ══════════════════════════════════════════

log ""
log "📝 Phase 2: Shared Daily Summary"
PHASE2_START=$(now_epoch)
SUMMARY_FILE="${SUMMARY_DIR}/${TARGET_DATE}.md"

if [ "$AGENT_NOTES_AVAILABLE" = true ]; then
    log "  → Creating shared summary for ${TARGET_DATE} (via $SUMMARY_AGENT)..."

    SUMMARY_PROMPT="Create the shared daily summary for ${TARGET_DATE}.

Read all per-agent daily notes from: agents/*/memory/${TARGET_DATE}.md
Also check sessions_list for supplementary activity data.
If the output file already exists, read it first and update carefully without duplicating content.

Aggregate into a single shared overview at: ${SUMMARY_FILE}

Format:
# ${TARGET_DATE} Daily Memory

## New Today
[Grouped by topic/agent. ONLY genuinely new activity from ${TARGET_DATE}.]

## Decisions & Outcomes
[Important choices, problems solved]

## Open Items
[Unfinished work. Items open 3+ days get (since MM-DD) tag.]

Rules:
- Read the PREVIOUS summary (${SUMMARY_DIR}/${PREVIOUS_TARGET_DATE}.md) for dedup — don't repeat stale items
- Preserve good existing content if ${SUMMARY_FILE} already exists
- Avoid duplicates if updating an existing file
- If ${TARGET_DATE} was quiet, say so honestly in 2-3 lines
- 200-400 words max
- Update state file if you use one, but do not create duplicate summaries for the same target date"

    BEFORE_SUMMARY_SHA=$(file_sha "$SUMMARY_FILE")
    if oc_agent "$SUMMARY_AGENT" "$SUMMARY_PROMPT" "$DAILY_SUMMARY_TIMEOUT"; then
        AFTER_SUMMARY_SHA=$(file_sha "$SUMMARY_FILE")
        SUMMARY_SIZE=0
        [ -f "$SUMMARY_FILE" ] && SUMMARY_SIZE=$(wc -c < "$SUMMARY_FILE")
        if [ "$BEFORE_SUMMARY_SHA" = "missing" ]; then
            log "  ✅ Shared summary created (${SUMMARY_SIZE}B)"
            record_task "summary" "daily-summary" "created" "$(( $(now_epoch) - PHASE2_START ))" "target=${TARGET_DATE};size=${SUMMARY_SIZE}"
        elif [ "$BEFORE_SUMMARY_SHA" = "$AFTER_SUMMARY_SHA" ]; then
            log "  ✅ Shared summary unchanged (${SUMMARY_SIZE}B)"
            record_task "summary" "daily-summary" "unchanged" "$(( $(now_epoch) - PHASE2_START ))" "target=${TARGET_DATE};size=${SUMMARY_SIZE}"
        else
            log "  ✅ Shared summary updated (${SUMMARY_SIZE}B)"
            record_task "summary" "daily-summary" "updated" "$(( $(now_epoch) - PHASE2_START ))" "target=${TARGET_DATE};size=${SUMMARY_SIZE}"
        fi
        PHASE_RESULTS+=("phase2=ok")
        record_phase "phase2" "ok" "$(( $(now_epoch) - PHASE2_START ))" "target=${TARGET_DATE};file=${SUMMARY_FILE}"
    else
        log "  ❌ Shared summary FAILED"
        set_degraded
        PHASE_RESULTS+=("phase2=FAILED")
        record_task "summary" "daily-summary" "failed" "$(( $(now_epoch) - PHASE2_START ))" "target=${TARGET_DATE}"
        record_phase "phase2" "failed" "$(( $(now_epoch) - PHASE2_START ))" "target=${TARGET_DATE}"
    fi
else
    log "  ⚠️ No agent notes available, skipping shared summary"
    set_degraded
    PHASE_RESULTS+=("phase2=skipped")
    record_phase "phase2" "skipped" "$(( $(now_epoch) - PHASE2_START ))" "target=${TARGET_DATE}"
fi

# ══════════════════════════════════════════
# Phase 3: Morning Briefing + Memory Sync
# ══════════════════════════════════════════

log ""
log "📬 Phase 3: Morning Briefing + Memory Sync"
PHASE3_START=$(now_epoch)
BRIEFING_FILE="${BRIEFING_DIR}/${DATE}.md"

(
    _briefing_start=$(now_epoch)
    log "  → Briefing starting (archive=${BRIEFING_FILE}; target=${TARGET_DATE})..."
    BRIEFING_PROMPT="Run the morning briefing for ${DATE}.

Data sources (read what's available, skip what's not):
1. Shared daily summary for the completed day: ${SUMMARY_FILE}
2. Agent memory files for the completed day: find agents/*/memory -name '${TARGET_DATE}.md'
3. Previous briefing for dedup: ${BRIEFING_DIR}/${TARGET_DATE}.md
4. Weather: use the weather tool for Vienna

Compose briefing with:
Section 1: Your Day (weather, highlights from ${TARGET_DATE}, pending items)
Section 2: System Health (brief: any issues from agent notes)

Critical:
- The briefing is for TODAY (${DATE}) but summarizes the COMPLETED PRIOR DAY (${TARGET_DATE})
- NO stale content. Short+fresh > long+stale.
- Keep it under 300 words.

Archive to: ${BRIEFING_FILE}
Then reply NO_REPLY."

    BEFORE_BRIEFING_SHA=$(file_sha "$BRIEFING_FILE")
    if oc_agent "$SUMMARY_AGENT" "$BRIEFING_PROMPT" "$BRIEFING_TIMEOUT"; then
        AFTER_BRIEFING_SHA=$(file_sha "$BRIEFING_FILE")
        BRIEFING_SIZE=0
        [ -f "$BRIEFING_FILE" ] && BRIEFING_SIZE=$(wc -c < "$BRIEFING_FILE")
        if [ "$BEFORE_BRIEFING_SHA" = "missing" ]; then
            log "  ✅ Briefing complete (${BRIEFING_SIZE}B)"
            record_task "briefing" "briefing" "created" "$(( $(now_epoch) - _briefing_start ))" "file=${BRIEFING_FILE};size=${BRIEFING_SIZE};target=${TARGET_DATE}"
        elif [ "$BEFORE_BRIEFING_SHA" = "$AFTER_BRIEFING_SHA" ]; then
            log "  ✅ Briefing unchanged (${BRIEFING_SIZE}B)"
            record_task "briefing" "briefing" "unchanged" "$(( $(now_epoch) - _briefing_start ))" "file=${BRIEFING_FILE};size=${BRIEFING_SIZE};target=${TARGET_DATE}"
        else
            log "  ✅ Briefing updated (${BRIEFING_SIZE}B)"
            record_task "briefing" "briefing" "updated" "$(( $(now_epoch) - _briefing_start ))" "file=${BRIEFING_FILE};size=${BRIEFING_SIZE};target=${TARGET_DATE}"
        fi
    else
        log "  ❌ Briefing FAILED"
        set_degraded
        record_task "briefing" "briefing" "failed" "$(( $(now_epoch) - _briefing_start ))" "file=${BRIEFING_FILE};target=${TARGET_DATE}"
    fi
) &
BRIEFING_PID=$!

log "  → Memory sync (all agents via $SUMMARY_AGENT)..."
SYNC_PIDS=()
for agent in "${AGENTS[@]}"; do
    (
        oc_agent "$SUMMARY_AGENT" "Run memory_search for '${agent} daily sync ${DATE}' to update the search index after processing ${TARGET_DATE}." "$MEMORY_SYNC_TIMEOUT" || true
    ) &
    SYNC_PIDS+=($!)
done
for pid in "${SYNC_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
done
log "  ✅ Memory sync complete"

if wait $BRIEFING_PID 2>/dev/null; then
    PHASE_RESULTS+=("phase3=ok")
    record_phase "phase3" "ok" "$(( $(now_epoch) - PHASE3_START ))" "briefing=${BRIEFING_FILE};target=${TARGET_DATE}"
else
    set_degraded
    PHASE_RESULTS+=("phase3=briefing-failed")
    record_phase "phase3" "failed" "$(( $(now_epoch) - PHASE3_START ))" "briefing=${BRIEFING_FILE};target=${TARGET_DATE}"
fi

# ══════════════════════════════════════════
# Phase 4: Status Report
# ══════════════════════════════════════════

FINAL_STATUS=$(get_status)

log ""
log "📊 Phase 4: Status Report"
log "  Status:       $FINAL_STATUS"
log "  Duration:     ${SECONDS}s"
log "  Target date:  ${TARGET_DATE}"
log "  Agent notes:  ${AGENT_CREATE_COUNT} created, ${AGENT_UPDATE_COUNT} updated, ${AGENT_UNCHANGED_COUNT} unchanged, ${AGENT_FAIL_COUNT} failed"
log "  Shared note:  ${SUMMARY_FILE}"
log "  Briefing:     ${BRIEFING_FILE}"
log "  Phases:       ${PHASE_RESULTS[*]}"

if [ "$FINAL_STATUS" = "degraded" ]; then
    log "  ⚠️ Pipeline completed with errors"
    if [ -n "$ALERT_CMD" ] && [ -z "$DRY_RUN" ]; then
        TARGET_DATE="$TARGET_DATE" DATE="$DATE" FINAL_STATUS="$FINAL_STATUS" PHASES="${PHASE_RESULTS[*]}" bash -lc "$ALERT_CMD" >/dev/null 2>&1 || true
    fi
else
    log "  ✅ Pipeline completed successfully"
fi

log ""
log "════════════════════════════════════════"
log "💙 Pipeline End: $(date +%H:%M:%S) (${SECONDS}s)"
log "════════════════════════════════════════"

rm -f "$STATUS_FILE"
exit 0
