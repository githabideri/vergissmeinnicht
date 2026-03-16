# Design Decisions

This document explains **why** vergissmeinnicht works the way it does. Each decision was made from real production experience, not theory.

---

## 1. Single Orchestrator over Job Chaining

**Decision:** One bash script controls the entire pipeline.

**Alternatives considered:**
- Separate cron jobs with fixed times
- Cron job triggers next cron job
- Workflow engine (Airflow, Temporal, etc.)

**Why we chose Single Orchestrator:**

| Approach | Problem in Practice |
|----------|-------------------|
| Separate cron jobs | Timing drift — briefing ran before summary was done. No way to express "run B after A finishes." |
| Job chaining | Debugging nightmare. Job A triggers B triggers C — when C fails, you check three different logs with three different timestamps. |
| Workflow engine | Overkill. We have 5 jobs and a 15-minute window. Airflow would take longer to configure than the pipeline takes to run. |
| **Single script** | One log file, one process, one `tail -f` to debug. |

**The clincher:** When the Context Reset job started failing silently (3 consecutive errors with no visibility), we had no unified log to diagnose it. With the orchestrator, every failure is in one place.

---

## 2. `sessions send` over Temporary Cron Jobs

**Decision:** Per-agent summaries use direct agent invocation, not temporary cron jobs.

**Why not create a cron job per agent per day?**

- 6 agents × 365 days = 2,190 cron jobs per year (bloat!)
- Each job needs cleanup logic (when? how? what if cleanup fails?)
- Cron jobs are designed for **recurring schedules**, not one-off tasks
- The orchestrator already handles retries and timeouts

**Direct invocation benefits:**
- Ephemeral — no persistent state to clean up
- Parallel — bash `&` + `wait` handles 6 agents trivially
- Isolated — one agent's failure doesn't affect others
- Logged — all output goes to the same pipeline log

---

## 3. Per-Agent Notes Before Shared Summary

**Decision:** Each agent writes its own daily note first (Phase 1), then a coordinator agent aggregates them (Phase 2).

**Why not have one agent read all sessions and summarize everything?**

- **Data ownership:** Each agent knows its own context best. Schreiber understands blog publishing; Labmaster understands GPU benchmarks.
- **Deduplication:** If an agent already wrote a note (manually or via an earlier trigger), the pipeline skips it. No overwrites.
- **Parallelism:** 6 agents writing simultaneously = 2-3 minutes. One agent reading all sessions sequentially = 10-15 minutes.
- **Prefix cache efficiency:** All agents share the same system prompt prefix. With vLLM prefix caching, this saves ~51% of KV cache across parallel sessions.

---

## 4. Bash over Python/Node

**Decision:** The orchestrator is a bash script, not a Python or Node.js program.

**Why bash?**

- **Zero dependencies:** bash, curl, jq — already on every Linux server
- **Process management is native:** `&`, `wait`, `timeout`, exit codes — bash does this in its sleep
- **Transparent:** `cat pipeline.log` tells you exactly what happened
- **Debuggable:** Add `set -x` and re-run. No debugger, no IDE needed.
- **Composable:** Each phase can call any tool (curl, CLI commands, other scripts)

**When would we switch to Python?**
If the pipeline needed complex data transformations, conditional branching based on API responses, or structured error reporting to a monitoring system. For now, bash is the right tool.

---

## 5. Graceful Degradation over Fail-Fast

**Decision:** Partial failures produce degraded output, not pipeline crashes.

**Real scenario that drove this:**
The GPU warmup failed (vLLM wasn't running). Under fail-fast, the entire pipeline stops — no summary, no briefing, nothing. Under graceful degradation:
- Warmup fails → summaries run anyway (just slower on first request)
- Summary fails → briefing reads last 3 days instead of today
- One agent fails → other agents' notes are still written

**The principle:** A degraded morning briefing is infinitely more useful than no morning briefing.

**Degradation table:**

| Component Fails | System Behavior |
|----------------|----------------|
| GPU Warmup | Agent notes run (slower first request) |
| Context Reset | Skip — stats are nice-to-have, not critical |
| Per-Agent Note (one) | Other agents unaffected; summary works with available notes |
| Daily Summary | Briefing falls back to reading last 3 days |
| Briefing | Alert sent; retry tomorrow |
| Memory Sync | Skip — agents auto-sync on next search query |

---

## 6. mc-servicebot for Notifications (Not Agent Messages)

**Decision:** Activity stats and alerts are sent via a lightweight Matrix bot, not through agent sessions.

**Why not use agent sessions for notifications?**

- Agent messages can trigger response loops (agent A posts → agent B responds → A responds → ...)
- Notifications are fire-and-forget, not conversations
- `m.notice` message type is specifically designed for bot notifications — Matrix clients style them differently

**Architecture:**
- **mc-servicebot** uses direct Matrix REST API (curl) — no encryption, no sync, no room state
- **`--notice` flag** sends as `m.notice` type (won't trigger agent responses)
- **Fallback:** matrix-commander with 12-second timeout for complex operations

---

## 7. Unified Logging to One File

**Decision:** All pipeline output goes to `logs/morning-pipeline-YYYY-MM-DD.log`.

**Why one file?**

In production, we had three separate cron jobs logging to... nowhere consistent. When the Context Reset started failing, we had to:
1. Figure out which agent ran it
2. Find that agent's session log
3. Parse JSONL to find the relevant run
4. Discover the error was "Message failed" with no further context

**With unified logging:**
```bash
tail -f logs/morning-pipeline-2026-03-16.log
```
One command. Full visibility. Every phase, every retry, every failure — timestamped and in order.

**Log format:**
```
[HH:MM:SS] message
```
Simple, greppable, readable.

---

## 8. Health Check as Independent Verification

**Decision:** A separate script (`pipeline-healthcheck.sh`) runs 1 hour after the pipeline to verify completion.

**Why not just check at the end of the pipeline?**

- The pipeline itself could crash (OOM, signal, timeout)
- The health check runs from a clean process — no shared state with the pipeline
- It can alert even if the pipeline never started (cron misconfiguration)

**Checks:**
1. Does today's daily summary file exist?
2. Did the pipeline log complete? (contains "Pipeline End")
3. Was the briefing posted? (check Matrix room)

---

## 9. Config via Environment, Not YAML

**Decision:** Configuration is in a sourced `.env` file, not YAML or JSON.

**Why?**

- Bash scripts source `.env` natively — no parser needed
- Environment variables compose naturally with systemd, Docker, cron
- One less dependency (no yq, no jq for config parsing)
- Easy to override: `AGENT_LIST="a b" ./morning-pipeline.sh`

**The config.env.example includes every variable with documentation.** Copy it, fill in your values, done.

---

## 10. Why "vergissmeinnicht"?

## 11. Sacrifice Agent + Prefix Cache Exploitation

**Decision:** Prime the LLM's prefix cache with a warmup request before launching parallel work.

**Context:** vLLM (and similar engines) cache the KV states of system prompts. If multiple requests share the same system prompt prefix, only the first request pays the full prompt-processing (PP) cost. Subsequent requests reuse the cached prefix and only process the unique user-message tail.

**What we tried:**
- 6 different agent variants in parallel → 6 different system prompts → no cache sharing → 0-30% completion rate (PP overhead × 6 overwhelmed the GPU)
- 1 agent variant × 6 parallel requests → 1 system prompt → prefix cached → **95-100% completion rate**

**The pattern:**
1. **"Sacrifice agent"** — Send a cheap warmup request to prime the prefix cache
2. **Wait** — Prefix cache is now hot
3. **Parallel burst** — Send N real requests sharing the cached prefix
4. Only the per-request variable tail (agent name, date, paths) needs PP

**Numbers (3× RTX 3060, 36GB, Qwen3.5-35B-A3B):**
- Warmup: ~8-10 seconds
- Per-note with warm cache: ~15-25 seconds
- 42 notes (7 days × 6 agents): 69 seconds total (incl. skip checks)
- Optimal parallelism: 6 concurrent (2 per GPU)

**Why it matters:** This turns moderate hardware into a practical daily pipeline. Without prefix cache exploitation, the same hardware couldn't complete the pipeline within reasonable timeouts.

---

## 12. Pre-Inject Ground Truth over Trust-the-Model

**Decision:** Extract relevant MEMORY.md excerpts and inject them directly into each prompt, rather than asking the model to read the file itself.

**Problem:** When asked to "read MEMORY.md and check for activity on date X", the model would sometimes:
- Claim the file doesn't exist (it does)
- Skip the Read tool call entirely
- Write "no activity" without investigating

This happened consistently with a file that was 19KB and had an explicit section header matching the target date.

**Solution:** The orchestrator script runs `grep -B2 -A20 "$date" MEMORY.md` and injects the excerpt directly into the prompt. The model receives the evidence as part of its input — it cannot claim the data doesn't exist when it's literally in the message.

**Result:** Quality jumped from 0/10 to 10/10 for the critical test case.

**Principle:** For batch/automated workflows, pre-compute what you can. Don't rely on multi-step tool-use chains when you can hand the model the answer as context. This is especially important for smaller models (7-35B) that are less reliable at complex tool orchestration.

---

## 13. Project Name

*Vergissmeinnicht* (German: "forget-me-not" 💙) — the flower that symbolizes remembrance.

The pipeline exists because AI agents forget. Every day, they wake up with no memory of yesterday unless someone writes it down. vergissmeinnicht is that someone.

The name also reflects the project's origin in a German-speaking team where technical precision meets a love for expressive naming.

---

*Last updated: 2026-03-16*
