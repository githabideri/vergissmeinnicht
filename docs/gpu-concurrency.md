# GPU Concurrency Guide

## Overview

vergissmeinnicht is designed for **consumer GPU** setups running local LLM inference. This guide covers concurrency planning for different hardware configurations.

## Reference Setup

**Hardware:** 3× NVIDIA RTX 3060 12GB (36 GB total VRAM)  
**Model:** Qwen3.5-35B-A3B-GPTQ-Int4 (MoE, ~3B active parameters)  
**Inference:** vLLM with tensor parallelism across 3 GPUs  
**KV Cache Budget:** 88K tokens / 1.91 GiB

## Prefix Caching

When multiple sessions share the same system prompt (common in multi-agent setups), vLLM's prefix caching can dramatically reduce memory usage.

### Typical Prefix Structure

```
System Prompt:     ~1,500 tokens  ─┐
Agent Autoload:    ~1,500 tokens   ├── Shared prefix (~3K tokens)
────────────────────────────────  ─┘
Task-specific:     ~2,000 tokens  ─── Unique per session
```

**Savings:** With 10 concurrent sessions sharing a 3K prefix:
- Without caching: 10 × 5K = 50K tokens in KV cache
- With caching: 3K + 10 × 2K = 23K tokens (54% reduction)

## Concurrency Limits

### By Context Length

| Context per Session | Max Concurrent | KV Usage | Notes |
|--------------------|----------------|----------|-------|
| 4K tokens | 22 sessions | 100% | Theoretical max |
| 8K tokens | 11 sessions | 100% | Comfortable |
| 16K tokens | 5 sessions | 91% | Typical summary |
| 32K tokens | 2-3 sessions | 73-100% | Large context |
| 64K tokens | 1-2 sessions | 73-100% | Very large |
| 131K tokens | 1 session | 100% | Maximum context |

*With prefix caching enabled — actual limits depend on shared prefix ratio.*

### By Pipeline Phase

| Phase | Sessions | Context Each | Total KV |
|-------|----------|-------------|----------|
| Warmup | 1 | ~4K | 5% |
| Daily Summary | 1 | ~16K | 18% |
| Summary + Briefing | 2 | ~46K total | 52% |
| Memory Sync (6 agents) | 6 | ~300 tokens each | <2% |
| **Backlog batch (10 parallel)** | 10 | ~8K each | ~60% |

## First-Request Penalty

The first request to a cold vLLM instance triggers **CUDAGraph compilation**:

- **Cold start:** 60-90 seconds (one-time per model load)
- **Warm start:** <1 second

The warmup ping job eliminates this penalty for real workloads.

## Performance Metrics

### Expected Throughput (Reference Setup)

| Metric | Value | Notes |
|--------|-------|-------|
| Prefill (PP) | ~2,500 tok/s | Processing input |
| Generation (TG) | ~45 tok/s | Single session |
| Generation (TG, 5 concurrent) | ~35 tok/s each | Per-session with concurrency |
| Total throughput (5 concurrent) | ~175 tok/s | Aggregate |

### Scaling Behavior

- **1-3 concurrent:** Near-linear throughput scaling
- **3-8 concurrent:** Slight per-session degradation (~80% efficiency)
- **8-15 concurrent:** Measurable degradation (~60-70% per-session)
- **15+:** Diminishing returns, queueing begins

## Adapting to Your Hardware

### Single GPU (e.g., RTX 4090 24GB)

```
KV Cache: ~40K tokens
Concurrent sessions: 2-4 (at 8K context)
Pipeline runtime: ~15-20 minutes
```

### Dual GPU (e.g., 2× RTX 3090 24GB)

```
KV Cache: ~80K tokens  
Concurrent sessions: 5-10 (at 8K context)
Pipeline runtime: ~12-15 minutes
```

### Cloud API (e.g., OpenAI, Anthropic)

```
No GPU constraints
Concurrent sessions: Limited by API rate limits
Pipeline runtime: ~5-8 minutes (network latency)
Cost: ~$0.10-0.50 per run
```

## Monitoring

### Key Metrics to Watch

```bash
# vLLM metrics endpoint
curl http://localhost:8000/metrics | grep -E "vllm_(cache|request|generation)"

# Key indicators:
# - gpu_cache_usage_perc: KV cache utilization
# - num_requests_running: Current concurrent requests  
# - num_requests_waiting: Queue depth (should be 0)
# - generation_tokens_total: Throughput
```

### Red Flags

| Indicator | Threshold | Action |
|-----------|-----------|--------|
| KV cache > 95% | Reduce concurrency | Lower parallel sessions |
| Queue depth > 0 | Consistent queueing | Add GPU or reduce batch |
| TG speed < 20 tok/s | Per-session slowdown | Check GPU thermals |
| OOM errors | Fatal | Reduce model size or concurrency |
