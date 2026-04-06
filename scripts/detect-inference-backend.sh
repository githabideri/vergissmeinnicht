#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# 🧠 Backend Detection Script
#
# Detects available inference backend and returns:
#   - "vllm" if vLLM is available (preferred)
#   - "llama-cpp" if llama.cpp is available
#   - "none" if neither is available
#
# Usage: ./detect-inference-backend.sh
# Output: "vllm" | "llama-cpp" | "none"
#
# Config:
#   VLLM_URL (optional): vLLM server URL
#   LLAMA_CPP_URL (optional): llama.cpp server URL
#   INFERENCE_URL (fallback): generic fallback URL
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load config if available
if [ -f "$SCRIPT_DIR/config.env" ]; then
    source "$SCRIPT_DIR/config.env" 2>/dev/null || true
fi

# Default URLs (config.env overrides)
VLLM_URL="${VLLM_URL:-http://192.168.0.24:8000}"
LLAMA_CPP_URL="${LLAMA_CPP_URL:-http://192.168.0.27:8081}"
INFERENCE_URL="${INFERENCE_URL:-$LLAMA_CPP_URL}"

detect_backend() {
    local backend=""
    
    # Check vLLM first (preferred)
    if curl -s --connect-timeout 2 "$VLLM_URL/v1/models" >/dev/null 2>&1; then
        echo "vllm"
        return 0
    fi
    
    # Check llama.cpp (fallback)
    if curl -s --connect-timeout 2 "$LLAMA_CPP_URL/v1/models" >/dev/null 2>&1; then
        echo "llama-cpp"
        return 0
    fi
    
    echo "none"
    return 1
}

# Main
detect_backend
