# Architecture

## Design Philosophy

**Single Orchestrator** — one entry point, full control.

Instead of chaining multiple independent cron jobs (which is fragile, hard to debug, and creates timing issues), vergissmeinnicht uses a single bash script that orchestrates all jobs sequentially and in parallel where safe.

### Why Not Job Chaining?

| Approach | Problem |
|----------|---------|
| Separate cron jobs with fixed times | Timing drift, no dependency awareness |
| Cron job triggers next cron job | Complex, hard to debug, circular risks |
| Workflow engine (Airflow, etc.) | Overkill for 5 jobs |
| **Single script with inline logic** | ✅ Simple, debuggable, reliable |

### Execution Model

```
Phase 0: PARALLEL
├── Warmup Ping (60-90s) ─── Primes GPU inference
└── Context Reset (5s) ──── Sends activity stats

Phase 1: PARALLEL (per agent)                    ← THE CORE
├── Agent A: read sessions → write own note
├── Agent B: read sessions → write own note
├── Agent C: read sessions → write own note
└── ...
    Each agent writes ONLY to: agents/<name>/memory/YYYY-MM-DD.md
    Skips if entry for that date already exists.

Phase 2: SEQUENTIAL
└── Daily Summary ── Reads all agent notes, writes shared summary
    Input:  agents/*/memory/YYYY-MM-DD.md
    Output: workspace/memory/YYYY-MM-DD.md

Phase 3: PARALLEL
├── Morning Briefing (2-3 min) ── Reads shared summary
└── Memory Sync (10s) ────────── Triggers index updates

Phase 4: REPORT
└── Status + Logging (instant)
```

### The Core: Per-Agent Summaries

This is the heart of vergissmeinnicht. Each agent:

1. **Reads its own session history** since the last context reset
2. **Checks** if `agents/<name>/memory/YYYY-MM-DD.md` already exists
3. **If not:** Summarizes sessions into a daily note and writes it
4. **If yes:** Skips (no duplication; agent may have written notes during the day)

**Key rules:**
- Each agent writes ONLY its own notes
- No cross-contamination (labmaster never gets schreiber content)
- Existing entries are preserved (human or agent-written notes take priority)
- Notes are each agent's personal memory — treat them as such

### Why Agent Notes First, Summary Second?

The per-agent notes are the **source of truth**. The shared daily summary merely aggregates them for overview purposes (briefings, cross-agent awareness). This ensures:

- Each agent's memory is coherent and relevant to its role
- The shared summary can be regenerated from agent notes
- Agents don't need to understand other agents' domains
- `memory_search` per agent returns only relevant results

### Error Handling

Each job has:
- **Timeout** — kills runaway processes
- **Retries** — configurable attempts with delay
- **Fallback** — degraded behavior on failure

```bash
run_with_retry() {
    local job_name="$1"
    local timeout_s="$2"
    local max_retries="${3:-2}"
    
    for attempt in $(seq 1 $max_retries); do
        if timeout "$timeout_s" run_job "$job_name"; then
            return 0
        fi
        log "⚠️ $job_name attempt $attempt/$max_retries failed"
        sleep 10
    done
    log "❌ $job_name FAILED after $max_retries attempts"
    return 1
}
```

### Graceful Degradation

| Job Fails | System Behavior |
|-----------|----------------|
| Warmup | Agent notes run (just slower first request) |
| Context Reset | Skip — non-critical |
| Per-Agent Notes | Summary uses whatever notes exist |
| Daily Summary | Briefing uses last 3 days instead |
| Briefing | Alert only, retry tomorrow |
| Memory Sync | Skip — agents auto-sync on next search |

**Principle:** Deliver degraded service rather than total failure.

## Pipeline Timing

### Happy Path (~15 minutes)

```
00:00  Pipeline starts
00:05  Warmup + Context Reset (parallel)
01:35  Warmup done
01:35  Per-Agent Summaries start (parallel, all agents)
04:00  Agent notes done (~2-3 min with parallelism)
04:00  Daily Summary starts (aggregation)
07:00  Summary done
07:00  Briefing + Memory Sync (parallel)
10:00  Both done
10:05  Status report logged
```

### Budget: 15 Minutes

The pipeline is designed to fit within a 15-minute GPU window. If a job exceeds its timeout, it's killed and the pipeline continues with degraded output.

### Health Check (Independent)

Runs 1 hour after pipeline (separate cron entry):
- Checks agent notes exist for today
- Checks shared summary file exists
- Verifies pipeline log shows completion
- Alerts on failures

## Data Flow

```
Session Logs ──┐
(per agent)    │
               ▼
          Per-Agent Notes ──▶ agents/<name>/memory/YYYY-MM-DD.md
               │
               ▼
          Daily Summary ───▶ workspace/memory/YYYY-MM-DD.md
               │
               ▼
Weather ──────────┐
System Metrics ───┤    Morning Briefing ──▶ Team Channel
Pending Tasks ────┤
Cron Reminders ───┘

Matrix API ──▶ Message Stats ──▶ Context Reset ──▶ Agent Channels
```

## Dependencies

**Minimal:**
- bash 4+
- curl
- jq
- python3 (for URL encoding)

**Optional:**
- GNU coreutils (for `timeout`, `date -d`)
- Agent orchestration system (for session history access)

**No heavy dependencies** — no Node.js, no Python frameworks, no Docker required for the pipeline itself.
