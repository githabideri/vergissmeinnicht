# 💙 vergissmeinnicht

**A morning pipeline for AI agent teams — so nothing gets forgotten.**

vergissmeinnicht is a reusable morning-orchestration pipeline for multi-agent AI systems. We use it with OpenClaw, but the core pattern is broader: any setup with multiple semi-persistent agents, session logs, agent-local memory files, and a shared coordination surface can use the same approach.

The project exists to solve a very practical problem: after a busy day, agent activity is scattered across many session transcripts, room conversations, tool calls, and half-finished threads. By the next morning, that context is expensive to reconstruct manually, easy to miss, and hard to search consistently. vergissmeinnicht turns that mess into a daily rhythm: first capture what each agent actually did for the completed prior day, then aggregate it into a shared daily memory, then generate a morning briefing for humans, and finally sync indices so the whole system can find the new knowledge again.

The order matters. Per-agent notes come first because they are the closest thing to ground truth for each agent. The shared daily summary comes second because it should be built from those agent-local notes, not from vague global impressions. The morning briefing comes third because humans want a short operational overview for **today**, but it should be grounded in what actually happened **yesterday**. Around that core, the pipeline also warms up inference, sends context-reset activity stats, and refreshes memory search so the new notes are immediately usable.

## Why the flow is structured this way

vergissmeinnicht intentionally separates three different time concepts:

- **Run date (`DATE`)** — the morning when the pipeline runs
- **Target date (`TARGET_DATE`)** — the completed prior day being summarized
- **Briefing date** — also `DATE`, because the briefing is for *today* even though it summarizes `TARGET_DATE`

This distinction prevents a common source of drift and confusion: writing “today’s” files before the day has even happened. The pipeline therefore treats per-agent notes and the shared daily summary as records for the **completed prior day**, while the briefing is archived under the **current morning’s date**.

It also aims to be idempotent. If a per-agent note or shared summary for the target date already exists, the job should **read first, then update carefully**, not blindly overwrite, and not duplicate content. That makes re-runs safe after partial failures, degraded runs, or late-arriving corrections.

## Current Flow

```text
Morning Pipeline (run date = DATE, target date = TARGET_DATE = completed prior day)

Phase 0 ─ Warmup + Context Reset
  ├─ Warmup ping primes model / prefix cache
  └─ Context reset posts room activity stats for TARGET_DATE

Phase 1 ─ Per-Agent Summaries   ← THE CORE
  ├─ for each configured agent, resolve workspace + sessions path
  ├─ target file: agents/<agent>/memory/TARGET_DATE.md
  ├─ if target file exists:
  │    ├─ read existing file first
  │    ├─ read MEMORY.md and relevant session logs
  │    └─ update carefully, preserving valid content and avoiding duplicates
  └─ if target file does not exist:
       ├─ read MEMORY.md and relevant session logs
       └─ create new daily memory note for TARGET_DATE

Phase 2 ─ Shared Daily Summary
  ├─ read all agents/*/memory/TARGET_DATE.md
  ├─ optionally read previous shared summary for dedup/context
  └─ create or update memory/TARGET_DATE.md

Phase 3 ─ Morning Briefing + Memory Sync
  ├─ Briefing
  │    ├─ read memory/TARGET_DATE.md
  │    ├─ read per-agent notes for TARGET_DATE
  │    ├─ read weather / system-health inputs
  │    └─ archive briefing to memory/briefings/DATE.md
  └─ Memory Sync
       └─ refresh memory search index after the new notes were written

Phase 4 ─ Status Report
  ├─ log created / updated / unchanged / failed counts
  ├─ surface degraded runs
  └─ optionally send alert notice
```

## What It Does

- writes or updates **per-agent daily memory** for the completed prior day
- builds a **shared daily memory** from those agent-local notes
- generates a **morning briefing** for humans
- warms up local inference before the heavy prompt burst
- sends **context reset** activity stats to team channels
- refreshes **memory search indices** after new notes are written
- logs enough state to diagnose degraded runs and re-run safely

**Total runtime:** typically ~15 minutes on consumer GPUs, depending on model, context size, and agent count.

## Features

- 📓 **Per-Agent Notes** — Each agent creates or updates the note for the completed prior day at `agents/<name>/memory/TARGET_DATE.md`
- 📝 **Daily Summary** — Aggregates all per-agent notes into a shared note for that same `TARGET_DATE`
- 🔥 **GPU Warmup** — Pre-compiles CUDAGraph and primes prefix cache before real work
- 🌅 **Context Reset** — Posts activity stats to channels (message counts, token estimates)
- 📬 **Morning Briefing** — Generates a daily briefing for `DATE`, grounded in the completed prior day
- 🧠 **Memory Sync** — Updates memory search indices for all agents in parallel
- 🏥 **Health Check** — Independent verification that the pipeline completed (runs later)
- 🛡️ **Graceful Degradation** — Partial failures do not have to crash the whole pipeline
- ♻️ **Re-run Safety** — Existing files should be read first and updated carefully, not blindly replaced

## Architecture

**Single Orchestrator Pattern** — one bash script controls the entire pipeline:

- no complex cron job chaining
- no temporary cron jobs for one-off daily work
- inline retries and configurable timeouts
- parallel execution where safe (warmup + context reset, per-agent notes, briefing + memory sync)
- sequential execution where required (agent notes → shared summary → briefing)
- repo-first canonical script, with deployment-local config in `config.env`

See [docs/architecture.md](docs/architecture.md) for the full design and [docs/design-decisions.md](docs/design-decisions.md) for the reasoning behind each choice.

## Quick Start

### Prerequisites

- Linux server with bash 4+, curl, jq, python3
- AI inference endpoint (vLLM, ollama, or cloud API)
- a messaging surface for notices / briefings (Matrix in our setup, but adaptable)
- agent orchestration system (e.g. [OpenClaw](https://github.com/openclaw/openclaw))
- per-agent session history and per-agent memory directories

### Installation

```bash
# Clone
git clone https://github.com/githabideri/vergissmeinnicht.git
cd vergissmeinnicht

# Copy example config
cp examples/config.env.example config.env

# Edit with your settings
nano config.env

# Make scripts executable
chmod +x scripts/*.sh

# Test manually
bash scripts/morning-pipeline.sh

# Add to crontab
crontab -e
# 0 6 * * * /path/to/vergissmeinnicht/scripts/morning-pipeline.sh
# 0 7 * * * /path/to/vergissmeinnicht/scripts/pipeline-healthcheck.sh
```

### Configuration

Copy `examples/config.env.example` and fill in your values:

```bash
# GPU Inference
VLLM_URL="http://localhost:8000"
VLLM_MODEL="your-model-name"

# Matrix Notifications
MATRIX_HOMESERVER="https://matrix.example.com"
MATRIX_TOKEN="your-access-token"
MATRIX_ROOMS=("!room1:server|name1" "!room2:server|name2")

# Agents
AGENTS=(agent1 agent2 agent3)

# Paths
WORKSPACE="/path/to/workspace"
AGENT_DIR="${WORKSPACE}/agents"
SUMMARY_DIR="${WORKSPACE}/memory"
BRIEFING_DIR="${SUMMARY_DIR}/briefings"
```

## Scripts

| Script | Purpose | Duration |
|--------|---------|----------|
| `morning-pipeline.sh` | Main orchestrator | ~15 min |
| `context-reset-stats.sh` | Activity stats to Matrix | ~5s |
| `pipeline-healthcheck.sh` | Verify completion | ~2s |

## Data Flow

```text
Session logs / MEMORY.md / existing note for TARGET_DATE
    │
    ▼
agents/<agent>/memory/TARGET_DATE.md      ← per-agent memory (create or update)
    │
    ▼
memory/TARGET_DATE.md                     ← shared daily summary for completed prior day
    │
    ├─ read by humans / other agents later
    └─ read by morning briefing generator on DATE
              │
              ▼
memory/briefings/DATE.md                  ← today's briefing archive
```

Each agent only gets its own local evidence during Phase 1. The shared summary aggregates across all agents, but it is still tied to `TARGET_DATE`. The briefing is the human-facing view for `DATE`.

## GPU Concurrency Notes

Tested with **3× RTX 3060 12GB** (36 GB VRAM) running Qwen3.5-35B-A3B-GPTQ-Int4:

| Scenario | Concurrent Sessions | KV Cache Usage |
|----------|-------------------|----------------|
| Per-agent notes (6 agents parallel) | 6 | ~40% |
| Summary + Briefing | 2 | ~52% |
| Memory sync (all agents) | 6-8 | trivial |
| Backlog batch (10-15 parallel) | 10-15 | ~60-80% |

**Prefix caching** saves ~51% tokens across sessions sharing the same system prompt.

See [docs/gpu-concurrency.md](docs/gpu-concurrency.md) for detailed analysis.

## Notification System

Uses a lightweight Matrix bot (`servicebot`) to send activity stats:

- **m.notice** type messages (won't trigger bot responses)
- **Unencrypted** via Matrix Client API (curl)
- **Conditional** — only sends to rooms with human activity
- **Alert path** for degraded runs

See [docs/notifications.md](docs/notifications.md) for setup.

## Project Name

*Vergissmeinnicht* (German: "forget-me-not" 💙) — the flower that symbolizes remembrance and faithfulness. Because this pipeline makes sure your AI agents never forget yesterday's work.

## License

MIT — see [LICENSE](LICENSE)

---

*Built with 🌸 by the [OpenClaw](https://github.com/openclaw/openclaw) community*
