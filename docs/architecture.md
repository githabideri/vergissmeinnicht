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

Phase 1: SEQUENTIAL
└── Daily Summary (5-10 min) ── Depends on nothing, but briefing depends on it

Phase 2: PARALLEL
├── Morning Briefing (2-3 min) ── Reads summary
└── Memory Sync (10s) ────────── Independent

Phase 3: REPORT
└── Status + Logging (instant)
```

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
| Warmup | Summary runs (just slower first request) |
| Context Reset | Skip — non-critical |
| Daily Summary | Briefing uses last 3 days instead |
| Briefing | Alert only, retry tomorrow |
| Memory Sync | Skip — agents auto-sync on next search |

**Principle:** Deliver degraded service rather than total failure.

## Pipeline Timing

### Happy Path (~12 minutes)

```
00:00  Pipeline starts
00:05  Warmup + Context Reset (parallel)
01:35  Warmup done
01:35  Daily Summary starts
09:00  Summary done (worst case)
09:00  Briefing + Memory Sync (parallel)
12:00  Both done
12:05  Status report logged
```

### Budget: 15 Minutes

The pipeline is designed to fit within a 15-minute GPU window. If a job exceeds its timeout, it's killed and the pipeline continues with degraded output.

### Health Check (Independent)

Runs 1 hour after pipeline (separate cron entry):
- Checks summary file exists
- Verifies pipeline log shows completion
- Alerts on failures

## Data Flow

```
Session Logs ──┐
Agent Memory ──┼──▶ Daily Summary ──▶ memory/YYYY-MM-DD.md
System Metrics ┘                          │
                                          ▼
Weather ──────────┐                  Morning Briefing ──▶ Team Channel
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
- Agent orchestration system

**No heavy dependencies** — no Node.js, no Python frameworks, no Docker required for the pipeline itself.
