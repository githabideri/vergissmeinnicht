# Vergissmeinnicht Morning Pipeline — Deployment Notes

## Dual-Mode Inference Support

The pipeline works with both **vLLM** (parallel execution) and **llama.cpp** (sequential execution).

### vLLM (Parallel)

- **Batch size:** 10-20 concurrent sessions
- **Runtime:** ~15-30 min for 7 agents
- **Config:** `INFERENCE_BACKEND="vllm"`
- **Prefix caching:** ~51% token savings across shared system prompts

### llama.cpp (Sequential)

- **Batch size:** 1 (no parallelism per instance)
- **Runtime:** ~60-120 min for 7 agents
- **Config:** `INFERENCE_BACKEND="llama-cpp"` or `auto`
- **Recommendation:** Consider multiple instances for parallelism

### Auto-Detection

The pipeline auto-detects the backend at startup:
1. Checks vLLM endpoint (configurable)
2. Falls back to llama.cpp endpoint
3. Sets `INFERENCE_BACKEND` accordingly

## Agent Coverage Patterns

### Standard Pattern (Pipeline Phase 1)

Most agents run through Phase 1 (per-agent summaries):
- Pipeline invokes `localbot-<agent>` for each agent
- Each agent writes its daily summary at `agents/<agent>/memory/TARGET_DATE.md`
- Pipeline reads all notes in Phase 2 (shared summary)

### Independent Creation Pattern

Some agents may have independent creation mechanisms:
- Agent has its own cron job that creates daily summary
- Pipeline skips Phase 1 invocation for that agent
- Pipeline reads the agent's note in Phase 2 (shared summary)

**Example:** Planning agent may have its own `planning-briefing` cron that creates its daily summary independently. The pipeline reads it in Phase 2 without invoking `localbot-planning` in Phase 1.

## Configuration Guide

### Backend Selection

**vLLM preferred for parallelism:**
```bash
INFERENCE_URL="http://vllm-host:8000"
INFERENCE_BACKEND="vllm"
```

**llama.cpp fallback:**
```bash
INFERENCE_URL="http://llama-cpp-host:8081"
INFERENCE_BACKEND="llama-cpp"
```

**Auto-detect both:**
```bash
INFERENCE_URL="http://your-backend:port"
INFERENCE_BACKEND="auto"
```

### Agent Configuration

**Standard agents (all run through Phase 1):**
```bash
AGENTS=(agent1 agent2 agent3)
```

**Exclude agents with independent creation:**
```bash
# Remove planning from this list if it has its own cron
AGENTS=(agent1 agent2 agent3)
```

**Workspace paths:**
```bash
declare -A AGENT_WORKSPACE=(
  [agent1]="${WORKSPACE}/agents/agent1"
  [agent2]="${WORKSPACE}/agents/agent2"
  [agent3]="${WORKSPACE}/agents/agent3"
)
```

## Troubleshooting

### Pipeline marked "degraded" but files exist

**Symptom:** Pipeline reports failure for an agent even though the note file exists and is correct.

**Possible causes:**
1. Agent has independent creation mechanism (should be excluded from Phase 1)
2. Agent invocation returned empty trace despite success
3. File was written by a different process after pipeline check

**Fixes:**
- If agent has independent creation: exclude from `AGENTS` list
- Review prompt engineering if trace is empty
- Adjust `FILE_SETTLE_TIMEOUT_S` if race condition

### Runtime too long

**Causes:**
1. Sequential llama.cpp execution (single instance)
2. Model loading delays on first run
3. Agent prompts taking full timeout

**Mitigation:**
1. Enable warmup phase (primes model)
2. Consider parallel llama.cpp instances
3. Reduce `AGENT_SUMMARY_TIMEOUT` if agents finish faster
4. Switch to vLLM for parallelism

### Empty trace files

**Symptom:** Agent call returns exit code 0 but trace file contains only config warnings, no content.

**Analysis:**
- Check trace directory: `logs/crons/morning-pipeline-YYYY-MM-DD-trace-*/`
- Compare with working agent traces
- Check if agent has independent creation mechanism

**Fix:** Review prompt engineering or exclude from Phase 1.

## Future Improvements

1. **Parallel llama.cpp:** Run multiple instances for true parallelism
2. **Metrics collection:** Track actual vs expected runtimes
3. **Better failure detection:** Distinguish between "empty trace" and "independent creation"
4. **vLLM recovery:** Restore vLLM when hardware config resolved

---

*See `config.env.example` for full configuration options.*
