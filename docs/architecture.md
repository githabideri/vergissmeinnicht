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

Phase 1: PARALLEL (per agent)              ← THE CORE
├── Agent A: read sessions → write own daily note
├── Agent B: read sessions → write own daily note
├── Agent C: read sessions → write own daily note
└── (skips if agent already has a note for that day)

Phase 2: SEQUENTIAL
└── Daily Summary (2-5 min)
    Reads all agents/*/memory/YYYY-MM-DD.md
    Writes shared workspace/memory/YYYY-MM-DD.md

Phase 3: PARALLEL
├── Morning Briefing (2-3 min) ── Reads shared summary
└── Memory Sync (10s) ────────── Triggers index update

Phase 4: REPORT
└── Status + Logging (instant)
```

### Data Ownership

**Critical principle:** Each agent owns its own memory.

```
agents/schreiber/memory/2026-03-14.md  ← only Schreiber's work
agents/labmaster/memory/2026-03-14.md  ← only Labmaster's work
agents/planning/memory/2026-03-14.md   ← only Planning's work

workspace/memory/2026-03-14.md         ← aggregated overview (all agents)
```

The pipeline NEVER copies shared content into agent-specific directories. Each agent's daily note contains only what that agent did.

### Per-Agent Summary (Phase 1)

For each agent:
1. Read session history since last context reset
2. Check if `agents/<agent>/memory/YYYY-MM-DD.md` already exists
3. If no entry exists: summarize sessions and write the note
4. If entry exists: skip (don't duplicate)

This runs **in parallel** across all agents — with prefix caching, 6 agents at ~8K context each use only ~40% of KV cache.

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
| Daily Summary | Briefing reads last 3 days instead |
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
04:00  All agent notes written
04:00  Daily Summary starts (reads agent notes)
06:30  Summary done
06:30  Briefing + Memory Sync (parallel)
09:00  Both done
09:05  Status report logged
```

### Budget: 15 Minutes

The pipeline is designed to fit within a 15-minute GPU window. If a job exceeds its timeout, it's killed and the pipeline continues with degraded output.

### Health Check (Independent)

Runs 1 hour after pipeline (separate cron entry):
- Checks agent notes exist
- Checks shared summary file exists
- Verifies pipeline log shows completion
- Alerts on failures

## Data Flow

```
Session History ──────────────────────────────────────┐
(per agent, since last reset)                         │
                                                      ▼
                                              Per-Agent Notes
                                              agents/*/memory/YYYY-MM-DD.md
                                                      │
                    ┌─────────────────────────────────┤
                    ▼                                  ▼
             Daily Summary                      Memory Sync
             workspace/memory/YYYY-MM-DD.md     (update search indices)
                    │
        ┌───────────┤
        ▼           ▼
   Briefing    Context Reset
   (planning)  (activity stats)
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
