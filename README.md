# 💙 vergissmeinnicht

**A morning pipeline for AI agent teams — so nothing gets forgotten.**

vergissmeinnicht automates the daily routine for multi-agent AI setups: write per-agent daily notes from session history, aggregate them into a shared summary, warm up GPU inference, send briefings, sync memory indices, and post activity stats to your team channels.

## What It Does

```
07:00 ─── Cron Trigger
            │
    ┌───────┴────────┐
    │                │
    ▼                ▼
 Warmup          Context
 Ping            Reset
 (GPU warm)      (activity stats)
    │                │
    └───────┬────────┘
            ▼
   Per-Agent Summaries          ← THE CORE
   (each agent summarizes
    the completed prior day
    → agents/<name>/memory/TARGET_DATE.md)
            │
            ▼
      Daily Summary
      (aggregates all agent
       notes → memory/TARGET_DATE.md)
            │
    ┌───────┴────────┐
    │                │
    ▼                ▼
  Morning        Memory
  Briefing       Sync
  (archived as    (all agents)
   briefing/DATE.md)
            │
            ▼
      Status Report ✅
```

**Total runtime:** ~15 minutes on consumer GPUs

## Features

- 📓 **Per-Agent Notes** — Each agent creates or updates the note for the completed prior day at `agents/<name>/memory/TARGET_DATE.md`
- 📝 **Daily Summary** — Aggregates all per-agent notes into a shared note for that same `TARGET_DATE`
- 🔥 **GPU Warmup** — Pre-compiles CUDAGraph and primes prefix cache before real work
- 🌅 **Context Reset** — Posts activity stats to channels (message counts, token estimates)
- 📬 **Morning Briefing** — Generates a daily briefing with weather, system health, pending tasks
- 🧠 **Memory Sync** — Updates memory search indices for all agents in parallel
- 🏥 **Health Check** — Independent verification that the pipeline completed (runs 1h later)
- 🛡️ **Graceful Degradation** — Partial failures don't crash the whole pipeline

## Architecture

**Single Orchestrator Pattern** — one bash script controls the entire pipeline:

- No complex cron job chaining
- No job dependencies to manage
- Inline retries with configurable timeouts
- Parallel execution where safe (warmup + context reset, per-agent notes, briefing + memory sync)
- Sequential where required (agent notes → summary → briefing)

See [docs/architecture.md](docs/architecture.md) for the full design and [docs/design-decisions.md](docs/design-decisions.md) for the reasoning behind each choice.

## Quick Start

### Prerequisites

- Linux server with bash 4+, curl, jq, python3
- AI inference endpoint (vLLM, ollama, or cloud API)
- Matrix homeserver (for notifications) — or adapt to Slack/Discord
- Agent orchestration system (e.g., [OpenClaw](https://github.com/openclaw/openclaw))

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

```
Agent Sessions (for completed prior day = TARGET_DATE)
    │
    ▼ (per agent, parallel)
agents/schreiber/memory/TARGET_DATE.md    ← agent's own memory
agents/labmaster/memory/TARGET_DATE.md    ← agent's own memory
agents/planning/memory/TARGET_DATE.md     ← agent's own memory
    │
    ▼ (aggregate)
workspace/memory/TARGET_DATE.md           ← shared overview for that completed day
    │
    ▼ (read on DATE=today)
Morning Briefing → Team Channel
archive: workspace/memory/briefings/DATE.md
```

Each agent only gets its own notes. The shared summary aggregates across all agents but lives separately.

## GPU Concurrency Notes

Tested with **3× RTX 3060 12GB** (36 GB VRAM) running Qwen3.5-35B-A3B:

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

See [docs/notifications.md](docs/notifications.md) for setup.

## Project Name

*Vergissmeinnicht* (German: "forget-me-not" 💙) — the flower that symbolizes remembrance and faithfulness. Because this pipeline makes sure your AI agents never forget yesterday's work.

## License

MIT — see [LICENSE](LICENSE)

---

*Built with 🌸 by the [OpenClaw](https://github.com/openclaw/openclaw) community*
