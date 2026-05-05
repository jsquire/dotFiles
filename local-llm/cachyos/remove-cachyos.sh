#!/usr/bin/env bash
# remove-cachyos.sh — CachyOS Server Removal
#
# Removes the local LLM stack from a CachyOS server or client node.

set -euo pipefail

MODE="full"
KEEP_MODELS=false
KEEP_CONFIG=false
FORCE=false

AI_TOOLS_DIR="${HOME}/.local/share/ai-tools"
UV_SHARE_DIR="${HOME}/.local/share/uv"
UV_BIN_PATH="${HOME}/.local/bin/uv"
UVX_BIN_PATH="${HOME}/.local/bin/uvx"
CRUSH_BIN_PATH="${HOME}/.local/bin/crush"
CRUSH_HOME_DIR="${HOME}/.crush"
CRUSH_CONFIG_DIR="${HOME}/.config/crush"
OLLAMA_DIR="${HOME}/.ollama"

STEP_NUMBER=0
FAILURES=()
WARNINGS=()

COLOR_RESET='\033[0m'
COLOR_RED='\033[1;31m'
COLOR_CYAN='\033[1;36m'
COLOR_GREEN='\033[1;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_GRAY='\033[0;37m'

usage() {
    cat <<'EOF'
CachyOS Local LLM Stack Removal

Usage:
  ./remove-cachyos.sh [options]

Options:
  --mode full|server|client   Removal mode (default: full; server is an alias for full)
  --keep-models        Keep ~/.ollama/models
  --keep-config        Keep ~/.crush and ~/.config/crush
  --force              Skip confirmation prompts
  --help               Show this help text

Examples:
  ./remove-cachyos.sh
  ./remove-cachyos.sh --keep-models
  ./remove-cachyos.sh --mode client --keep-config
  ./remove-cachyos.sh --force
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

remove_user_path() {
    local path="$1"
    local description="$2"

    if [[ -e "$path" || -L "$path" ]]; then
        rm -rf "$path"
        success "Removed ${description}: ${path}"
    else
        info "${description} not found at ${path} — skipping."
    fi
}

remove_system_path() {
    local path="$1"
    local description="$2"

    if run_privileged test -e "$path" || run_privileged test -L "$path"; then
        run_privileged rm -rf "$path"
        success "Removed ${description}: ${path}"
    else
        info "${description} not found at ${path} — skipping."
    fi
}

confirm_action() {
    local prompt="$1"

    if [[ "$FORCE" == true ]]; then
        return 0
    fi

    read -r -p "  ${prompt} (y/N) " response
    [[ "$response" == "y" || "$response" == "Y" ]]
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)
                [[ $# -lt 2 ]] && { fail "--mode requires a value."; usage; exit 1; }
                MODE="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
                shift 2
                ;;
            --keep-models)
                KEEP_MODELS=true
                shift
                ;;
            --keep-config)
                KEEP_CONFIG=true
                shift
                ;;
            --force)
                FORCE=true
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

case "$MODE" in
    full|server|client) ;;
    *) fail "--mode must be full, server, or client."; exit 1 ;;
esac

# server is functionally identical to full for removal (includes firewall cleanup)
[[ "$MODE" == "server" ]] && MODE="full"

printf '%b\n' ""
printf '%b\n' "${COLOR_RED}╔══════════════════════════════════════════════════════════════╗${COLOR_RESET}"
printf '%b\n' "${COLOR_RED}║   CachyOS Server — Local LLM Stack Removal                  ║${COLOR_RESET}"
printf '%b\n' "${COLOR_RED}╚══════════════════════════════════════════════════════════════╝${COLOR_RESET}"
printf '%b\n' ""

printf '%b\n' "  Mode: ${MODE}"
printf '%b\n' '  This script will remove:'
if [[ "$MODE" == "full" ]]; then
    printf '%b\n' '    • Ollama service and binary'
    if [[ "$KEEP_MODELS" == false ]]; then
        printf '%b\n' "    • ${OLLAMA_DIR}"
    else
        printf '%b\n' "    • ${OLLAMA_DIR} (except models/)"
    fi
fi
printf '%b\n' "    • ${CRUSH_BIN_PATH} (or pacman package if installed)"
printf '%b\n' "    • ${HOME}/.local/bin/uv and uvx"
printf '%b\n' "    • ${UV_SHARE_DIR}"
printf '%b\n' "    • ${AI_TOOLS_DIR}"
if [[ "$KEEP_CONFIG" == false ]]; then
    printf '%b\n' "    • ${CRUSH_HOME_DIR} and ${CRUSH_CONFIG_DIR}"
fi
printf '%b\n' ""

if [[ "$MODE" == "client" && "$KEEP_MODELS" == true ]]; then
    add_warning "--keep-models is irrelevant in client mode because Ollama data is not removed."
fi
if [[ "$KEEP_CONFIG" == true ]]; then
    add_warning "Crush configuration will be kept."
fi

if ! confirm_action "Proceed with ${MODE} removal?"; then
    warn 'Cancelled.'
    exit 0
fi

if [[ "$MODE" == "full" ]]; then
    step "Acquire sudo access"
    require_sudo_access || exit 1

    step "Stop and disable Ollama service"
    if command_exists systemctl; then
        run_privileged systemctl stop ollama >/dev/null 2>&1 || true
        run_privileged systemctl disable ollama >/dev/null 2>&1 || true
        success 'Ollama service stop/disable commands issued.'
    else
        info 'systemctl is not available — skipping service stop/disable.'
    fi

    step "Remove Ollama files"
    remove_system_path '/usr/local/bin/ollama' 'Ollama binary'
    remove_system_path '/etc/systemd/system/ollama.service.d/override.conf' 'Ollama override'
    remove_system_path '/etc/systemd/system/ollama.service.d' 'Ollama override directory'
    remove_system_path '/etc/systemd/system/ollama.service' 'Ollama service file'
    remove_system_path '/usr/lib/systemd/system/ollama.service' 'Ollama packaged service file'
    if command_exists systemctl; then
        run_privileged systemctl daemon-reload >/dev/null 2>&1 || true
        run_privileged systemctl reset-failed >/dev/null 2>&1 || true
        success 'Reloaded systemd state.'
    fi

    step "Remove Ollama data"
    if [[ -d "$OLLAMA_DIR" ]]; then
        if [[ "$KEEP_MODELS" == true ]]; then
            find "$OLLAMA_DIR" -mindepth 1 -maxdepth 1 ! -name models -exec rm -rf {} +
            success "Kept ${OLLAMA_DIR}/models and removed other Ollama data."
        else
            rm -rf "$OLLAMA_DIR"
            success "Removed ${OLLAMA_DIR}"
        fi
    else
        info "${OLLAMA_DIR} not found — skipping."
    fi

    step "Clean up firewall rules"
    if command_exists ufw; then
        # Remove Ollama LAN allow rule if present
        ufw_num="$(run_privileged ufw status numbered 2>/dev/null | grep -i 'ollama\|11434' | head -n1 | sed -n 's/^\[\s*\([0-9]*\)\].*/\1/p' || true)"
        if [[ -n "$ufw_num" ]]; then
            run_privileged ufw --force delete "$ufw_num" >/dev/null 2>&1 || true
            # Check for a second rule (deny rule)
            ufw_num2="$(run_privileged ufw status numbered 2>/dev/null | grep -i 'ollama\|11434' | head -n1 | sed -n 's/^\[\s*\([0-9]*\)\].*/\1/p' || true)"
            [[ -n "$ufw_num2" ]] && run_privileged ufw --force delete "$ufw_num2" >/dev/null 2>&1 || true
            success "Removed ufw rules for Ollama port 11434."
        else
            info "No ufw rules found for Ollama."
        fi
    else
        info "ufw is not installed — no firewall rules to clean up."
    fi
else
    step "Skip Ollama removal"
    info 'Client mode selected — Ollama service, binary, and models are preserved.'
fi

step "Remove Crush"
if command_exists pacman && pacman -Q crush >/dev/null 2>&1; then
    if [[ "$MODE" == "full" ]]; then
        if run_privileged pacman -Rns --noconfirm crush; then
            success 'Removed Crush pacman package.'
        else
            add_warning 'pacman could not remove Crush cleanly. Remove it manually if needed.'
        fi
    else
        add_warning 'Crush is installed via pacman; re-run with sudo or remove it manually: sudo pacman -Rns crush'
    fi
else
    remove_user_path "$CRUSH_BIN_PATH" 'Crush binary'
fi
remove_user_path "${HOME}/bin/crush" 'alternate Crush binary'
if [[ "$MODE" == "full" ]]; then
    remove_system_path "/usr/local/bin/crush" 'system-wide Crush binary link'
fi

step "Remove uv binaries"
remove_user_path "$UV_BIN_PATH" 'uv binary'
remove_user_path "$UVX_BIN_PATH" 'uvx binary'

step "Remove uv data"
remove_user_path "$UV_SHARE_DIR" 'uv shared data'

step "Remove MCP environments"
remove_user_path "$AI_TOOLS_DIR" 'AI tools directory'

if [[ "$KEEP_CONFIG" == false ]]; then
    step "Remove Crush configuration"
    remove_user_path "$CRUSH_HOME_DIR" 'Crush home directory'
    remove_user_path "$CRUSH_CONFIG_DIR" 'Crush config directory'
else
    step "Keep Crush configuration"
    info 'Keeping ~/.crush and ~/.config/crush as requested.'
fi

echo
if (( ${#FAILURES[@]} > 0 )) || (( ${#WARNINGS[@]} > 0 )); then
    printf '%b\n' "${COLOR_YELLOW}╔══════════════════════════════════════════════════════════════╗${COLOR_RESET}"
    printf '%b\n' "${COLOR_YELLOW}║   Removal Completed with Warnings                           ║${COLOR_RESET}"
    printf '%b\n' "${COLOR_YELLOW}╚══════════════════════════════════════════════════════════════╝${COLOR_RESET}"
else
    printf '%b\n' "${COLOR_GREEN}╔══════════════════════════════════════════════════════════════╗${COLOR_RESET}"
    printf '%b\n' "${COLOR_GREEN}║   Removal Complete                                          ║${COLOR_RESET}"
    printf '%b\n' "${COLOR_GREEN}╚══════════════════════════════════════════════════════════════╝${COLOR_RESET}"
fi

echo
printf '%b\n' "Mode: ${MODE}"
printf '%b\n' 'Removed:'
if [[ "$MODE" == "full" ]]; then
    printf '%b\n' '  • Ollama service and binaries'
    if [[ "$KEEP_MODELS" == false ]]; then
        printf '%b\n' '  • Ollama models and config'
    else
        printf '%b\n' '  • Ollama config (models kept)'
    fi
fi
printf '%b\n' '  • Crush'
printf '%b\n' '  • uv / uvx'
printf '%b\n' '  • uv shared data'
printf '%b\n' '  • MCP environments'
if [[ "$KEEP_CONFIG" == false ]]; then
    printf '%b\n' '  • Crush configuration'
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
