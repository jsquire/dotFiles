#!/usr/bin/env bash
# install-cachyos.sh — CachyOS Server Bootstrap
#
# Installs the local LLM stack on a CachyOS (Arch-based) machine.
#   client — Crush + uv + MCP only, connects to a remote vLLM/Ollama endpoint.
#   full   — local Ollama + NVIDIA + models + Crush + uv + MCP (localhost only, single-user).
#   server — vLLM (multi-user) + NVIDIA + HuggingFace models + Crush + uv + MCP + LAN firewall.

set -euo pipefail

MODE="full"
MODEL_PROFILE="server"
OLLAMA_HOST_ARG=""
MODEL_PATH=""
SKIP_MODELS=false
MODELS_ONLY=false
ENABLE_LAN=false
LAN_CIDR=""
IS_SERVER_MODE=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CUSTOM_MODEL_LIST_PATH="${SCRIPT_DIR}/../config/ollama-models.txt"
AI_TOOLS_DIR="${HOME}/.local/share/ai-tools"
CRUSH_HOME_DIR="${HOME}/.crush"
CRUSH_CONFIG_DIR="${HOME}/.config/crush"
DEFAULT_MODEL_ROOT="${HOME}/.ollama/models"
VLLM_PORT=8000
VLLM_DEFAULT_MODEL="btbtyler09/Qwen3-Coder-30B-A3B-Instruct-gptq-4bit"

STEP_NUMBER=0
FAILURES=()
WARNINGS=()
SELECTED_MODELS=()
MODEL_PROFILE_LABEL="server"
MODEL_SOURCE_MESSAGE=""
EFFECTIVE_MODEL_REQUIRED_GB=62

COLOR_RESET='\033[0m'
COLOR_MAGENTA='\033[1;35m'
COLOR_CYAN='\033[1;36m'
COLOR_GREEN='\033[1;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_RED='\033[1;31m'
COLOR_GRAY='\033[0;37m'

usage() {
    cat <<'EOF'
CachyOS Local LLM Stack Installer

Usage:
  ./install-cachyos.sh [options]

Options:
  --mode client|full|server    Install mode (default: full)
                               client — no Ollama, points at remote host
                               full   — local Ollama on localhost only
                               server — full + LAN firewall + client instructions
  --model-profile desktop|server
                               GPU profile: desktop (5090, 32GB) or server (4090, 24GB dedicated)
                               Default: server
  --ollama-host <url>          Remote endpoint URL (required for client mode)
                               Can be Ollama (http://host:11434) or vLLM (http://host:8000/v1)
  --model-path <path>          Custom Ollama model directory (sets OLLAMA_MODELS; full mode only)
  --lan-cidr <cidr>            Override LAN CIDR for firewall (auto-detected if omitted)
                               Examples: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16
  --skip-models                Skip model downloads
  --models-only                Only download models; skip software installation
  --help                       Show this help text

Examples:
  ./install-cachyos.sh                                                  # Full local (Ollama, localhost)
  ./install-cachyos.sh --mode server                                    # vLLM server + LAN exposure
  ./install-cachyos.sh --mode server --lan-cidr 10.0.0.0/8              # vLLM server on 10.x LAN
  ./install-cachyos.sh --mode client --ollama-host http://192.168.1.50:8000/v1
  ./install-cachyos.sh --models-only
EOF
}

step() {
    STEP_NUMBER=$((STEP_NUMBER + 1))
    echo
    printf '%b\n' "${COLOR_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}"
    printf '%b\n' "${COLOR_CYAN}  Step ${STEP_NUMBER}: $1${COLOR_RESET}"
    printf '%b\n' "${COLOR_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}"
}

info() {
    printf '%b\n' "${COLOR_GRAY}  ℹ  $1${COLOR_RESET}"
}

success() {
    printf '%b\n' "${COLOR_GREEN}  ✓  $1${COLOR_RESET}"
}

warn() {
    printf '%b\n' "${COLOR_YELLOW}  ⚠  $1${COLOR_RESET}"
}

fail() {
    printf '%b\n' "${COLOR_RED}  ✗  $1${COLOR_RESET}"
}

add_warning() {
    WARNINGS+=("$1")
    warn "$1"
}

add_failure() {
    FAILURES+=("$1")
    fail "$1"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

ensure_local_bin_on_path() {
    case ":${PATH}:" in
        *":${HOME}/.local/bin:"*) ;;
        *) export PATH="${HOME}/.local/bin:${PATH}" ;;
    esac
}

trim_line() {
    printf '%s' "$1" | xargs
}

detect_lan_cidr() {
    local ip
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')"
    if [[ -z "$ip" ]]; then
        printf '%s' "192.168.0.0/16"
        return
    fi
    case "$ip" in
        10.*)         printf '%s' "10.0.0.0/8" ;;
        172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) printf '%s' "172.16.0.0/12" ;;
        192.168.*)    printf '%s' "192.168.0.0/16" ;;
        *)            printf '%s' "${ip%.*}.0/24" ;;
    esac
}

model_description() {
    case "$1" in
        qwen2.5-coder:32b) printf '%s' 'Qwen2.5-Coder 32B — heavy coding, ~19 GB' ;;
        qwen2.5-coder:14b) printf '%s' 'Qwen2.5-Coder 14B — light coding, ~9 GB' ;;
        deepseek-r1:32b) printf '%s' 'DeepSeek R1 32B — code review/reasoning, ~19 GB' ;;
        mistral-small3.2:24b) printf '%s' 'Mistral Small 3.2 — docs/creative/office, ~15 GB' ;;
        gemma4:31b) printf '%s' 'Gemma 4 31B — heavy coding (256k ctx), ~20 GB' ;;
        gemma4:26b) printf '%s' 'Gemma 4 26B MoE — general (256k ctx), ~17 GB' ;;
        qwen3:14b) printf '%s' 'Qwen3 14B — image gen profile, VRAM-friendly (131k ctx), ~9 GB' ;;
        qwen2.5-coder:14b) printf '%s' 'Qwen2.5-Coder 14B — code review profile (32k ctx), ~9 GB' ;;
        gemma3:27b) printf '%s' 'Gemma 3 27B — tech docs (128k ctx), ~16 GB' ;;
        llama3.3:70b-instruct-q2_K) printf '%s' 'Llama 3.3 70B Q2 — creative writing, ~26 GB' ;;
        qwen3-coder:30b) printf '%s' 'Qwen3-Coder 30B MoE — heavy coding/office docs (256k ctx), ~19 GB' ;;
        qwen3:32b) printf '%s' 'Qwen3 32B — creative writing (128k ctx), ~20 GB' ;;
        x/z-image-turbo) printf '%s' 'Z-Image Turbo 6B — image generation, ~12 GB' ;;
        # HuggingFace model IDs (vLLM server mode)
        Qwen/Qwen2.5-Coder-32B-Instruct-GPTQ-Int4) printf '%s' 'Qwen2.5-Coder 32B GPTQ — heavy coding, ~18 GB' ;;
        btbtyler09/Qwen3-Coder-30B-A3B-Instruct-gptq-4bit) printf '%s' 'Qwen3-Coder 30B MoE GPTQ — heavy coding (agentic), ~19 GB' ;;
        Qwen/Qwen2.5-Coder-14B-Instruct-GPTQ-Int4) printf '%s' 'Qwen2.5-Coder 14B GPTQ — light coding, ~8 GB' ;;
        deepseek-ai/DeepSeek-R1-Distill-Qwen-32B-GPTQ-Int4) printf '%s' 'DeepSeek R1 Distill 32B GPTQ — code review, ~18 GB' ;;
        mistralai/Mistral-Small-3.2-24B-Instruct-2503-GPTQ-Int4) printf '%s' 'Mistral Small 3.2 GPTQ — docs/creative/office, ~13 GB' ;;
        *) printf '%s' 'Custom model' ;;
    esac
}

require_sudo_access() {
    if [[ ${EUID} -eq 0 ]]; then
        success "Running as root."
        return 0
    fi

    if ! command_exists sudo; then
        add_failure "This step requires root or sudo, but sudo is not installed."
        return 1
    fi

    if sudo -n true >/dev/null 2>&1; then
        success "sudo is available."
        return 0
    fi

    info "Requesting sudo access..."
    if sudo -v; then
        success "sudo authentication succeeded."
        return 0
    fi

    add_failure "Could not obtain sudo access."
    return 1
}

run_privileged() {
    if [[ ${EUID} -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

wait_for_ollama() {
    local timeout_seconds="${1:-45}"
    local elapsed=0

    info "Waiting for Ollama API to become ready..."
    while (( elapsed < timeout_seconds )); do
        if curl -fsS http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
            success "Ollama API is ready."
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    warn "Ollama API did not respond within ${timeout_seconds} seconds."
    return 1
}

load_effective_model_config() {
    SELECTED_MODELS=()

    case "$MODEL_PROFILE" in
        desktop)
            EFFECTIVE_MODEL_REQUIRED_GB=84
            SELECTED_MODELS=("gemma4:31b" "qwen3:14b" "deepseek-r1:32b" "gemma3:27b" "qwen3:32b" "qwen3-coder:30b")
            ;;
        server)
            EFFECTIVE_MODEL_REQUIRED_GB=74
            if [[ "$IS_SERVER_MODE" == true ]]; then
                # vLLM uses HuggingFace model IDs (GPTQ quantized)
                SELECTED_MODELS=(
                    "btbtyler09/Qwen3-Coder-30B-A3B-Instruct-gptq-4bit"
                    "Qwen/Qwen2.5-Coder-14B-Instruct-GPTQ-Int4"
                    "deepseek-ai/DeepSeek-R1-Distill-Qwen-32B-GPTQ-Int4"
                    "mistralai/Mistral-Small-3.2-24B-Instruct-2503-GPTQ-Int4"
                )
                EFFECTIVE_MODEL_REQUIRED_GB=58
            else
                # Ollama (full mode, single-user) uses Ollama tags
                SELECTED_MODELS=("gemma4:26b" "qwen3:14b" "qwen2.5-coder:14b")
            fi
            ;;
    esac

    MODEL_PROFILE_LABEL="$MODEL_PROFILE"
    MODEL_SOURCE_MESSAGE="Using ${MODEL_PROFILE^} profile models."

    if [[ -f "$CUSTOM_MODEL_LIST_PATH" ]]; then
        local custom_models=()
        local raw trimmed
        local -A seen=()

        while IFS= read -r raw || [[ -n "$raw" ]]; do
            raw="${raw%%#*}"
            trimmed="$(trim_line "$raw")"
            [[ -z "$trimmed" ]] && continue

            if [[ -z "${seen[$trimmed]+x}" ]]; then
                seen[$trimmed]=1
                custom_models+=("$trimmed")
            fi
        done < "$CUSTOM_MODEL_LIST_PATH"

        if (( ${#custom_models[@]} > 0 )); then
            SELECTED_MODELS=("${custom_models[@]}")
            MODEL_PROFILE_LABEL="custom"
            MODEL_SOURCE_MESSAGE="Using custom model list from ../config/ollama-models.txt."
        else
            add_warning "Custom model list exists at $CUSTOM_MODEL_LIST_PATH but is empty after comments are removed. Falling back to ${MODEL_PROFILE^}."
        fi
    fi
}

install_uv() {
    ensure_local_bin_on_path

    if command_exists uv; then
        info "uv is already installed: $(uv --version 2>/dev/null || true)"
        return 0
    fi

    if [[ -x "${HOME}/.local/bin/uv" ]]; then
        success "uv already exists at ${HOME}/.local/bin/uv"
        return 0
    fi

    if curl -LsSf https://astral.sh/uv/install.sh | sh; then
        ensure_local_bin_on_path
        if [[ -x "${HOME}/.local/bin/uv" ]]; then
            success "uv installed to ${HOME}/.local/bin/uv"
            return 0
        fi
        if command_exists uv; then
            success "uv installed successfully."
            return 0
        fi
    fi

    add_failure "uv installation failed."
    return 1
}

install_crush_from_github() {
    local arch asset_url release_json download_dir archive_path arch_pattern binary_path

    case "$(uname -m)" in
        x86_64|amd64) arch_pattern='(amd64|x86_64)' ;;
        aarch64|arm64) arch_pattern='(arm64|aarch64)' ;;
        *) arch_pattern="$(uname -m)" ;;
    esac

    release_json="$(curl -fsSL https://api.github.com/repos/charmbracelet/crush/releases/latest)" || return 1
    asset_url="$({ printf '%s' "$release_json" | grep -Eo 'https://[^"[:space:]]+' | grep '/download/' | grep -Ei 'linux' | grep -Ei "$arch_pattern" | grep -E '\.(tar\.gz|tgz)$' | head -n 1; } || true)"
    [[ -z "$asset_url" ]] && return 1

    download_dir="${AI_TOOLS_DIR}/.downloads/crush"
    archive_path="${download_dir}/crush.tar.gz"
    rm -rf "$download_dir"
    mkdir -p "$download_dir" "${HOME}/.local/bin"

    curl -fsSL "$asset_url" -o "$archive_path"
    tar -xzf "$archive_path" -C "$download_dir"
    binary_path="$({ find "$download_dir" -type f -name crush | head -n 1; } || true)"
    [[ -z "$binary_path" ]] && return 1

    install -m 0755 "$binary_path" "${HOME}/.local/bin/crush"
    rm -rf "$download_dir"
    return 0
}

install_crush() {
    ensure_local_bin_on_path

    if command_exists crush; then
        info "Crush is already installed: $(crush --version 2>/dev/null || true)"
        return 0
    fi

    if command_exists pacman && pacman -Si crush >/dev/null 2>&1; then
        if [[ ${EUID} -eq 0 ]] || command_exists sudo; then
            info "Installing Crush from pacman repositories."
            if run_privileged pacman -S --needed --noconfirm crush; then
                ensure_local_bin_on_path
                success "Crush installed via pacman."
                return 0
            fi
            warn "pacman install for Crush failed — falling back to user-local install."
        fi
    fi

    info "Trying Charm installer for Crush."
    if curl -fsSL https://crush.charm.sh/install.sh | sh; then
        ensure_local_bin_on_path
        if command_exists crush || [[ -x "${HOME}/.local/bin/crush" ]]; then
            success "Crush installed successfully."
            return 0
        fi
    fi

    warn "Charm installer for Crush was unavailable. Trying GitHub release fallback."
    if install_crush_from_github; then
        ensure_local_bin_on_path
        success "Crush installed from GitHub release to ${HOME}/.local/bin/crush"
        return 0
    fi

    add_failure "Crush installation failed."
    return 1
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)
                [[ $# -lt 2 ]] && { fail "--mode requires a value."; usage; exit 1; }
                MODE="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
                shift 2
                ;;
            --model-profile)
                [[ $# -lt 2 ]] && { fail "--model-profile requires a value."; usage; exit 1; }
                MODEL_PROFILE="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
                shift 2
                ;;
            --ollama-host)
                [[ $# -lt 2 ]] && { fail "--ollama-host requires a value."; usage; exit 1; }
                OLLAMA_HOST_ARG="$2"
                shift 2
                ;;
            --model-path)
                [[ $# -lt 2 ]] && { fail "--model-path requires a value."; usage; exit 1; }
                MODEL_PATH="$2"
                shift 2
                ;;
            --lan-cidr)
                [[ $# -lt 2 ]] && { fail "--lan-cidr requires a CIDR value (e.g. 10.0.0.0/8)."; usage; exit 1; }
                LAN_CIDR="$2"
                shift 2
                ;;
            --skip-models)
                SKIP_MODELS=true
                shift
                ;;
            --models-only)
                MODELS_ONLY=true
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                fail "Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done
}

parse_args "$@"

printf '%b\n' ""
printf '%b\n' "${COLOR_MAGENTA}╔══════════════════════════════════════════════════════════════╗${COLOR_RESET}"
printf '%b\n' "${COLOR_MAGENTA}║   CachyOS Server — Local LLM Stack Installer                 ║${COLOR_RESET}"
printf '%b\n' "${COLOR_MAGENTA}║   Ollama · Crush · uv · MCP Servers                          ║${COLOR_RESET}"
printf '%b\n' "${COLOR_MAGENTA}╚══════════════════════════════════════════════════════════════╝${COLOR_RESET}"
printf '%b\n' ""

case "$MODE" in
    full|client|server) ;;
    *) fail "--mode must be client, full, or server."; exit 1 ;;
esac

case "$MODEL_PROFILE" in
    desktop|server) ;;
    *) fail "--model-profile must be 'desktop' or 'server'."; exit 1 ;;
esac

if [[ "$MODE" == "client" && -z "$OLLAMA_HOST_ARG" ]]; then
    fail "--ollama-host is required when --mode client is used."
    exit 1
fi

if [[ "$MODE" == "client" && "$MODELS_ONLY" == true ]]; then
    add_warning "--models-only is ignored in client mode. Continuing with client installation."
    MODELS_ONLY=false
fi

if [[ "$MODE" == "client" && "$SKIP_MODELS" == true ]]; then
    add_warning "--skip-models is irrelevant in client mode because no local models are pulled."
fi

if [[ "$MODE" == "client" && "$ENABLE_LAN" == true ]]; then
    add_warning "--enable-lan is ignored in client mode because Ollama is not installed locally."
    ENABLE_LAN=false
fi

if [[ "$MODE" == "client" && -n "$MODEL_PATH" ]]; then
    add_warning "--model-path is ignored in client mode because no local Ollama storage is configured."
fi

if [[ "$MODE" == "full" && "$MODELS_ONLY" == true && "$SKIP_MODELS" == true ]]; then
    fail "--models-only and --skip-models cannot be used together."
    exit 1
fi

IS_FULL_MODE=false
IS_CLIENT_MODE=false
IS_SERVER_MODE=false
SHOULD_INSTALL_SOFTWARE=true
SHOULD_PULL_MODELS=false
OLLAMA_BIND_HOST="127.0.0.1"

if [[ "$MODE" == "server" ]]; then
    IS_FULL_MODE=true
    IS_SERVER_MODE=true
    ENABLE_LAN=true
    OLLAMA_BIND_HOST="0.0.0.0"
    SHOULD_INSTALL_SOFTWARE=true
    SHOULD_PULL_MODELS=true
    [[ "$MODELS_ONLY" == true ]] && SHOULD_INSTALL_SOFTWARE=false
    [[ "$SKIP_MODELS" == true ]] && SHOULD_PULL_MODELS=false
    # Resolve LAN CIDR: use --lan-cidr if provided, otherwise auto-detect
    if [[ -z "$LAN_CIDR" ]]; then
        LAN_CIDR="$(detect_lan_cidr)"
        info "Auto-detected LAN CIDR: $LAN_CIDR"
    else
        info "Using user-specified LAN CIDR: $LAN_CIDR"
    fi
    load_effective_model_config
elif [[ "$MODE" == "full" ]]; then
    IS_FULL_MODE=true
    SHOULD_INSTALL_SOFTWARE=true
    SHOULD_PULL_MODELS=true
    [[ "$MODELS_ONLY" == true ]] && SHOULD_INSTALL_SOFTWARE=false
    [[ "$SKIP_MODELS" == true ]] && SHOULD_PULL_MODELS=false
    load_effective_model_config
else
    IS_CLIENT_MODE=true
    SHOULD_PULL_MODELS=false
    SHOULD_INSTALL_SOFTWARE=true
    MODEL_PROFILE_LABEL="n/a (client mode)"
fi

info "Mode: $MODE"
info "Model profile: $MODEL_PROFILE_LABEL"
if [[ "$IS_FULL_MODE" == true ]]; then
    info "$MODEL_SOURCE_MESSAGE"
fi

if [[ "$IS_FULL_MODE" == true && "$SHOULD_PULL_MODELS" == true ]]; then
    local_model_root="${MODEL_PATH:-$DEFAULT_MODEL_ROOT}"
    if command_exists df; then
        free_gb="$({ df -BG "$local_model_root" 2>/dev/null || df -BG "$(dirname "$local_model_root")" 2>/dev/null || true; } | awk 'NR==2 {gsub(/G/,"",$4); print $4}')"
        if [[ -n "${free_gb:-}" ]]; then
            if (( free_gb < EFFECTIVE_MODEL_REQUIRED_GB )); then
                add_warning "Only ${free_gb} GB free where models will live. Pulls need about ${EFFECTIVE_MODEL_REQUIRED_GB} GB."
            else
                info "${free_gb} GB free in target filesystem — enough for roughly ${EFFECTIVE_MODEL_REQUIRED_GB} GB of models."
            fi
        fi
    fi
fi

if [[ "$IS_FULL_MODE" == true && "$SHOULD_INSTALL_SOFTWARE" == true ]]; then
    step "Pre-flight checks"

    if ! require_sudo_access; then
        exit 1
    fi

    if command_exists pacman; then
        success "pacman is available."
    else
        add_failure "pacman is required on CachyOS/Arch systems."
    fi

    if command_exists lspci; then
        if lspci | grep -qi nvidia; then
            success "NVIDIA GPU detected."
        else
            add_failure "No NVIDIA GPU was detected by lspci."
        fi
    else
        add_failure "lspci is not installed. Install pciutils, then re-run this script."
    fi

    if ! command_exists curl; then
        add_failure "curl is required for installer downloads."
    else
        success "curl is available."
    fi

    if (( ${#FAILURES[@]} > 0 )); then
        exit 1
    fi
elif [[ "$IS_FULL_MODE" == true ]]; then
    step "Pre-flight checks"
    info "Models-only mode selected — skipping driver and package pre-flight checks."
    if ! command_exists curl; then
        add_failure "curl is required to probe the Ollama API."
        exit 1
    fi
fi

if [[ "$SHOULD_INSTALL_SOFTWARE" == true ]]; then
    if [[ "$IS_FULL_MODE" == true ]]; then
        step "Install NVIDIA drivers and CUDA"
        info "Installing nvidia-dkms, nvidia-utils, and cuda from CachyOS repositories."
        if run_privileged pacman -S --needed --noconfirm nvidia-dkms nvidia-utils cuda; then
            success "NVIDIA packages are installed."
        else
            add_failure "Failed to install NVIDIA drivers and CUDA packages."
        fi

        if [[ "$IS_SERVER_MODE" == true ]]; then
            # ── vLLM Server Mode ──────────────────────────────────────────────
            step "Install vLLM (multi-user inference server)"
            if command_exists vllm; then
                info "vLLM is already installed: $(pip show vllm 2>/dev/null | grep Version || true)"
            else
                info "Installing vLLM via pip. This requires Python 3.10+ and CUDA 12.1+."
                ensure_local_bin_on_path
                UV_BIN="$(command -v uv || echo "${HOME}/.local/bin/uv")"
                if [[ ! -x "$UV_BIN" ]]; then
                    info "Installing uv first (needed for Python management)..."
                    curl -LsSf https://astral.sh/uv/install.sh | sh
                    ensure_local_bin_on_path
                    UV_BIN="${HOME}/.local/bin/uv"
                fi
                # Create a dedicated venv for vLLM
                VLLM_VENV="${HOME}/.local/share/vllm-env"
                if [[ ! -d "$VLLM_VENV" ]]; then
                    "$UV_BIN" venv "$VLLM_VENV" --python 3.12
                fi
                # Detect CUDA version and choose appropriate torch backend
                local cuda_version torch_backend_flag=""
                if command_exists nvcc; then
                    cuda_version="$(nvcc --version 2>/dev/null | grep -oP 'release \K[0-9]+\.[0-9]+')"
                    if [[ -n "$cuda_version" ]]; then
                        local cuda_major="${cuda_version%%.*}"
                        if (( cuda_major >= 13 )); then
                            torch_backend_flag="--torch-backend=cu130"
                            info "Detected CUDA ${cuda_version} — using --torch-backend=cu130"
                        elif [[ "$cuda_version" == 12.* ]]; then
                            torch_backend_flag="--torch-backend=auto"
                            info "Detected CUDA ${cuda_version} — using --torch-backend=auto"
                        fi
                    fi
                fi
                if [[ -z "$torch_backend_flag" ]]; then
                    torch_backend_flag="--torch-backend=auto"
                    info "Could not detect CUDA version — using --torch-backend=auto"
                fi

                if "$UV_BIN" pip install --python "$VLLM_VENV/bin/python" vllm $torch_backend_flag; then
                    success "vLLM installed in $VLLM_VENV"
                else
                    add_failure "vLLM installation failed. Check CUDA version (needs 12.1+)."
                fi
            fi

            step "Install huggingface-cli (model downloader)"
            VLLM_VENV="${HOME}/.local/share/vllm-env"
            if [[ -x "$VLLM_VENV/bin/huggingface-cli" ]]; then
                info "huggingface-cli already available in vLLM venv."
            else
                "$UV_BIN" pip install --python "$VLLM_VENV/bin/python" huggingface_hub[cli] || add_warning "huggingface-cli install failed."
            fi

            step "Configure vLLM systemd service"
            VLLM_VENV="${HOME}/.local/share/vllm-env"
            local_vllm_service="/etc/systemd/system/vllm.service"
            local_vllm_override_dir="/etc/systemd/system/vllm.service.d"
            local_vllm_override="${local_vllm_override_dir}/override.conf"

            # Create the base service unit
            local vllm_service_content="[Unit]
Description=vLLM Inference Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$(whoami)
ExecStart=${VLLM_VENV}/bin/python -m vllm.entrypoints.openai.api_server \\
    --model \${VLLM_MODEL} \\
    --host \${VLLM_HOST} \\
    --port \${VLLM_PORT} \\
    --max-model-len \${VLLM_MAX_MODEL_LEN} \\
    --gpu-memory-utilization \${VLLM_GPU_MEMORY_UTILIZATION} \\
    --quantization gptq
Environment=\"VLLM_MODEL=${VLLM_DEFAULT_MODEL}\"
Environment=\"VLLM_HOST=0.0.0.0\"
Environment=\"VLLM_PORT=${VLLM_PORT}\"
Environment=\"VLLM_MAX_MODEL_LEN=32768\"
Environment=\"VLLM_GPU_MEMORY_UTILIZATION=0.50\"
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
"
            if printf '%s' "$vllm_service_content" | run_privileged tee "$local_vllm_service" >/dev/null; then
                run_privileged systemctl daemon-reload
                success "Created vLLM service at $local_vllm_service"
                info "Default model: ${VLLM_DEFAULT_MODEL}"
                info "Listening on: 0.0.0.0:${VLLM_PORT}"
                info "To change model: sudo systemctl edit vllm → set VLLM_MODEL"
            else
                add_failure "Failed to create vLLM systemd service."
            fi

            step "Configure firewall (vLLM port ${VLLM_PORT})"
            if command_exists ufw; then
                ufw_status="$(run_privileged ufw status 2>/dev/null || true)"
                if grep -Fq "$LAN_CIDR" <<<"$ufw_status" && grep -Fq "${VLLM_PORT}" <<<"$ufw_status"; then
                    info "ufw already has a LAN rule for port ${VLLM_PORT}."
                else
                    if run_privileged ufw allow from "$LAN_CIDR" to any port "${VLLM_PORT}" proto tcp comment 'vLLM LAN' >/dev/null; then
                        success "Added ufw allow rule for $LAN_CIDR -> ${VLLM_PORT}/tcp"
                    else
                        add_warning "Could not add ufw allow rule for port ${VLLM_PORT}."
                    fi
                fi
                # Deny non-LAN access
                if ! grep -Fq "${VLLM_PORT}/tcp" <<<"$ufw_status" || ! grep -Fq 'DENY' <<<"$ufw_status"; then
                    if run_privileged ufw deny "${VLLM_PORT}/tcp" comment 'Block non-LAN vLLM' >/dev/null; then
                        success "Added ufw deny rule for non-LAN access to ${VLLM_PORT}/tcp"
                    else
                        add_warning "Could not add ufw deny rule for port ${VLLM_PORT}."
                    fi
                fi
            else
                info "ufw is not installed — skipping firewall configuration."
            fi

            step "Install image generation service (SGLang-Diffusion)"
            VLLM_VENV="${HOME}/.local/share/vllm-env"
            IMAGEGEN_PORT=8001

            # Install SGLang with diffusion support into the vLLM venv (shares torch/CUDA)
            info "Installing SGLang with diffusion support into vLLM venv..."
            "$UV_BIN" pip install --python "$VLLM_VENV/bin/python" \
                "sglang[diffusion]" --prerelease=allow 2>/dev/null \
                && success "SGLang-Diffusion installed." \
                || add_warning "SGLang-Diffusion install failed."

            step "Configure image generation systemd service"
            local imagegen_service="/etc/systemd/system/imagegen.service"
            local imagegen_service_content="[Unit]
Description=Image Generation API (SGLang-Diffusion + FLUX.1-schnell)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$(whoami)
ExecStart=${VLLM_VENV}/bin/python -m sglang.launch_server \\
    --model-path \${IMAGEGEN_MODEL} \\
    --host 0.0.0.0 \\
    --port ${IMAGEGEN_PORT}
Environment=\"IMAGEGEN_MODEL=black-forest-labs/FLUX.1-schnell\"
Restart=on-failure
RestartSec=15

[Install]
WantedBy=multi-user.target
"
            if printf '%s' "$imagegen_service_content" | run_privileged tee "$imagegen_service" >/dev/null; then
                run_privileged systemctl daemon-reload
                success "Created imagegen.service (SGLang-Diffusion)"
                info "Default model: FLUX.1-schnell on port ${IMAGEGEN_PORT}"
                info "Start with: sudo systemctl enable --now imagegen"
            else
                add_failure "Failed to create imagegen systemd service."
            fi

            step "Configure firewall (image gen port ${IMAGEGEN_PORT})"
            if command_exists ufw; then
                ufw_status="$(run_privileged ufw status 2>/dev/null || true)"
                if grep -Fq "$LAN_CIDR" <<<"$ufw_status" && grep -Fq "${IMAGEGEN_PORT}" <<<"$ufw_status"; then
                    info "ufw already has a LAN rule for port ${IMAGEGEN_PORT}."
                else
                    if run_privileged ufw allow from "$LAN_CIDR" to any port "${IMAGEGEN_PORT}" proto tcp comment 'ImageGen LAN' >/dev/null; then
                        success "Added ufw allow rule for $LAN_CIDR -> ${IMAGEGEN_PORT}/tcp"
                    else
                        add_warning "Could not add ufw allow rule for port ${IMAGEGEN_PORT}."
                    fi
                fi
            else
                info "ufw is not installed — skipping image gen firewall."
            fi
        else
            # ── Ollama (full mode, single-user, localhost only) ────────────────
            step "Install Ollama"
            info "Using the official Ollama installer script."
            if command_exists ollama; then
                info "Ollama is already installed: $(ollama --version 2>/dev/null || true)"
            elif curl -fsSL https://ollama.com/install.sh | sh; then
                success "Ollama installed."
            else
                add_failure "Ollama installation failed."
            fi

            step "Configure Ollama systemd service"
            if (( ${#FAILURES[@]} == 0 )); then
                local_override_dir="/etc/systemd/system/ollama.service.d"
                local_override_path="${local_override_dir}/override.conf"
                local_override_content="[Service]
Environment=\"OLLAMA_HOST=${OLLAMA_BIND_HOST}\"
Environment=\"OLLAMA_KEEP_ALIVE=5m\"
Environment=\"OLLAMA_FLASH_ATTENTION=1\"
Environment=\"OLLAMA_KV_CACHE_TYPE=q8_0\"\n"

                if [[ -n "$MODEL_PATH" ]]; then
                    if mkdir -p "$MODEL_PATH" 2>/dev/null || run_privileged mkdir -p "$MODEL_PATH"; then
                        success "Ensured model path exists: $MODEL_PATH"
                    else
                        add_warning "Could not create $MODEL_PATH automatically. Ensure it exists and is writable by Ollama."
                    fi
                    local_override_content+="Environment=\"OLLAMA_MODELS=${MODEL_PATH}\"\n"
                fi

                if run_privileged install -d -m 0755 "$local_override_dir" && printf '%b' "$local_override_content" | run_privileged tee "$local_override_path" >/dev/null; then
                    run_privileged systemctl daemon-reload
                    run_privileged systemctl enable --now ollama
                    success "Configured Ollama override at $local_override_path"
                    info "OLLAMA_HOST=${OLLAMA_BIND_HOST}"
                    info "OLLAMA_KEEP_ALIVE=5m"
                    info "OLLAMA_FLASH_ATTENTION=1"
                    info "OLLAMA_KV_CACHE_TYPE=q8_0"
                    [[ -n "$MODEL_PATH" ]] && info "OLLAMA_MODELS=${MODEL_PATH}"
                else
                    add_failure "Failed to create the Ollama systemd override."
                fi
            fi

            step "Configure firewall"
            if command_exists ufw; then
                info "Ollama is bound to localhost only — no LAN rule needed."
            else
                info "ufw is not installed — skipping firewall configuration."
            fi
        fi
    else
        step "Validate remote Ollama endpoint"
        info "Client mode will use remote Ollama at $OLLAMA_HOST_ARG"
    fi

    step "Install uv"
    info "uv manages Python versions and isolated environments without touching system Python."
    install_uv || true

    step "Install Python via uv"
    ensure_local_bin_on_path
    if command_exists uv || [[ -x "${HOME}/.local/bin/uv" ]]; then
        UV_BIN="$(command -v uv || true)"
        [[ -z "$UV_BIN" ]] && UV_BIN="${HOME}/.local/bin/uv"
        if "$UV_BIN" python install --default; then
            success "Python installed via uv."
        else
            add_failure "uv could not install Python."
        fi
    else
        add_failure "uv is not available, so Python could not be installed."
    fi

    step "Install Crush"
    info "Crush is the CLI agent. Prefer user-local install; use pacman when available."
    install_crush || true

    step "Install MCP tools"
    info "Installing MCP servers as uv tools (docx-mcp-server, office-powerpoint-mcp-server)."
    if command_exists uv; then
        if uv tool install docx-mcp-server --python 3.12 >/dev/null 2>&1; then
            success "docx-mcp-server installed (Word OOXML editing)"
        else
            add_warning "Failed to install docx-mcp-server. Run 'uv tool install docx-mcp-server --python 3.12' manually."
        fi
        if uv tool install office-powerpoint-mcp-server --python 3.12 >/dev/null 2>&1; then
            success "office-powerpoint-mcp-server installed (cross-platform PPTX editing)"
        else
            add_warning "Failed to install office-powerpoint-mcp-server. Run 'uv tool install office-powerpoint-mcp-server --python 3.12' manually."
        fi
    else
        add_warning "uv not found — cannot install MCP tools. Install uv first."
    fi
    mkdir -p "$CRUSH_HOME_DIR" "$CRUSH_CONFIG_DIR"
    success "Prepared Crush config directories: ${CRUSH_HOME_DIR} and ${CRUSH_CONFIG_DIR}"

    # ── Deploy Crush configuration ───────────────────────────────────────
    step "Deploy Crush configuration"
    local crush_config_source="${SCRIPT_DIR}/../config/crush.json"
    local crush_config_dest="${CRUSH_CONFIG_DIR}/crush.json"

    if [[ -f "$crush_config_source" ]]; then
        if [[ -f "$crush_config_dest" ]]; then
            info "Crush config already exists at $crush_config_dest — skipping (won't overwrite)."
        else
            # Expand template placeholders for Linux
            local linux_app_data="${HOME}/.local/share"
            # Determine vLLM server IP for the placeholder
            local vllm_ip="127.0.0.1"
            if [[ "$IS_SERVER_MODE" == true ]]; then
                vllm_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' || echo '127.0.0.1')"
            elif [[ "$IS_CLIENT_MODE" == true && -n "$OLLAMA_HOST_ARG" ]]; then
                # Extract host from the provided URL
                vllm_ip="$(echo "$OLLAMA_HOST_ARG" | sed -E 's|https?://||;s|:[0-9]+.*||')"
            fi
            # Determine imagegen host — same as vLLM for server/client modes, localhost for standalone
            local imagegen_host="127.0.0.1"
            [[ "$vllm_ip" != "127.0.0.1" ]] && imagegen_host="$vllm_ip"
            sed -e "s|__LOCALAPPDATA__|${linux_app_data}|g" \
                -e "s|__VENV_BIN__|bin|g" \
                -e "s|__EXE__||g" \
                -e "s|__EXE_SUFFIX__||g" \
                -e "s|__CONFIG_DIR__|${CRUSH_CONFIG_DIR}|g" \
                -e "s|__SQUIRE_SERVER_IP__|${vllm_ip}|g" \
                -e "s|__IMAGEGEN_HOST__|${imagegen_host}|g" \
                "$crush_config_source" > "$crush_config_dest"

            # On Linux: disable COM-based pptx-mcp, enable cross-platform pptx-mcp-xplat
            sed -i '/"pptx-mcp":/{ /pptx-mcp-xplat/!s/"disabled": *false/"disabled": true/; /pptx-mcp-xplat/!s/\(\"pptx-mcp\".*\)/\1/ }' "$crush_config_dest" 2>/dev/null || true
            python3 -c "
import json, sys
with open('$crush_config_dest', 'r') as f:
    cfg = json.load(f)
mcps = cfg.get('mcp', cfg.get('mcpServers', {}))
if 'pptx-mcp' in mcps:
    mcps['pptx-mcp']['disabled'] = True
if 'pptx-mcp-xplat' in mcps:
    mcps['pptx-mcp-xplat'].pop('disabled', None)
with open('$crush_config_dest', 'w') as f:
    json.dump(cfg, f, indent=2)
" 2>/dev/null && info "Swapped PPTX MCP: pptx-mcp disabled, pptx-mcp-xplat enabled (cross-platform)" || true

            success "Deployed crush.json to $crush_config_dest"
            if [[ "$IS_SERVER_MODE" == true ]]; then
                info "vLLM server provider configured at http://${vllm_ip}:${VLLM_PORT}/v1"
            fi
            info "Local Ollama is the default provider. vLLM server, Mistral, Google AI Studio, Groq, and OpenRouter available as fallbacks."
            info "Set MISTRAL_API_KEY, GEMINI_API_KEY, GROQ_API_KEY, and/or OPENROUTER_API_KEY to enable cloud providers."
            info "MCP servers (Word, PowerPoint) are enabled. Run setup-mcp-venvs.sh to install them."
        fi
    else
        warn "Config template not found at $crush_config_source — skipping Crush config."
    fi

    # ── Install ComfyUI (image generation) ────────────────────────────────
    if [[ "$MODE" != "client" ]]; then
        step "Install ComfyUI (image generation)"
        if command_exists comfyui || [[ -d "${HOME}/.local/share/ComfyUI" ]]; then
            info "ComfyUI appears to be installed already."
        else
            info "ComfyUI provides local image generation (FLUX, SD3.5, Z-Image)."
            info "On Linux (headless server), ComfyUI is best installed manually."
            info "  Desktop: https://www.comfy.org/download"
            info "  Manual:  git clone https://github.com/comfyanonymous/ComfyUI && pip install -r requirements.txt"
            info "Skipping automatic install — see above for instructions."
        fi
    fi

    # ── Deploy copilot-local launcher ─────────────────────────────────────
    step "Deploy copilot-local launcher"
    local launcher_source="${SCRIPT_DIR}/../scripts/copilot-local.sh"
    local launcher_dest="${HOME}/.local/bin/copilot-local"

    if [[ -f "$launcher_source" ]]; then
        mkdir -p "${HOME}/.local/bin"
        install -m 0755 "$launcher_source" "$launcher_dest"
        success "Deployed copilot-local to $launcher_dest"
        info "Usage: copilot-local (from any directory)"
    else
        warn "Launcher script not found at $launcher_source — skipping."
    fi

    # ── Deploy crush-task launcher ────────────────────────────────────────
    step "Deploy crush-task launcher"
    local crush_task_source="${SCRIPT_DIR}/../scripts/crush-task.sh"
    local crush_task_dest="${HOME}/.local/bin/crush-task"

    if [[ -f "$crush_task_source" ]]; then
        mkdir -p "${HOME}/.local/bin"
        install -m 0755 "$crush_task_source" "$crush_task_dest"
        success "Deployed crush-task to $crush_task_dest"
        info "Usage: crush-task (from any directory)"
    else
        warn "crush-task script not found at $crush_task_source — skipping."
    fi

    # ── Deploy Crush skills and MCP servers ─────────────────────────────
    step "Deploy Crush skills and MCP servers"

    # Deploy custom MCP servers (if any)
    local mcp_source_dir="${SCRIPT_DIR}/../config/mcp"
    local mcp_dest_dir="${CRUSH_CONFIG_DIR}/mcp"
    if [[ -d "$mcp_source_dir" ]]; then
        mkdir -p "$mcp_dest_dir"
        cp -r "$mcp_source_dir"/* "$mcp_dest_dir"/ 2>/dev/null || true
        success "Deployed MCP servers to $mcp_dest_dir"
    fi

    # Deploy local skills from dotFiles
    local skills_source_dir="${SCRIPT_DIR}/../config/skills"
    local skills_dest_dir="${CRUSH_CONFIG_DIR}/skills"
    if [[ -d "$skills_source_dir" ]]; then
        mkdir -p "$skills_dest_dir"
        cp -r "$skills_source_dir"/* "$skills_dest_dir"/
        success "Deployed local skills (git-safety) to $skills_dest_dir"
    fi

    # Download latest doc-coauthoring skill from anthropics/skills
    local doc_coauth_dir="${skills_dest_dir}/doc-coauthoring"
    mkdir -p "$doc_coauth_dir"
    local doc_coauth_url="https://raw.githubusercontent.com/anthropics/skills/main/skills/doc-coauthoring/SKILL.md"
    if curl -fsSL "$doc_coauth_url" -o "${doc_coauth_dir}/SKILL.md" 2>/dev/null; then
        success "Downloaded latest doc-coauthoring skill from anthropics/skills"
    else
        warn "Could not download doc-coauthoring skill from GitHub"
    fi

    # ── Deploy Copilot CLI MCP configuration ──────────────────────────────
    step "Deploy Copilot CLI MCP configuration"
    local copilot_mcp_source="${SCRIPT_DIR}/../config/copilot-mcp-config.json"
    local copilot_dir="${HOME}/.copilot"
    local copilot_mcp_dest="${copilot_dir}/mcp-config.json"

    if [[ -f "$copilot_mcp_source" ]]; then
        mkdir -p "$copilot_dir"
        if [[ -f "$copilot_mcp_dest" ]]; then
            info "Copilot MCP config already exists at $copilot_mcp_dest — skipping (won't overwrite)."
        else
            local linux_app_data="${HOME}/.local/share"
            local imagegen_host="127.0.0.1"
            [[ "${vllm_ip:-}" != "127.0.0.1" && -n "${vllm_ip:-}" ]] && imagegen_host="$vllm_ip"
            sed -e "s|__LOCALAPPDATA__|${linux_app_data}|g" \
                -e "s|__VENV_BIN__|bin|g" \
                -e "s|__EXE__||g" \
                -e "s|__EXE_SUFFIX__||g" \
                -e "s|__CONFIG_DIR__|${CRUSH_CONFIG_DIR}|g" \
                -e "s|__IMAGEGEN_HOST__|${imagegen_host}|g" \
                "$copilot_mcp_source" > "$copilot_mcp_dest"
            success "Deployed mcp-config.json to $copilot_mcp_dest"
        fi
    else
        warn "Copilot MCP config template not found — skipping."
    fi

    # ── Set up imagegen MCP venv ──────────────────────────────────────────
    step "Set up imagegen MCP server"
    local mcp_imagegen_dir="${HOME}/.local/share/ai-tools/mcp-imagegen"
    local mcp_imagegen_script="${SCRIPT_DIR}/../mcp/imagegen-mcp-server.py"

    if [[ -f "$mcp_imagegen_script" ]]; then
        mkdir -p "$mcp_imagegen_dir"
        cp "$mcp_imagegen_script" "$mcp_imagegen_dir/imagegen-mcp-server.py"

        if [[ -d "$mcp_imagegen_dir/.venv" ]]; then
            info "imagegen MCP venv already exists — skipping."
        else
            local UV_BIN
            UV_BIN="$(command -v uv || echo "${HOME}/.local/bin/uv")"
            if [[ -x "$UV_BIN" ]]; then
                "$UV_BIN" venv "$mcp_imagegen_dir/.venv" --quiet 2>/dev/null
                "$UV_BIN" pip install --python "$mcp_imagegen_dir/.venv/bin/python" \
                    fastmcp httpx --quiet 2>/dev/null \
                    && success "imagegen MCP venv created with fastmcp + httpx" \
                    || warn "Failed to install imagegen MCP dependencies."
            else
                warn "uv not found — skipping imagegen MCP venv setup."
            fi
        fi
    else
        warn "imagegen-mcp-server.py not found — skipping."
    fi
fi

if [[ "$SHOULD_PULL_MODELS" == true ]]; then
    if [[ "$IS_SERVER_MODE" == true ]]; then
        # ── vLLM: Download models from HuggingFace ──────────────────────
        step "Download HuggingFace models for vLLM"
        info "$MODEL_SOURCE_MESSAGE"
        info "This will download about ${EFFECTIVE_MODEL_REQUIRED_GB} GB. Downloads are resumable."

        VLLM_VENV="${HOME}/.local/share/vllm-env"
        HF_CLI="${VLLM_VENV}/bin/huggingface-cli"

        if [[ ! -x "$HF_CLI" ]]; then
            add_failure "huggingface-cli not found at $HF_CLI — install vLLM first."
        else
            for model_id in "${SELECTED_MODELS[@]}"; do
                echo
                printf '%b\n' "${COLOR_GRAY}  Downloading ${model_id}${COLOR_RESET}"
                info "$(model_description "$model_id")"
                if "$HF_CLI" download "$model_id" --quiet; then
                    success "$model_id ready."
                else
                    add_failure "Model download failed: $model_id"
                fi
            done

            # Also download FLUX.1-schnell for image generation
            echo
            printf '%b\n' "${COLOR_GRAY}  Downloading black-forest-labs/FLUX.1-schnell (image generation)${COLOR_RESET}"
            info "FLUX.1-schnell — fast image generation (4 steps), ~12 GB"
            if "$HF_CLI" download "black-forest-labs/FLUX.1-schnell" --quiet; then
                success "FLUX.1-schnell ready."
            else
                add_warning "FLUX.1-schnell download failed — image gen will not work until downloaded."
            fi
        fi
    else
        # ── Ollama: Pull GGUF models ────────────────────────────────────
        step "Pull Ollama models"
        info "$MODEL_SOURCE_MESSAGE"
        info "This will download about ${EFFECTIVE_MODEL_REQUIRED_GB} GB. Each pull is resumable."

        if ! command_exists ollama && [[ ! -x /usr/local/bin/ollama ]]; then
            add_failure "Ollama is not installed, so models cannot be pulled."
        else
            api_ready=false
            if wait_for_ollama 45; then
                api_ready=true
            else
                warn "Trying to start Ollama before pulling models."
                if command_exists systemctl; then
                    run_privileged systemctl restart ollama >/dev/null 2>&1 || true
                fi
                if wait_for_ollama 30; then
                    api_ready=true
                else
                    add_failure "Could not connect to Ollama. Re-run with --models-only after the service is healthy."
                fi
            fi

            if [[ "$api_ready" == true ]]; then
                OLLAMA_BIN="$(command -v ollama || true)"
                [[ -z "$OLLAMA_BIN" && -x /usr/local/bin/ollama ]] && OLLAMA_BIN="/usr/local/bin/ollama"

                if [[ -n "$OLLAMA_BIN" ]]; then
                    for tag in "${SELECTED_MODELS[@]}"; do
                        echo
                        printf '%b\n' "${COLOR_GRAY}  Pulling ${tag}${COLOR_RESET}"
                        info "$(model_description "$tag")"
                        if "$OLLAMA_BIN" pull "$tag"; then
                            success "$tag ready."
                        else
                            add_failure "Model pull failed: $tag"
                        fi
                    done

                    # Set num_ctx on models (Ollama defaults to 2048)
                    printf '%b\n' "${COLOR_GRAY}  Setting context window (num_ctx) on models...${COLOR_RESET}"
                    local -A num_ctx_settings=(
                        ["gemma4:26b"]=65536
                        ["qwen3:14b"]=16384
                        ["qwen2.5-coder:14b"]=65536
                    )
                    for tag in "${!num_ctx_settings[@]}"; do
                        local ctx="${num_ctx_settings[$tag]}"
                        local modelfile_tmp
                        modelfile_tmp="$(mktemp)"
                        printf 'FROM %s\nPARAMETER num_ctx %s\n' "$tag" "$ctx" > "$modelfile_tmp"
                        if "$OLLAMA_BIN" create "$tag" -f "$modelfile_tmp" >/dev/null 2>&1; then
                            info "  $tag → num_ctx $ctx"
                        fi
                        rm -f "$modelfile_tmp"
                    done

                    # Create named alias models used by launcher scripts
                    printf '%b\n' "${COLOR_GRAY}  Creating launcher model aliases...${COLOR_RESET}"
                    local -A alias_from=(
                        ["gemma4-65k"]="gemma4:26b"
                        ["qwen25coder-65k"]="qwen2.5-coder:14b"
                    )
                    local -A alias_ctx=(
                        ["gemma4-65k"]=65536
                        ["qwen25coder-65k"]=65536
                    )
                    for alias_name in "${!alias_from[@]}"; do
                        local from="${alias_from[$alias_name]}"
                        local ctx="${alias_ctx[$alias_name]}"
                        local modelfile_tmp
                        modelfile_tmp="$(mktemp)"
                        printf 'FROM %s\nPARAMETER num_ctx %s\n' "$from" "$ctx" > "$modelfile_tmp"
                        if "$OLLAMA_BIN" create "$alias_name" -f "$modelfile_tmp" >/dev/null 2>&1; then
                            info "  $alias_name → $from @ num_ctx $ctx"
                        fi
                        rm -f "$modelfile_tmp"
                    done
                else
                    add_failure "Ollama binary was not found after the API became ready."
                fi
            fi
        fi
    fi
elif [[ "$IS_FULL_MODE" == true ]]; then
    echo
    info "Model pulls skipped. Re-run later with: ./install-cachyos.sh --models-only"
fi

echo
if (( ${#FAILURES[@]} > 0 )) || (( ${#WARNINGS[@]} > 0 )); then
    printf '%b\n' "${COLOR_YELLOW}╔══════════════════════════════════════════════════════════════╗${COLOR_RESET}"
    printf '%b\n' "${COLOR_YELLOW}║   Installation Completed with Warnings                       ║${COLOR_RESET}"
    printf '%b\n' "${COLOR_YELLOW}╚══════════════════════════════════════════════════════════════╝${COLOR_RESET}"
else
    printf '%b\n' "${COLOR_GREEN}╔══════════════════════════════════════════════════════════════╗${COLOR_RESET}"
    printf '%b\n' "${COLOR_GREEN}║   Installation Complete                                      ║${COLOR_RESET}"
    printf '%b\n' "${COLOR_GREEN}╚══════════════════════════════════════════════════════════════╝${COLOR_RESET}"
fi

echo
printf '%b\n' "Mode: ${MODE}"
printf '%b\n' "Model profile: ${MODEL_PROFILE_LABEL}"

if [[ "$SHOULD_INSTALL_SOFTWARE" == true ]]; then
    echo
    printf '%b\n' 'Installed / prepared:'
    [[ "$IS_FULL_MODE" == true ]] && printf '%b\n' '  • NVIDIA drivers + CUDA (system)'
    [[ "$IS_FULL_MODE" == true ]] && printf '%b\n' '  • Ollama (system service)'
    printf '%b\n' '  • uv + Python (user-local / uv-managed)'
    printf '%b\n' '  • Crush (CLI agent)'
    printf '%b\n' "  • ${AI_TOOLS_DIR}/mcp-*"
    printf '%b\n' "  • ${CRUSH_HOME_DIR} and ${CRUSH_CONFIG_DIR}"
    [[ -n "$MODEL_PATH" && "$IS_FULL_MODE" == true ]] && printf '%b\n' "  • Custom model path: ${MODEL_PATH}"
fi

if [[ "$IS_CLIENT_MODE" == true ]]; then
    echo
    printf '%b\n' 'Next steps:'
    printf '%b\n' "  1. Launch Crush and point it at ${OLLAMA_HOST_ARG}"
    printf '%b\n' '  2. Verify remote endpoint: curl http://server:8000/v1/models (vLLM) or :11434/api/tags (Ollama)'
    printf '%b\n' '  3. Create MCP venvs under ~/.local/share/ai-tools as needed'
elif [[ "$IS_SERVER_MODE" == true ]]; then
    # Detect LAN IP for client connection instructions
    local_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' || hostname -I 2>/dev/null | awk '{print $1}' || echo '<this-server-ip>')"
    echo
    printf '%b\n' "${COLOR_CYAN}── Client Access (vLLM) ───────────────────────────────────────${COLOR_RESET}"
    printf '%b\n' ""
    printf '%b\n' "  vLLM API:    http://${local_ip}:${VLLM_PORT}/v1"
    printf '%b\n' "  Image Gen:   http://${local_ip}:8001/v1/images/generations"
    printf '%b\n' "  Firewall:    ufw allow from ${LAN_CIDR} to port ${VLLM_PORT},8001/tcp"
    printf '%b\n' ""
    printf '%b\n' "  Verify from any LAN machine:"
    printf '%b\n' "    curl http://${local_ip}:${VLLM_PORT}/v1/models"
    printf '%b\n' "    curl http://${local_ip}:8001/health"
    printf '%b\n' ""
    printf '%b\n' "  Windows client install:"
    printf '%b\n' "    .\\install-windows.ps1 -Mode Client -OllamaHost http://${local_ip}:${VLLM_PORT}/v1"
    printf '%b\n' ""
    printf '%b\n' "  CachyOS client install:"
    printf '%b\n' "    ./install-cachyos.sh --mode client --ollama-host http://${local_ip}:${VLLM_PORT}/v1"
    printf '%b\n' ""
    printf '%b\n' "  Switch model:"
    printf '%b\n' "    sudo systemctl edit vllm  →  set VLLM_MODEL=<model-id>"
    printf '%b\n' "    sudo systemctl restart vllm"
    printf '%b\n' ""
    printf '%b\n' "${COLOR_CYAN}──────────────────────────────────────────────────────────────${COLOR_RESET}"
    echo
    printf '%b\n' 'Next steps:'
    printf '%b\n' "  1. Start services: sudo systemctl enable --now vllm imagegen"
    printf '%b\n' "  2. Verify vLLM: curl http://127.0.0.1:${VLLM_PORT}/v1/models"
    printf '%b\n' "  3. Verify image gen: curl http://127.0.0.1:8001/health"
    printf '%b\n' "  4. Verify from LAN: curl http://${local_ip}:${VLLM_PORT}/v1/models"
    printf '%b\n' '  5. Launch Crush and select vllm-server provider'
else
    echo
    printf '%b\n' 'Next steps:'
    printf '%b\n' '  1. Check service status: sudo systemctl status ollama'
    printf '%b\n' '  2. Verify API: curl http://127.0.0.1:11434/api/tags'
    printf '%b\n' '  3. Launch Crush and select your preferred model'
fi

if (( ${#WARNINGS[@]} > 0 )); then
    echo
    printf '%b\n' 'Warnings:'
    for warning in "${WARNINGS[@]}"; do
        printf '%b\n' "  • ${warning}"
    done
fi

if (( ${#FAILURES[@]} > 0 )); then
    echo
    printf '%b\n' 'Failures:'
    for failure in "${FAILURES[@]}"; do
        printf '%b\n' "  • ${failure}"
    done
    exit 1
fi
