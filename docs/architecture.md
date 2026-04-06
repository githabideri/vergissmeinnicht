# Architecture

## Design Philosophy

**Single Orchestrator** — one entry point, full control.

Instead of chaining multiple independent cron jobs (which is fragile, hard to debug, and creates timing issues), vergissmeinnicht uses a single bash script that orchestrates all jobs sequentially and in parallel where safe.

### Why Not Job Chaining?

| Approach | Problem |
|----------|---------|
| Separate cron jobs with fixed times | Timing drift, no dependency awareness |
| Cron job triggers next cron job | Complex, hard to debug, circular risks |
| Workflow engine (Airflow, etc.) | Overkill for a small morning pipeline |
| **Single script with inline logic** | ✅ Simple, debuggable, reliable |

## Time Model

vergissmeinnicht separates three time concepts on purpose:

- **`DATE`** — the current morning / run date
- **`TARGET_DATE`** — the completed prior day being summarized
- **Briefing archive date** — also `DATE`, because the briefing is for today

This distinction is essential. The pipeline should not create a “daily memory” for an unfinished day. Instead, it writes per-agent and shared memory artifacts for `TARGET_DATE`, then creates a human-facing morning briefing for `DATE`.

## Execution Model

```text
Phase 0: PARALLEL
├── Warmup Ping ───────────── primes GPU inference / prefix cache
└── Context Reset ─────────── posts activity stats and establishes day cutoff

Phase 1: PARALLEL (per agent)                ← THE CORE
├── resolve agent workspace + session path
├── target: agents/<agent>/memory/TARGET_DATE.md
├── if target exists:
│   ├── read existing file first
│   ├── read MEMORY.md + session evidence
│   └── update carefully, preserve good content, avoid duplicates
└── if target does not exist:
    ├── read MEMORY.md + session evidence
    └── create new note for TARGET_DATE

Phase 2: SEQUENTIAL
└── Shared Daily Summary
    Reads all agents/*/memory/TARGET_DATE.md
    Writes or updates memory/TARGET_DATE.md

Phase 3: PARALLEL
├── Morning Briefing ─────── reads TARGET_DATE artifacts, archives to briefing/DATE.md
└── Memory Sync ─────────── refreshes indices after new notes are written

Phase 4: REPORT
└── Status + Logging + optional alert
```

## Data Ownership

**Critical principle:** Each agent owns its own memory.

```text
agents/schreiber/memory/2026-03-17.md  ← only Schreiber's work for that completed day
agents/labmaster/memory/2026-03-17.md  ← only Labmaster's work for that completed day
agents/planning/memory/2026-03-17.md   ← only Planning's work for that completed day

workspace/memory/2026-03-17.md         ← aggregated overview for that completed day
workspace/memory/briefings/2026-03-18.md ← today's morning briefing
```

The pipeline should never flatten everything into a single undifferentiated note too early. Per-agent notes are the ground layer; the shared summary is a derived artifact.

## Per-Agent Summary Phase (Phase 1)

For each agent:

1. Resolve workspace path and session-log path
2. Set target file to `agents/<agent>/memory/TARGET_DATE.md`
3. Determine mode:
   - **create** if the target file does not exist
   - **update** if the target file already exists
4. Read local evidence:
   - existing target file, if present
   - `MEMORY.md`, if present
   - session logs relevant to `TARGET_DATE`
5. Write back a clean, non-duplicated daily memory note
6. Validate basic output shape (file exists, header/date sane, etc.)

This phase is deliberately designed to be **idempotent**. Re-running after a degraded run should improve or complete the result, not create duplicates.

## Shared Summary Phase (Phase 2)

The shared daily summary is built from the completed per-agent notes, not directly from raw session logs.

Inputs:
- `agents/*/memory/TARGET_DATE.md`
- optionally the previous shared summary for dedup/context
- optionally supplemental session metadata

Output:
- `memory/TARGET_DATE.md`

This separation matters because the shared summary should summarize the summaries, not re-invent them from partial global visibility.

## Briefing Phase (Phase 3)

The morning briefing is the human-facing artifact for the **current day**.

Inputs:
- shared summary for `TARGET_DATE`
- per-agent notes for `TARGET_DATE`
- optional weather and system-health inputs
- optional previous briefing for dedup/style continuity

Output:
- `memory/briefings/DATE.md`
- delivery to the chosen human-facing surface

The briefing is therefore **about today**, but **grounded in yesterday**.

## Context Reset: Why It Exists

The context reset is not just a cosmetic status message.

It has two important roles:

1. **Creates a documented daily cutoff**
   - new day, new context
   - easier to reason about what belongs to which day
   - gives the pipeline a clean operational boundary

2. **Avoids long-session memory drift**
   - long-lived sessions drag stale context across days
   - auto-compaction and “please remember X” workflows are fragile
   - provider cache windows are often short, so huge contexts become expensive again the next day
   - on local inference, large stale contexts waste KV cache / VRAM

vergissmeinnicht solves this by externalizing durable memory to files and resetting the conversational working set.

## Logging and Observability

The pipeline should log enough information to debug degraded runs without guesswork.

Useful categories include:

- run date and target date
- per-agent target file
- per-agent mode (`create` / `update`)
- session counts or evidence counts
- result classification (`created` / `updated` / `unchanged` / `failed`)
- output size and basic header/date validation
- per-phase timings
- degraded vs successful final state

This is especially important because a run can fail partially while still producing useful artifacts.

## Error Handling

Each phase should be allowed to degrade independently where possible.

| Job Fails | System Behavior |
|-----------|----------------|
| Warmup | Continue — real work may just start slower |
| Context Reset | Continue — cutoff message missing, but pipeline can still run |
| Some Per-Agent Notes | Continue with partial set, mark degraded |
| Shared Summary | Briefing may fail or need partial fallback |
| Briefing | Core memory artifacts may still be valid |
| Memory Sync | New notes exist, searchability may lag |

**Principle:** deliver degraded but inspectable output rather than total failure.

## Pipeline Timing

The exact runtime depends on model, hardware, prompt size, and how many agents need create vs update work.

A healthy run on the reference setup is typically in the rough range of **~15 minutes**, but this should be treated as an operational expectation, not a hard guarantee.

## Health Check

A separate health check can run later and verify, at minimum:

- per-agent target files exist for `TARGET_DATE`
- shared summary exists for `TARGET_DATE`
- briefing archive exists for `DATE`
- pipeline log reached completion
- degraded states are surfaced clearly

## Data Flow

```text
Session History / MEMORY.md / Existing Target File
                    │
                    ▼
            Per-Agent Notes
       agents/*/memory/TARGET_DATE.md
                    │
                    ▼
         Shared Daily Summary
           memory/TARGET_DATE.md
                    │
        ┌───────────┴───────────┐
        ▼                       ▼
   Morning Briefing         Memory Sync
 briefing/DATE.md           refresh indices
```

## Dependencies

**Minimal:**
- bash 4+
- curl
- jq
- python3

**Typical local-runtime stack:**
- vLLM for the measured reference setup
- local or remote agent orchestration system
- readable session history and writable memory directories

**No workflow-engine dependency required.**
The whole point is to stay small, direct, and debuggable.
