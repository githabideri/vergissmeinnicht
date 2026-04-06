# GPU Concurrency Guide

## Overview

vergissmeinnicht is designed for **consumer GPU** setups running local LLM inference. This guide covers concurrency planning for the current pipeline shape, with an emphasis on **vLLM-based** deployments.

## Important Scope Note

This document currently mixes two levels of confidence:

1. **Measured reference characteristics** from our local vLLM setup
2. **Operational heuristics** for the current pipeline architecture

What changed: earlier versions of vergissmeinnicht only populated the shared daily memory. The current pipeline now does significantly more work in Phase 1 by creating or updating **per-agent daily memory files** first, and only then producing the shared daily summary and briefing.

That means some older phase-by-phase numbers from the previous architecture are no longer representative of the current production flow. Until we run and publish a dedicated measurement pass for the new pipeline shape, this document should be read as a **planning guide**, not as a source of exact per-phase ground-truth timings or KV percentages for every step.

## Reference Setup

**Hardware:** 3× NVIDIA RTX 3060 12GB (36 GB total VRAM)  
**Model:** Qwen3.5-35B-A3B-GPTQ-Int4 (MoE, ~3B active parameters)  
**Inference Runtime:** **vLLM** with tensor parallelism across 3 GPUs  
**KV Cache Budget:** 88K tokens / 1.91 GiB

> These concurrency assumptions depend on **vLLM** behavior, especially batching and prefix caching. They do **not** translate directly to llama.cpp.

## Prefix Caching

When multiple sessions share the same system prompt, vLLM's prefix caching can dramatically reduce memory usage.

### Typical Prefix Structure

```text
System Prompt:     ~1,500 tokens  ─┐
Agent Autoload:    ~1,500 tokens   ├── Shared prefix (~3K tokens)
────────────────────────────────  ─┘
Task-specific:     ~2,000+ tokens ─── Unique per session
```

In the current pipeline, this matters most during **Phase 1**, where multiple per-agent summary/update requests are sent through a single summary agent with a largely shared prompt prefix.

**Illustrative savings:** With 10 concurrent sessions sharing a 3K prefix:
- Without caching: 10 × 5K = 50K tokens in KV cache
- With caching: 3K + 10 × 2K = 23K tokens (54% reduction)

## Concurrency Limits

### By Context Length

| Context per Session | Max Concurrent | KV Usage | Notes |
|--------------------|----------------|----------|-------|
| 4K tokens | 22 sessions | 100% | Theoretical upper bound |
| 8K tokens | 11 sessions | 100% | Comfortable planning zone |
| 16K tokens | 5 sessions | 91% | Typical larger summary/update workloads |
| 32K tokens | 2-3 sessions | 73-100% | Large context |
| 64K tokens | 1-2 sessions | 73-100% | Very large |
| 131K tokens | 1 session | 100% | Maximum context |

*With prefix caching enabled — actual limits depend on shared-prefix ratio and task shape.*

## Current Pipeline: What We Actually Know

For the current architecture, the most defensible statements are these:

- **Phase 1 is the dominant GPU workload.**
  It now handles per-agent create/update work, potentially with existing notes, MEMORY.md excerpts, and session-log reads behind each prompt.

- **The current design assumes vLLM prefix caching is a major enabler.**
  A single summary agent is used to maximize shared-prefix reuse across many parallel requests.

- **Memory sync is negligible compared with summary generation.**
  Its prompts are short and mostly index-triggering overhead.

- **Summary + briefing are lighter in parallelism but can still be heavy in context.**
  They process aggregated artifacts rather than many small independent agent tasks.

## Operational Guidance

### Safe Starting Point

For the reference setup, a practical starting point is:

- **Per-agent note/update burst:** 6-8 concurrent tasks
- **Summary + briefing overlap:** 2 concurrent heavier tasks
- **Memory sync:** low concern unless the system is already saturated

### If You See Timeouts or Queueing

Reduce pressure in this order:

1. **Lower batch size** for Phase 1
2. **Reduce prompt/context size** before increasing raw parallelism
3. **Raise timeouts** only after confirming the system is making steady progress
4. **Inspect actual target files and logs** after degraded runs — partial success is common

## First-Request Penalty

The first request to a cold vLLM instance triggers **CUDAGraph compilation**:

- **Cold start:** 60-90 seconds (one-time per model load)
- **Warm start:** <1 second

The warmup ping exists to eliminate this penalty before the expensive prompt burst starts.

## Monitoring

### Key Metrics to Watch

```bash
# vLLM metrics endpoint
curl http://localhost:8000/metrics | grep -E "vllm_(cache|request|generation)"

# Useful indicators:
# - gpu_cache_usage_perc: KV cache utilization
# - num_requests_running: Current concurrent requests
# - num_requests_waiting: Queue depth (should ideally be 0)
# - generation_tokens_total: Throughput
```

### Red Flags

| Indicator | Threshold | Action |
|-----------|-----------|--------|
| KV cache > 95% | Reduce concurrency | Lower parallel sessions |
| Queue depth > 0 for sustained periods | System is overcommitted | Lower batch size or context |
| TG speed < 20 tok/s | Per-session slowdown | Check GPU thermals / pressure |
| OOM errors | Fatal | Reduce model size or concurrency |
| Frequent timeout 124 exits | Pipeline degradation | Check logs, batch size, prompt size, timeouts |

## What We Still Need to Measure Properly

To replace heuristics with current hard numbers, we should run a dedicated measurement pass on the **current** pipeline and capture at least:

1. **Phase 1 burst size** actually used
2. **Per-request latency** for agent create/update tasks
3. **Queue depth over time** during the burst
4. **GPU KV cache usage** during Phase 1 and during summary/briefing
5. **Effect of existing-file update mode** vs create mode
6. **End-to-end runtime** under real-world backlog conditions

The repo already contains the right direction for this work (`metrics-sampler`, cron logs, and task logs). Once we collect a few representative runs, this guide should be rewritten with measured tables for the current architecture instead of inherited approximations.
