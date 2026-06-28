#!/usr/bin/env bash
# offload-serve.sh — swap the local Ollama server for one with MoE expert CPU-offload
# enabled (and back). See offload-serve.ps1 for the full rationale.
#
# Mechanism (verified on Windows, Ollama 0.30.7): Ollama's bundled runner is upstream
# llama-server, which honors LLAMA_ARG_CPU_MOE inherited from the serve environment,
# pushing MoE expert weights to system RAM. The env var is GLOBAL to a serve process, so
# it must NOT be set on the everyday server — this script runs a dedicated offload serve
# and restores the normal one afterwards. The serve lifecycle below is Linux-specific
# (systemd `ollama.service` if present, else a plain `ollama serve`).
#
# Usage (also sourceable):  offload-serve.sh start [n_cpu_moe] | offload-serve.sh stop
#   n_cpu_moe: 0 (default) = all experts to CPU; >0 = first N layers only (partial offload).
set -uo pipefail

OFFLOAD_PID_FILE="${TMPDIR:-/tmp}/ollama-offload.pid"
API_BASE="http://127.0.0.1:11434"

_offload_stop_ollama() {
    # Best-effort: stop a systemd-managed Ollama if present, plus any stray serve procs AND
    # the llama-server runner child (killing only the parent leaves it orphaned, holding VRAM).
    if command -v systemctl >/dev/null 2>&1; then
        sudo systemctl stop ollama 2>/dev/null || systemctl --user stop ollama 2>/dev/null || true
    fi
    pkill -f "ollama serve" 2>/dev/null || true
    pkill -f "llama-server" 2>/dev/null || true
    sleep 2
}

_offload_wait_api() {
    local secs="${1:-30}" i
    for ((i = 0; i < secs; i++)); do
        if curl -fsS --max-time 2 "$API_BASE/api/version" >/dev/null 2>&1; then return 0; fi
        sleep 1
    done
    return 1
}

offload_start() {
    local ncpumoe="${1:-0}"
    local req_free_gb="${2:-15}"
    # RAM-headroom guard: experts spill to system RAM; abort if not enough free (set OFFLOAD_FORCE=1 to skip).
    if [[ "${OFFLOAD_FORCE:-0}" != "1" ]]; then
        local free_gb
        free_gb=$(awk '/MemAvailable/ {printf "%d", $2/1048576}' /proc/meminfo 2>/dev/null || echo 999)
        if [[ "$free_gb" -lt "$req_free_gb" ]]; then
            echo "  [offload] ABORT: only ${free_gb} GB RAM free; need >= ${req_free_gb} GB. Close apps or set OFFLOAD_FORCE=1." >&2
            return 1
        fi
        echo "  [offload] RAM check OK: ${free_gb} GB free (>= ${req_free_gb} GB)."
    fi
    echo "  [offload] Stopping managed Ollama server..."
    _offload_stop_ollama

    export OLLAMA_HOST="127.0.0.1"
    export OLLAMA_FLASH_ATTENTION="1"
    export OLLAMA_KV_CACHE_TYPE="q8_0"
    export OLLAMA_KEEP_ALIVE="5m"
    # Required for offload: avoid CUDA pinning the large CPU-resident expert tensors.
    export GGML_CUDA_NO_PINNED="1"

    if [[ "$ncpumoe" -gt 0 ]]; then
        export LLAMA_ARG_N_CPU_MOE="$ncpumoe"
        unset LLAMA_ARG_CPU_MOE 2>/dev/null || true
        echo "  [offload] Partial offload: first $ncpumoe layers' experts -> CPU RAM"
    else
        export LLAMA_ARG_CPU_MOE="1"
        unset LLAMA_ARG_N_CPU_MOE 2>/dev/null || true
        echo "  [offload] Full offload: all experts -> CPU RAM"
    fi

    nohup ollama serve >/dev/null 2>&1 &
    echo $! >"$OFFLOAD_PID_FILE"

    if _offload_wait_api 30; then
        echo "  [offload] Offload server ready (LLAMA_ARG_CPU_MOE active)."
    else
        echo "  [offload] WARNING: offload server did not become ready in time."
    fi
}

offload_stop() {
    echo "  [offload] Stopping offload server, restoring managed Ollama..."
    if [[ -f "$OFFLOAD_PID_FILE" ]]; then
        kill "$(cat "$OFFLOAD_PID_FILE")" 2>/dev/null || true
        rm -f "$OFFLOAD_PID_FILE"
    fi
    pkill -f "ollama serve" 2>/dev/null || true
    sleep 1
    if command -v systemctl >/dev/null 2>&1 &&
        { sudo systemctl start ollama 2>/dev/null || systemctl --user start ollama 2>/dev/null; }; then
        echo "  [offload] Managed Ollama service restarted."
    else
        nohup ollama serve >/dev/null 2>&1 &
        echo "  [offload] Plain ollama serve restarted."
    fi
}

# Allow running directly (not just sourcing).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        start) offload_start "${2:-0}" ;;
        stop) offload_stop ;;
        *) echo "usage: $0 start|stop [n_cpu_moe]" >&2; exit 1 ;;
    esac
fi
