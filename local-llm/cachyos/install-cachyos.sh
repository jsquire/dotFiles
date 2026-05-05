#!/usr/bin/env bash
# install-cachyos.sh — CachyOS Server Bootstrap
#
# Installs the local LLM stack on a CachyOS (Arch-based) machine.
#   client — Crush + uv + MCP only, connects to a remote Ollama endpoint.
#   full   — local Ollama + NVIDIA + models + Crush + uv + MCP (localhost only).
#   server — full + exposes Ollama on the LAN via firewall and prints client access info.

set -euo pipefail

MODE="full"
MODEL_PROFILE="standard"
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

STEP_NUMBER=0
FAILURES=()
WARNINGS=()
SELECTED_MODELS=()
MODEL_PROFILE_LABEL="standard"
MODEL_SOURCE_MESSAGE=""
EFFECTIVE_MODEL_REQUIRED_GB=38

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
  --model-profile standard|high|ultra
                               Model profile for full/server mode (default: standard)
  --ollama-host <url>          Remote Ollama URL (required for client mode)
  --model-path <path>          Custom Ollama model directory (sets OLLAMA_MODELS)
  --lan-cidr <cidr>            Override LAN CIDR for firewall (auto-detected if omitted)
                               Examples: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16
  --skip-models                Skip model pulls
  --models-only                Only pull models; skip software installation
  --help                       Show this help text

Examples:
  ./install-cachyos.sh                                                  # Full local (localhost)
  ./install-cachyos.sh --mode server                                    # Full + LAN exposure
  ./install-cachyos.sh --mode server --lan-cidr 10.0.0.0/8              # Server on 10.x LAN
  ./install-cachyos.sh --mode server --model-profile high               # Server with Q5 models
  ./install-cachyos.sh --mode client --ollama-host http://192.168.1.50:11434
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
        qwen3:30b) printf '%s' 'Qwen 3 30B (Q4_K_M) — primary coder, ~18 GB' ;;
        qwen3:30b-q5_K_M) printf '%s' 'Qwen 3 30B (Q5_K_M) — primary coder, ~21 GB' ;;
        qwen3:30b-q6_K) printf '%s' 'Qwen 3 30B (Q6_K) — primary coder, ~24 GB' ;;
        qwen3:8b) printf '%s' 'Qwen 3 8B — fast tasks, ~5 GB' ;;
        deepseek-r1:14b) printf '%s' 'DeepSeek R1 14B — hard reasoning, ~9 GB' ;;
        llama3.1:8b) printf '%s' 'Llama 3.1 8B — general/sysadmin, ~5 GB' ;;
        *) printf '%s' 'Custom model from config/ollama-models.txt' ;;
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
        standard)
            EFFECTIVE_MODEL_REQUIRED_GB=38
            SELECTED_MODELS=("qwen3:30b" "qwen3:8b" "deepseek-r1:14b" "llama3.1:8b")
            ;;
        high)
            EFFECTIVE_MODEL_REQUIRED_GB=41
            SELECTED_MODELS=("qwen3:30b-q5_K_M" "qwen3:8b" "deepseek-r1:14b" "llama3.1:8b")
            ;;
        ultra)
            EFFECTIVE_MODEL_REQUIRED_GB=44
            SELECTED_MODELS=("qwen3:30b-q6_K" "qwen3:8b" "deepseek-r1:14b" "llama3.1:8b")
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
    standard|high|ultra) ;;
    *) fail "--model-profile must be standard, high, or ultra."; exit 1 ;;
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
Environment=\"OLLAMA_KEEP_ALIVE=5m\"\n"

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
                [[ -n "$MODEL_PATH" ]] && info "OLLAMA_MODELS=${MODEL_PATH}"
            else
                add_failure "Failed to create the Ollama systemd override."
            fi
        fi

        step "Configure firewall"
        if command_exists ufw; then
            if [[ "$ENABLE_LAN" == true ]]; then
                ufw_status="$(run_privileged ufw status 2>/dev/null || true)"
                if grep -Fq "$LAN_CIDR" <<<"$ufw_status" && grep -Fq '11434' <<<"$ufw_status"; then
                    info "ufw already has a LAN rule for port 11434."
                else
                    if run_privileged ufw allow from "$LAN_CIDR" to any port 11434 proto tcp comment 'Ollama LAN' >/dev/null; then
                        success "Added ufw allow rule for $LAN_CIDR -> 11434/tcp"
                    else
                        add_warning "Could not add ufw allow rule for port 11434."
                    fi
                fi

                ufw_status="$(run_privileged ufw status 2>/dev/null || true)"
                if grep -Fq '11434/tcp' <<<"$ufw_status" && grep -Fq 'DENY' <<<"$ufw_status"; then
                    info "ufw already has a deny rule for port 11434."
                else
                    if run_privileged ufw deny 11434/tcp comment 'Block non-LAN Ollama' >/dev/null; then
                        success "Added ufw deny rule for non-LAN access to 11434/tcp"
                    else
                        add_warning "Could not add ufw deny rule for port 11434. Ensure the service is not exposed beyond your LAN."
                    fi
                fi
            else
                info "ufw is installed, but Ollama is bound to localhost only — no LAN rule needed."
            fi
        else
            info "ufw is not installed — skipping firewall configuration."
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

    step "Create MCP directories"
    mkdir -p "${AI_TOOLS_DIR}/mcp-office" "${AI_TOOLS_DIR}/mcp-word" "${AI_TOOLS_DIR}/mcp-pptx" "$CRUSH_HOME_DIR" "$CRUSH_CONFIG_DIR"
    success "Created MCP directories under ${AI_TOOLS_DIR}"
    success "Prepared Crush config directories: ${CRUSH_HOME_DIR} and ${CRUSH_CONFIG_DIR}"

    # ── Deploy Crush configuration ───────────────────────────────────────
    step "Deploy Crush configuration"
    local crush_config_source="${SCRIPT_DIR}/../config/crush.json"
    local crush_config_dest="${CRUSH_CONFIG_DIR}/crush.json"

    if [[ -f "$crush_config_source" ]]; then
        if [[ -f "$crush_config_dest" ]]; then
            info "Crush config already exists at $crush_config_dest — skipping (won't overwrite)."
        else
            cp "$crush_config_source" "$crush_config_dest"
            success "Deployed crush.json to $crush_config_dest"
            info "Local Ollama is the default provider. Mistral, Google AI Studio, Groq, and OpenRouter available as fallbacks."
            info "Set MISTRAL_API_KEY, GEMINI_API_KEY, GROQ_API_KEY, and/or OPENROUTER_API_KEY to enable cloud providers."
        fi
    else
        warn "Config template not found at $crush_config_source — skipping Crush config."
    fi
fi

if [[ "$SHOULD_PULL_MODELS" == true ]]; then
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
            else
                add_failure "Ollama binary was not found after the API became ready."
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
    printf '%b\n' '  2. Verify remote Ollama: curl http://server:11434/api/tags'
    printf '%b\n' '  3. Create MCP venvs under ~/.local/share/ai-tools as needed'
elif [[ "$IS_SERVER_MODE" == true ]]; then
    # Detect LAN IP for client connection instructions
    local_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' || hostname -I 2>/dev/null | awk '{print $1}' || echo '<this-server-ip>')"
    echo
    printf '%b\n' "${COLOR_CYAN}── Client Access ──────────────────────────────────────────────${COLOR_RESET}"
    printf '%b\n' ""
    printf '%b\n' "  Ollama API:  http://${local_ip}:11434"
    printf '%b\n' "  Firewall:    ufw allow from ${LAN_CIDR} to port 11434/tcp"
    printf '%b\n' ""
    printf '%b\n' "  Verify from any LAN machine:"
    printf '%b\n' "    curl http://${local_ip}:11434/api/tags"
    printf '%b\n' ""
    printf '%b\n' "  Windows client install:"
    printf '%b\n' "    .\\install-windows.ps1 -Mode Client -OllamaHost http://${local_ip}:11434"
    printf '%b\n' ""
    printf '%b\n' "  CachyOS client install:"
    printf '%b\n' "    ./install-cachyos.sh --mode client --ollama-host http://${local_ip}:11434"
    printf '%b\n' ""
    printf '%b\n' "${COLOR_CYAN}──────────────────────────────────────────────────────────────${COLOR_RESET}"
    echo
    printf '%b\n' 'Next steps:'
    printf '%b\n' '  1. Check service status: sudo systemctl status ollama'
    printf '%b\n' "  2. Verify API locally: curl http://127.0.0.1:11434/api/tags"
    printf '%b\n' "  3. Verify from LAN: curl http://${local_ip}:11434/api/tags"
    printf '%b\n' '  4. Launch Crush and select your preferred model'
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
