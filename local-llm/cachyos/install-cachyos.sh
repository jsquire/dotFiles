#!/usr/bin/env bash
# install-cachyos.sh — CachyOS Server Bootstrap
#
# Installs the local LLM stack on a CachyOS (Arch-based) machine.
#   client — Crush + uv + MCP only, connects to a remote vLLM/Ollama endpoint (no engine here).
#   local  — Ollama engine: local Ollama + NVIDIA + models + Crush + uv + MCP (localhost, single-user).
#   server — vLLM engine: vLLM (multi-user) + NVIDIA + HuggingFace models + Crush + uv + MCP + LAN firewall.

set -euo pipefail

MODE="full"
INSTALL=""
PROVIDERS=""
DEFAULT_PROVIDER=""
SHOULD_INSTALL_CLIENT_TOOLS=true
NO_CLIENT_TOOLS=false
# Ollama model roster GPU tier (local/Ollama installs only): 4090 (24GB) | 5090 (32GB).
# Default 4090 — the CachyOS box is the 4090. Selected via --ollama-models.
OLLAMA_TIER="4090"
OLLAMA_TIER_EXPLICIT=false   # true once --ollama-models is passed (for the "no local provider" warning)
TEST_PROFILES=false          # --test-profiles: also install the experimental/bench models (mirrors Windows)
OLLAMA_HOST_ARG=""
MODEL_PATH=""
SKIP_MODELS=false
MODELS_ONLY=false
FORCE=false
LAN_CIDR=""
IS_SERVER_MODE=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CUSTOM_MODEL_LIST_PATH="${SCRIPT_DIR}/../config/ollama-models.txt"
AI_TOOLS_DIR="${HOME}/.local/share/ai-tools"
CRUSH_HOME_DIR="${HOME}/.crush"
CRUSH_CONFIG_DIR="${HOME}/.config/crush"
DEFAULT_MODEL_ROOT="${HOME}/.ollama/models"
VLLM_PORT=8000
# LAN model-switch web service (browser button page so non-technical/Windows users can switch
# models without an SSH account). Runs as the unprivileged VLLM_SWITCH_USER; port verified free
# on the server (clear of AdGuard 3000/53/80/443, Plex 32400/8080, vLLM 8000/8001).
VLLM_SWITCH_WEB_PORT=4090
VLLM_SWITCH_USER="vllm-model-control"
# Standing default served model = Mistral-Small-3.2-24B-Instruct (basic chat / general use). See the base
# vllm.service comment for the gghfez-weights + jeffcookio-tokenizer rationale. On-demand switch modes
# (cachyos-switch-model): coder = Qwen3-Coder (coding + office document authoring, the reliable tool-use
# model), coder-alt = Devstral-2 (agentic coding / review), image = HiDream + Qwen3-4B.
VLLM_DEFAULT_MODEL="gghfez/Mistral-Small-3.2-24B-Instruct-hf-AWQ"
VLLM_DEFAULT_TOKENIZER="jeffcookio/Mistral-Small-3.2-24B-Instruct-2506-awq-sym"
VLLM_DEFAULT_SERVED_NAME="mistral-small"
VLLM_DEFAULT_TOOL_PARSER="mistral"

# Squire Server (CachyOS vLLM) hooks for the deployed copilot-local launcher.
# SQUIRE_SERVER_IP empty = auto-derive (client host, else this box's LAN IP).
SQUIRE_SERVER_IP=""
SQUIRE_SSH_TARGET="jesse@192.168.1.99"

STEP_NUMBER=0
FAILURES=()
WARNINGS=()
SELECTED_MODELS=()
OLLAMA_TIER_LABEL="4090"
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
  --install local|server|client   What to install here (default: local). The ENGINE is explicit:
                               local   — Ollama engine: local Ollama server + models + client tools
                               server  — vLLM engine: vLLM host + models + switch service + LAN firewall
                               client  — no engine here: client tools only, talks to remote provider(s)
                               (Legacy values 'full' and 'ollama-only' are still accepted: full == local,
                                ollama-only == local --no-client-tools.)
  --no-client-tools            With --install local: install the Ollama server + models only (no Crush/MCP).
  --mode client|full|server    Legacy alias for --install (kept for back-compat; prints a nudge).
  --providers <list>           Comma list of crush client providers to wire: local,server
                               local  == this box's Ollama (localhost:11434)
                               server == the remote vLLM (Squire) server
                               (default: local->local,server; server/client->server)
                               ('squire-server' is accepted as a legacy alias for 'server'.)
  --default-provider <p>       Default crush provider: local | server
                               (default: local->local; server/client->server)
  --ollama-models 4090|5090    Ollama roster GPU tier: 4090 (24GB) or 5090 (32GB). Default: 4090.
                               Distinct per-tier aliases + tier-safe contexts. Applies to local installs
                               AND to client installs whose --providers includes 'local' (it selects the
                               launcher's model-alias menu so it matches the remote Ollama server's tier).
  --test-profiles              Also install the experimental/bench models (North Mini Code, Nemotron
                               Cascade 2, Ornith-1.0-35B, Qwen3-Next-80B). Default: production roster only.
  --squire-server-ip <ip>      Remote (server) address for client/local installs (default: 192.168.1.99)
  --squire-ssh-target <target> SSH target for the server model-switch (default: jesse@192.168.1.99)
  --ollama-host <url>          Optional extra remote Ollama provider (NOT required for client mode)
                               Example: http://host:11434
  --model-path <path>          Custom Ollama model directory (sets OLLAMA_MODELS; local mode only)
  --lan-cidr <cidr>            Override LAN CIDR for firewall (auto-detected if omitted)
                               Examples: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16
  --skip-models                Skip model downloads
  --models-only                Only download models; skip software installation
  --force                      Overwrite existing crush.json + Copilot mcp-config.json
                               (each backed up to a timestamped .bak first)
  --help                       Show this help text

Examples:
  ./install-cachyos.sh --install local                                  # Ollama server + client (local+server)
  ./install-cachyos.sh --install local --ollama-models 5090             # Ollama server, 32GB (5090) roster
  ./install-cachyos.sh --install local --no-client-tools                # Ollama server + models only
  ./install-cachyos.sh --install server                                 # vLLM server host + LAN exposure
  ./install-cachyos.sh --install client --providers local,server        # client, both, default local
  ./install-cachyos.sh --install client --providers local               # client, local Ollama only
  ./install-cachyos.sh --install client                                 # server-only client (pointed at remote)
  ./install-cachyos.sh --install client --force                         # refresh client configs (crush.json + mcp-config.json)
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
        mistral-small3.2:24b) printf '%s' 'Mistral Small 3.2 — docs/creative/chat, ~15 GB' ;;
        gemma4:31b) printf '%s' 'Gemma 4 31B — heavy coding (256k ctx), ~20 GB' ;;
        gemma4:26b) printf '%s' 'Gemma 4 26B MoE — general (256k ctx), ~17 GB' ;;
        qwen3:14b) printf '%s' 'Qwen3 14B — light coding profile (131k ctx), ~9 GB' ;;
        qwen3:4b) printf '%s' 'Qwen3 4B — image gen profile, VRAM-friendly (32k ctx), ~2.5 GB' ;;
        gemma3:27b) printf '%s' 'Gemma 3 27B — tech docs (128k ctx), ~16 GB' ;;
        llama3.3:70b-instruct-q2_K) printf '%s' 'Llama 3.3 70B Q2 — creative writing, ~26 GB' ;;
        qwen3-coder:30b) printf '%s' 'Qwen3-Coder 30B MoE — heavy coding/office docs (256k ctx), ~19 GB' ;;
        qwen3:32b) printf '%s' 'Qwen3 32B — creative writing (128k ctx), ~20 GB' ;;
        x/z-image-turbo) printf '%s' 'Z-Image Turbo 6B — image generation, ~12 GB' ;;
        # HuggingFace model IDs (vLLM server mode)
        QuantTrio/GLM-4.7-Flash-AWQ) printf '%s' 'GLM-4.7-Flash AWQ — RETIRED from the server roster (hallucinated in office/agentic use); Qwen3-Coder took its slot' ;;
        gghfez/Mistral-Small-3.2-24B-Instruct-hf-AWQ) printf '%s' 'Mistral-Small-3.2 24B AWQ — STANDING DEFAULT: basic chat / general (64K, tool-calling), ~14 GB' ;;
        jeffcookio/Mistral-Small-3.2-24B-Instruct-2506-awq-sym) printf '%s' 'Mistral-Small-3.2 tokenizer source (tekken.json for --tokenizer-mode mistral); weights unused' ;;
        cyankiwi/Devstral-Small-2-24B-Instruct-2512-AWQ-4bit) printf '%s' 'Devstral-2 24B AWQ — agentic-coding alternative (switch mode, dense, 384k ctx, compressed-tensors), ~14 GB' ;;
        Qwen/Qwen3-4B-Instruct-2507) printf '%s' 'Qwen3 4B — image-gen companion LLM (co-resides with HiDream), ~8 GB' ;;
        cyankiwi/Qwen3-4B-Instruct-2507-AWQ-4bit) printf '%s' 'Qwen3 4B AWQ-4bit — former image-gen companion (superseded by 1.7B), ~3.4 GB' ;;
        Orion-zhen/Qwen3-1.7B-AWQ) printf '%s' 'Qwen3 1.7B AWQ — image-gen companion LLM (co-resides with HiDream, 16K ctx), ~1.3 GB' ;;
        Qwen/Qwen3.6-27B-Instruct-GPTQ) printf '%s' 'Qwen3.6 27B GPTQ — primary model (32k ctx, FP8 KV), ~15 GB' ;;
        Qwen/Qwen2.5-Coder-32B-Instruct-GPTQ-Int4) printf '%s' 'Qwen2.5-Coder 32B GPTQ — heavy coding, ~18 GB' ;;
        btbtyler09/Qwen3-Coder-30B-A3B-Instruct-gptq-4bit) printf '%s' 'Qwen3-Coder 30B MoE GPTQ — heavy coding (agentic), ~19 GB' ;;
        Qwen/Qwen2.5-Coder-14B-Instruct-GPTQ-Int4) printf '%s' 'Qwen2.5-Coder 14B GPTQ — light coding, ~8 GB' ;;
        deepseek-ai/DeepSeek-R1-Distill-Qwen-32B-GPTQ-Int4) printf '%s' 'DeepSeek R1 Distill 32B GPTQ — code review, ~18 GB' ;;
        mistralai/Mistral-Small-3.2-24B-Instruct-2503-GPTQ-Int4) printf '%s' 'Mistral Small 3.2 GPTQ — docs/creative/chat, ~13 GB' ;;
        *) printf '%s' 'Custom model' ;;
    esac
}

# ── Ollama roster per GPU tier ────────────────────────────────────────────────
# Same base GGUFs across tiers (weights identical); only num_ctx differs. Selecting
# a tier populates the alias->base map, per-alias num_ctx, the task->alias SLOT map,
# and the alias->friendly-label registry used by the launchers' tier config.
# Globals set: OLLAMA_PULL_TAGS[], OLLAMA_ALIAS_FROM[], OLLAMA_ALIAS_CTX[],
#              OLLAMA_SLOT[], OLLAMA_ALIAS_LABEL[], OLLAMA_ALIAS_TEMPLATE[].
declare -A OLLAMA_ALIAS_FROM
declare -A OLLAMA_ALIAS_CTX
declare -A OLLAMA_SLOT
declare -A OLLAMA_ALIAS_LABEL
declare -A OLLAMA_ALIAS_TEMPLATE
OLLAMA_PULL_TAGS=()

populate_ollama_tier() {
    local tier="$1"

    # Reset (function may be called more than once).
    OLLAMA_ALIAS_FROM=()
    OLLAMA_ALIAS_CTX=()
    OLLAMA_SLOT=()
    OLLAMA_ALIAS_LABEL=()
    OLLAMA_ALIAS_TEMPLATE=()
    OLLAMA_PULL_TAGS=()

    # Base GGUF tags (identical across tiers).
    local mtp="hf.co/unsloth/Qwen3.6-27B-MTP-GGUF:Q4_K_M"
    local q36_35b="qwen3.6:35b"
    local gemma4="gemma4:31b"
    local coder="qwen3-coder:30b"
    local glm="glm-4.7-flash"
    local img="qwen3:8b"
    local northmini="hf.co/unsloth/North-Mini-Code-1.0-GGUF:UD-Q4_K_M"
    local nemotron="hf.co/bartowski/nvidia_Nemotron-3-Nano-30B-A3B-GGUF:Q4_K_M"
    local ornith="hf.co/deepreinforce-ai/Ornith-1.0-35B-GGUF:Q4_K_M"
    local devstral="hf.co/unsloth/Devstral-Small-2-24B-Instruct-2512-GGUF:Q4_K_M"
    local qwen3next="hf.co/Qwen/Qwen3-Next-80B-A3B-Instruct-GGUF:Q4_K_M"

    # Production roster (always). Experimental/bench models are added only with --test-profiles.
    OLLAMA_PULL_TAGS=("$mtp" "$q36_35b" "$gemma4" "$coder" "$glm" "$img")
    if [[ "$TEST_PROFILES" == true ]]; then
        OLLAMA_PULL_TAGS+=("$northmini" "$nemotron" "$ornith" "$devstral" "$qwen3next")
    fi

    # Per-tier alias names + contexts (24GB-safe on 4090; full on 5090).
    local a_heavy a_q3635 a_gemma a_coder a_glm a_north a_nemo a_ornith a_devstral
    local c_heavy c_q3635 c_gemma c_coder c_glm c_north c_nemo c_ornith c_devstral
    if [[ "$tier" == "5090" ]]; then
        a_heavy=qwen36-27b-212k;   c_heavy=217088
        a_q3635=qwen36-35b-256k;   c_q3635=262144
        a_gemma=gemma4-31b-128k;   c_gemma=131072
        a_coder=qwen3coder-144k;   c_coder=147456
        a_glm=glm47-flash-198k;    c_glm=202752
        a_north=northmini-code-256k; c_north=262144
        a_nemo=nemotron3-nano-256k; c_nemo=262144
        a_ornith=ornith-35b-256k;  c_ornith=262144
        a_devstral=devstral2-24b-128k; c_devstral=131072
    else
        a_heavy=qwen36-27b-96k;    c_heavy=98304
        a_q3635=qwen36-35b-96k;    c_q3635=98304
        a_gemma=gemma4-31b-64k;    c_gemma=65536
        a_coder=qwen3coder-64k;    c_coder=65536
        a_glm=glm47-flash-45k;     c_glm=46080
        a_north=northmini-code-96k; c_north=98304
        a_nemo=nemotron3-nano-96k; c_nemo=98304
        a_ornith=ornith-35b-96k;   c_ornith=98304
        a_devstral=devstral2-24b-64k; c_devstral=65536
    fi
    local a_offload=qwen3next-80b-offload
    local c_offload=131072

    OLLAMA_ALIAS_FROM["$a_heavy"]="$mtp";        OLLAMA_ALIAS_CTX["$a_heavy"]="$c_heavy"
    OLLAMA_ALIAS_FROM["$a_q3635"]="$q36_35b";    OLLAMA_ALIAS_CTX["$a_q3635"]="$c_q3635"
    OLLAMA_ALIAS_FROM["$a_gemma"]="$gemma4";     OLLAMA_ALIAS_CTX["$a_gemma"]="$c_gemma"
    OLLAMA_ALIAS_FROM["$a_coder"]="$coder";      OLLAMA_ALIAS_CTX["$a_coder"]="$c_coder"
    OLLAMA_ALIAS_FROM["$a_glm"]="$glm";          OLLAMA_ALIAS_CTX["$a_glm"]="$c_glm"

    # Task->alias SLOT map (drives the launcher tier config).
    OLLAMA_SLOT[heavy]="$a_heavy"
    OLLAMA_SLOT[coder]="$a_coder"
    OLLAMA_SLOT[review]="$a_coder"
    OLLAMA_SLOT[agentic]="$a_glm"
    OLLAMA_SLOT[image_llm]="$img"
    OLLAMA_SLOT[h1]="$a_heavy"
    OLLAMA_SLOT[h2]="$a_q3635"
    OLLAMA_SLOT[h3]="$a_gemma"
    OLLAMA_SLOT[h4]="$a_coder"
    OLLAMA_SLOT[h5]="$a_glm"

    # Friendly labels (identity is tier-independent).
    OLLAMA_ALIAS_LABEL["$a_heavy"]="Qwen3.6 27B (+MTP)"
    OLLAMA_ALIAS_LABEL["$a_q3635"]="Qwen3.6 35B-A3B"
    OLLAMA_ALIAS_LABEL["$a_gemma"]="Gemma 4 31B"
    OLLAMA_ALIAS_LABEL["$a_coder"]="Qwen3-Coder 30B-A3B"
    OLLAMA_ALIAS_LABEL["$a_glm"]="GLM-4.7-Flash"
    OLLAMA_ALIAS_LABEL["$img"]="Qwen3 8B"

    # Experimental/bench models — registered only with --test-profiles (aliases, bench task slots
    # [H6]-[H8]/[O2], friendly labels, and the Qwen3-Next ChatML template). Kept out of the maps
    # otherwise so the alias-creation loop never tries to build an un-pulled model.
    if [[ "$TEST_PROFILES" == true ]]; then
        OLLAMA_ALIAS_FROM["$a_north"]="$northmini";   OLLAMA_ALIAS_CTX["$a_north"]="$c_north"
        OLLAMA_ALIAS_FROM["$a_nemo"]="$nemotron";     OLLAMA_ALIAS_CTX["$a_nemo"]="$c_nemo"
        OLLAMA_ALIAS_FROM["$a_ornith"]="$ornith";     OLLAMA_ALIAS_CTX["$a_ornith"]="$c_ornith"
        OLLAMA_ALIAS_FROM["$a_devstral"]="$devstral"; OLLAMA_ALIAS_CTX["$a_devstral"]="$c_devstral"
        OLLAMA_ALIAS_FROM["$a_offload"]="$qwen3next"; OLLAMA_ALIAS_CTX["$a_offload"]="$c_offload"
        OLLAMA_SLOT[h6]="$a_north"
        OLLAMA_SLOT[h7]="$a_nemo"
        OLLAMA_SLOT[h8]="$a_ornith"
        OLLAMA_SLOT[h9]="$a_devstral"
        OLLAMA_SLOT[o2]="$a_offload"
        OLLAMA_ALIAS_LABEL["$a_north"]="North Mini Code 1.0"
        OLLAMA_ALIAS_LABEL["$a_nemo"]="Nemotron 3 Nano 30B-A3B"
        OLLAMA_ALIAS_LABEL["$a_ornith"]="Ornith-1.0-35B"
        OLLAMA_ALIAS_LABEL["$a_devstral"]="Devstral Small 2 (24B)"
        OLLAMA_ALIAS_LABEL["$a_offload"]="Qwen3-Next-80B-A3B (partial offload)"
        # Qwen3-Next needs an explicit ChatML template baked in (the GGUF's embedded template
        # renders an immediate-EOS empty reply under Ollama).
        OLLAMA_ALIAS_TEMPLATE["$a_offload"]='{{ if .System }}<|im_start|>system
{{ .System }}<|im_end|>
{{ end }}{{ range .Messages }}{{ if eq .Role "user" }}<|im_start|>user
{{ .Content }}<|im_end|>
{{ else if eq .Role "assistant" }}<|im_start|>assistant
{{ .Content }}<|im_end|>
{{ end }}{{ end }}<|im_start|>assistant
'
    fi
}

# Path the launchers read for their tier-aware local roster (replaces the old ollama-tier.sh).
LOCAL_MODELS_PATH="${HOME}/.config/local-llm/local-models.json"

# Generate the local model roster the launchers read: the repo template (scripts/local-models.json)
# provides the static per-launcher menus; this injects the tier-specific 'tier' + 'registry'
# (alias -> {label, ctx}) + 'task_alias' (slot -> alias). Self-contained: populates the tier first.
write_local_models_json() {
    populate_ollama_tier "$OLLAMA_TIER"

    local dest="$LOCAL_MODELS_PATH"
    local template="${SCRIPT_DIR}/../scripts/local-models.json"
    mkdir -p "$(dirname "$dest")"

    if [[ ! -f "$template" ]]; then
        add_warning "local-models.json template not found at $template — skipping local roster generation."
        return 0
    fi

    # Serialize the tier maps as key<TAB>value lines for the python merger.
    local slot_lines="" label_lines="" ctx_lines="" k
    for k in "${!OLLAMA_SLOT[@]}";        do slot_lines+="${k}"$'\t'"${OLLAMA_SLOT[$k]}"$'\n'; done
    for k in "${!OLLAMA_ALIAS_LABEL[@]}"; do label_lines+="${k}"$'\t'"${OLLAMA_ALIAS_LABEL[$k]}"$'\n'; done
    for k in "${!OLLAMA_ALIAS_CTX[@]}";   do ctx_lines+="${k}"$'\t'"${OLLAMA_ALIAS_CTX[$k]}"$'\n'; done

    if LL_TEMPLATE="$template" LL_TIER="$OLLAMA_TIER" \
       LL_SLOTS="$slot_lines" LL_LABELS="$label_lines" LL_CTX="$ctx_lines" \
       python3 - "$dest" <<'PY'
import json, os, sys
tmpl = json.load(open(os.environ["LL_TEMPLATE"]))
tmpl_reg = tmpl.get("registry", {})
def parse(env):
    out = {}
    for line in os.environ.get(env, "").splitlines():
        if not line.strip():
            continue
        k, _, v = line.partition("\t")
        out[k] = v
    return out
slots  = parse("LL_SLOTS")    # slot  -> alias
labels = parse("LL_LABELS")   # alias -> label
ctx    = parse("LL_CTX")      # alias -> ctx (str)
def ctx_of(alias):
    if alias in ctx and ctx[alias]:
        return int(ctx[alias])
    return int(tmpl_reg.get(alias, {}).get("ctx", 0) or 0)
registry = {}
for alias, label in labels.items():
    registry[alias] = {"label": label, "ctx": ctx_of(alias)}
# Ensure every task_alias target has a registry entry (e.g. the image alias).
for slot, alias in slots.items():
    if alias not in registry:
        registry[alias] = {"label": tmpl_reg.get(alias, {}).get("label", alias), "ctx": ctx_of(alias)}
out = {
    "_comment": tmpl.get("_comment", ""),
    "schema_version": tmpl.get("schema_version", 1),
    "tier": os.environ["LL_TIER"],
    "registry": registry,
    "task_alias": slots,
    "launchers": tmpl["launchers"],
}
with open(sys.argv[1], "w") as fh:
    json.dump(out, fh, indent=2)
PY
    then
        success "Wrote local model roster (${OLLAMA_TIER}) to $dest"
    else
        add_failure "Failed to generate local-models.json at $dest"
    fi
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

    if [[ "$IS_SERVER_MODE" == true ]]; then
        # vLLM (server): serves ONE model at a time (24GB). Mistral-Small is the standing default; the
        # rest are downloaded so the mode-switch (cachyos-switch-model) can load them on demand without a
        # fresh pull. (GLM-4.7-Flash was retired: it hallucinated in office/agentic use; Qwen3-Coder is
        # the office + coding model now.)
        SELECTED_MODELS=(
            "gghfez/Mistral-Small-3.2-24B-Instruct-hf-AWQ"
            "jeffcookio/Mistral-Small-3.2-24B-Instruct-2506-awq-sym"
            "btbtyler09/Qwen3-Coder-30B-A3B-Instruct-gptq-4bit"
            "cyankiwi/Devstral-Small-2-24B-Instruct-2512-AWQ-4bit"
            "Orion-zhen/Qwen3-1.7B-AWQ"
        )
        EFFECTIVE_MODEL_REQUIRED_GB=89
        OLLAMA_TIER_LABEL="n/a (vLLM)"
        MODEL_SOURCE_MESSAGE="Using vLLM (server) HuggingFace model roster."
    else
        # Ollama (local, single-user): roster is selected by the GPU tier.
        populate_ollama_tier "$OLLAMA_TIER"
        SELECTED_MODELS=("${OLLAMA_PULL_TAGS[@]}")
        EFFECTIVE_MODEL_REQUIRED_GB=205
        OLLAMA_TIER_LABEL="$OLLAMA_TIER"
        MODEL_SOURCE_MESSAGE="Using Ollama ${OLLAMA_TIER} roster."
    fi

    # Custom-list override applies to the local (Ollama) path only.
    if [[ "$IS_SERVER_MODE" != true && -f "$CUSTOM_MODEL_LIST_PATH" ]]; then
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
            MODEL_SOURCE_MESSAGE="Using custom model list from ../config/ollama-models.txt."
        else
            add_warning "Custom model list exists at $CUSTOM_MODEL_LIST_PATH but is empty after comments are removed. Falling back to the ${OLLAMA_TIER} roster."
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

    # Crush is not in the official Arch/CachyOS repos but is in the AUR (crush-bin =
    # prebuilt binary). Prefer it when a helper (yay) is present and we're non-root.
    if command_exists yay && [[ ${EUID} -ne 0 ]]; then
        info "Installing Crush from the AUR (crush-bin) via yay."
        if yay -S --needed --noconfirm crush-bin; then
            ensure_local_bin_on_path
            success "Crush installed from the AUR (crush-bin)."
            return 0
        fi
        warn "AUR install for Crush failed — falling back to user-local install."
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

ensure_dotnet_tools_on_path() {
    case ":${PATH}:" in
        *":${HOME}/.dotnet/tools:"*) ;;
        *) export PATH="${HOME}/.dotnet/tools:${PATH}" ;;
    esac
}

install_csharp_ls() {
    # csharp-ls is the C# language server referenced by crush.json's lsp block. It is a
    # .NET global tool (dotnet tool install), NOT a pacman/AUR package.
    ensure_dotnet_tools_on_path

    if command_exists csharp-ls || [[ -x "${HOME}/.dotnet/tools/csharp-ls" ]]; then
        info "csharp-ls is already installed: $(csharp-ls --version 2>/dev/null | head -n1 || true)"
        return 0
    fi

    # 'dotnet tool install' requires the .NET SDK (not just a runtime). On Arch/CachyOS: dotnet-sdk.
    if ! command_exists dotnet; then
        if command_exists pacman && { [[ ${EUID} -eq 0 ]] || command_exists sudo; }; then
            info "Installing the .NET SDK (dotnet-sdk) — required to install csharp-ls."
            if ! run_privileged pacman -S --needed --noconfirm dotnet-sdk; then
                warn "Could not install dotnet-sdk — skipping csharp-ls (Crush works without it)."
                return 1
            fi
        else
            warn "dotnet not found and pacman/privilege unavailable — skipping csharp-ls."
            return 1
        fi
    fi

    info "Installing csharp-ls (dotnet global tool)."
    if ! dotnet tool install --global csharp-ls >/dev/null 2>&1; then
        warn "csharp-ls install failed — skipping (Crush works without it; C# LSP disabled)."
        return 1
    fi
    ensure_dotnet_tools_on_path

    # Persist ~/.dotnet/tools on PATH so Crush finds csharp-ls in future interactive shells.
    local rc="${HOME}/.bashrc"
    if [[ -f "$rc" ]] && ! grep -q '\.dotnet/tools' "$rc" 2>/dev/null; then
        printf '\n# Added by install-cachyos.sh: .NET global tools (csharp-ls for Crush LSP)\nexport PATH="$HOME/.dotnet/tools:$PATH"\n' >> "$rc"
        info "Added ~/.dotnet/tools to PATH in ~/.bashrc."
    fi

    # Verify the tool actually runs (catches a .NET runtime mismatch).
    if csharp-ls --version >/dev/null 2>&1; then
        success "csharp-ls installed: $(csharp-ls --version 2>/dev/null | head -n1)"
    else
        warn "csharp-ls installed but did not run cleanly (may need a specific .NET runtime)."
    fi
    return 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)
                [[ $# -lt 2 ]] && { fail "--mode requires a value."; usage; exit 1; }
                MODE="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
                shift 2
                ;;
            --install)
                [[ $# -lt 2 ]] && { fail "--install requires a value."; usage; exit 1; }
                INSTALL="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
                shift 2
                ;;
            --providers)
                [[ $# -lt 2 ]] && { fail "--providers requires a value (e.g. local,server)."; usage; exit 1; }
                PROVIDERS="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
                shift 2
                ;;
            --default-provider)
                [[ $# -lt 2 ]] && { fail "--default-provider requires a value (local|server)."; usage; exit 1; }
                DEFAULT_PROVIDER="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
                shift 2
                ;;
            --ollama-models)
                [[ $# -lt 2 ]] && { fail "--ollama-models requires a value (4090|5090)."; usage; exit 1; }
                OLLAMA_TIER="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
                OLLAMA_TIER_EXPLICIT=true
                shift 2
                ;;
            --test-profiles)
                TEST_PROFILES=true
                shift
                ;;
            --no-client-tools)
                NO_CLIENT_TOOLS=true
                shift
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
            --squire-server-ip)
                [[ $# -lt 2 ]] && { fail "--squire-server-ip requires a value."; usage; exit 1; }
                SQUIRE_SERVER_IP="$2"
                shift 2
                ;;
            --squire-ssh-target)
                [[ $# -lt 2 ]] && { fail "--squire-ssh-target requires a value."; usage; exit 1; }
                SQUIRE_SSH_TARGET="$2"
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

main() {
parse_args "$@"

printf '%b\n' ""
printf '%b\n' "${COLOR_MAGENTA}╔══════════════════════════════════════════════════════════════╗${COLOR_RESET}"
printf '%b\n' "${COLOR_MAGENTA}║   CachyOS Server — Local LLM Stack Installer                 ║${COLOR_RESET}"
printf '%b\n' "${COLOR_MAGENTA}║   Ollama · Crush · uv · MCP Servers                          ║${COLOR_RESET}"
printf '%b\n' "${COLOR_MAGENTA}╚══════════════════════════════════════════════════════════════╝${COLOR_RESET}"
printf '%b\n' ""

# Reconcile --install (primary) with legacy --mode (alias). --install takes precedence.
# New vocabulary: local (Ollama), server (vLLM), client. Legacy full/ollama-only accepted.
if [[ -n "$INSTALL" ]]; then
    case "$INSTALL" in
        local)       MODE="full";   SHOULD_INSTALL_CLIENT_TOOLS=true ;;
        client)      MODE="client"; SHOULD_INSTALL_CLIENT_TOOLS=true ;;
        server)      MODE="server"; SHOULD_INSTALL_CLIENT_TOOLS=true ;;
        full)        MODE="full";   SHOULD_INSTALL_CLIENT_TOOLS=true
                     info "--install full is a legacy alias; use --install local (Ollama engine)." ;;
        ollama-only) MODE="full";   SHOULD_INSTALL_CLIENT_TOOLS=false
                     info "--install ollama-only is a legacy alias; use --install local --no-client-tools." ;;
        *) fail "--install must be local, server, or client (legacy: full, ollama-only)."; exit 1 ;;
    esac
elif [[ -n "$MODE" && "$MODE" != "full" ]]; then
    # Legacy --mode path (no --install given).
    info "--mode is a legacy alias; use --install local|server|client."
    case "$MODE" in
        full)   INSTALL="local" ;;
        server) INSTALL="server" ;;
        client) INSTALL="client" ;;
    esac
else
    INSTALL="local"   # default
fi

# --no-client-tools applies to local installs only.
if [[ "$NO_CLIENT_TOOLS" == true ]]; then
    if [[ "$MODE" != "full" ]]; then
        fail "--no-client-tools is only valid with --install local."
        exit 1
    fi
    SHOULD_INSTALL_CLIENT_TOOLS=false
fi

case "$MODE" in
    full|client|server) ;;
    *) fail "--mode must be client, full, or server."; exit 1 ;;
esac

# Validate the Ollama roster GPU tier.
case "$OLLAMA_TIER" in
    4090|5090) ;;
    *) fail "--ollama-models must be 4090 or 5090."; exit 1 ;;
esac

if [[ "$MODE" == "client" && -n "$OLLAMA_HOST_ARG" ]]; then
    info "Client mode targets the server (vLLM); --ollama-host will be kept only as an optional extra remote-Ollama provider."
fi

if [[ "$MODE" == "client" && "$MODELS_ONLY" == true ]]; then
    add_warning "--models-only is ignored in client mode. Continuing with client installation."
    MODELS_ONLY=false
fi

if [[ "$MODE" == "client" && "$SKIP_MODELS" == true ]]; then
    add_warning "--skip-models is irrelevant in client mode because no local models are pulled."
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
    OLLAMA_TIER_LABEL="n/a (client mode)"
fi

# Client-side provider selection (crush providers + launcher entries). N/A for --no-client-tools.
# 'server' is the canonical name for the vLLM provider; 'squire-server' is a deprecated input alias.
if [[ -n "$PROVIDERS" ]]; then
    PROVIDERS="$(printf '%s' "$PROVIDERS" | sed -E 's/(^|,)squire-server($|,)/\1server\2/g; s/(^|,)squire-server($|,)/\1server\2/g')"
fi
[[ "$DEFAULT_PROVIDER" == "squire-server" ]] && DEFAULT_PROVIDER="server"
if [[ -z "$PROVIDERS" ]]; then
    case "$MODE" in
        full) PROVIDERS="local,server" ;;
        *)    PROVIDERS="server" ;;   # client, server
    esac
fi
if [[ -z "$DEFAULT_PROVIDER" ]]; then
    case "$MODE" in
        full) DEFAULT_PROVIDER="local" ;;
        *)    DEFAULT_PROVIDER="server" ;;
    esac
fi
for pv in ${PROVIDERS//,/ }; do
    case "$pv" in
        local|server) ;;
        *) fail "--providers entries must be 'local' or 'server' (got '$pv')."; exit 1 ;;
    esac
done
# The Ollama tier only takes effect when the launchers present local Ollama entries — i.e. when the
# resolved providers include 'local' (true for local installs AND for client installs with a local
# provider, where it selects the alias menu that matches the remote Ollama server's tier). Warn only if
# a tier was set explicitly but no local provider is wired, where it has no effect.
if [[ "$OLLAMA_TIER_EXPLICIT" == true && ",$PROVIDERS," != *",local,"* ]]; then
    add_warning "--ollama-models ${OLLAMA_TIER} has no effect without a 'local' provider (providers=${PROVIDERS}); ignored."
fi
case "$DEFAULT_PROVIDER" in
    local|server) ;;
    *) fail "--default-provider must be 'local' or 'server'."; exit 1 ;;
esac
if [[ ",$PROVIDERS," != *",$DEFAULT_PROVIDER,"* ]]; then
    fail "--default-provider '$DEFAULT_PROVIDER' must be one of --providers '$PROVIDERS'."; exit 1
fi

# Engine-explicit summary line.
case "$MODE" in
    full)   info "Install mode: local (Ollama)" ;;
    server) info "Install mode: server (vLLM)" ;;
    client) info "Install mode: client (no local engine)" ;;
esac
info "Ollama roster: $OLLAMA_TIER_LABEL"
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

    # Robust GPU detection — accept any authoritative signal, not just lspci's vendor string
    # (which can transiently render without the "NVIDIA" name). nvidia-smi / the kernel module
    # are the strongest signals; lspci (name or 10de vendor id) is the fallback.
    gpu_detected=false
    if command_exists nvidia-smi && nvidia-smi -L >/dev/null 2>&1; then
        gpu_detected=true
    elif [[ -e /proc/driver/nvidia/version ]]; then
        gpu_detected=true
    elif command_exists lspci && lspci -nn 2>/dev/null | grep -qiE 'nvidia|\[10de:'; then
        gpu_detected=true
    fi
    if [[ "$gpu_detected" == true ]]; then
        success "NVIDIA GPU detected."
    elif ! command_exists lspci && ! command_exists nvidia-smi; then
        add_failure "Cannot detect a GPU: neither nvidia-smi nor lspci is installed (install pciutils)."
    else
        add_failure "No NVIDIA GPU detected (checked nvidia-smi, /proc/driver/nvidia, lspci)."
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
        # If the CachyOS prebuilt open kernel modules (nvidia-open) are already
        # installed, do NOT pull nvidia-dkms — the two provide the same kernel
        # module and would conflict. Keep the working open driver and only add
        # userspace (nvidia-utils) + CUDA.
        if pacman -Qq 2>/dev/null | grep -q 'nvidia-open'; then
            nvidia_packages=(nvidia-utils cuda)
            info "Detected nvidia-open driver; skipping nvidia-dkms. Installing nvidia-utils and cuda."
        else
            nvidia_packages=(nvidia-dkms nvidia-utils cuda)
            info "Installing nvidia-dkms, nvidia-utils, and cuda from CachyOS repositories."
        fi
        if run_privileged pacman -S --needed --noconfirm "${nvidia_packages[@]}"; then
            success "NVIDIA packages are installed."
        else
            add_failure "Failed to install NVIDIA drivers and CUDA packages."
        fi

        # The cuda package installs nvcc to /opt/cuda/bin, which is not on PATH by
        # default. Add it for this run so the vLLM CUDA-version detection below (and
        # the flash-attn build) can find nvcc.
        if [[ -d /opt/cuda/bin ]]; then
            case ":${PATH}:" in
                *":/opt/cuda/bin:"*) ;;
                *) export PATH="/opt/cuda/bin:${PATH}" ;;
            esac
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

            step "Install hf CLI (model downloader)"
            VLLM_VENV="${HOME}/.local/share/vllm-env"
            # huggingface_hub >=1.0 ships the `hf` CLI; the old `huggingface-cli` is deprecated and no
            # longer works. vLLM/transformers already pull huggingface_hub in, so `hf` usually exists.
            if [[ -x "$VLLM_VENV/bin/hf" ]]; then
                info "hf CLI already available in vLLM venv."
            else
                "$UV_BIN" pip install --python "$VLLM_VENV/bin/python" huggingface_hub || add_warning "huggingface_hub (hf CLI) install failed."
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
    --tokenizer \${VLLM_TOKENIZER} \\
    --tokenizer-mode \${VLLM_TOKENIZER_MODE} \\
    --host \${VLLM_HOST} \\
    --port \${VLLM_PORT} \\
    --max-model-len \${VLLM_MAX_MODEL_LEN} \\
    --hf-overrides '{\"max_position_embeddings\":131072}' \\
    --max-num-seqs \${VLLM_MAX_NUM_SEQS} \\
    --gpu-memory-utilization \${VLLM_GPU_MEMORY_UTILIZATION} \\
    --kv-cache-dtype \${VLLM_KV_CACHE_DTYPE} \\
    --served-model-name \${VLLM_SERVED_NAME} active-model \\
    --enable-auto-tool-choice \\
    --tool-call-parser \${VLLM_TOOL_PARSER}
# Standing default = Mistral-Small-3.2-24B (basic chat / general). Weights = gghfez AWQ (compressed-tensors, auto-
# detected — no --quantization); tokenizer = jeffcookio tekken (--tokenizer-mode mistral) since gghfez's
# HF tokenizer mis-detokenizes. The gghfez re-quant's config.json wrongly caps max_position_embeddings
# at 32768, though the upstream Mistral-3.2 (same weights, rope_theta=1e9) is natively 128K. Serving
# --max-model-len 65536 against that truncated table let a >32768-token prompt overrun it -> CUDA
# device-side assert -> engine crash (seen 2026-07-16, office authoring). --hf-overrides restores the
# true 131072 position table so the 64K window is in-bounds. VLLM_ALLOW_LONG_MAX_MODEL_LEN=1 is now a
# no-op (derived max == 131072 > 65536). Mistral has no reasoning parser.
Environment=\"VLLM_MODEL=${VLLM_DEFAULT_MODEL}\"
Environment=\"VLLM_TOKENIZER=${VLLM_DEFAULT_TOKENIZER}\"
Environment=\"VLLM_TOKENIZER_MODE=mistral\"
Environment=\"VLLM_SERVED_NAME=${VLLM_DEFAULT_SERVED_NAME}\"
Environment=\"VLLM_TOOL_PARSER=${VLLM_DEFAULT_TOOL_PARSER}\"
Environment=\"VLLM_ALLOW_LONG_MAX_MODEL_LEN=1\"
Environment=\"VLLM_HOST=0.0.0.0\"
Environment=\"VLLM_PORT=${VLLM_PORT}\"
Environment=\"VLLM_MAX_MODEL_LEN=65536\"
Environment=\"VLLM_MAX_NUM_SEQS=16\"
Environment=\"VLLM_GPU_MEMORY_UTILIZATION=0.92\"
# flashinfer JIT-compiles its sampling kernel at startup and needs nvcc; CachyOS puts CUDA in /opt/cuda.
Environment=\"CUDA_HOME=/opt/cuda\"
Environment=\"VLLM_KV_CACHE_DTYPE=fp8_e5m2\"
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
"
            if printf '%s' "$vllm_service_content" | run_privileged tee "$local_vllm_service" >/dev/null; then
                run_privileged systemctl daemon-reload
                # If vllm is already running (re-install), restart it so base-service arg changes
                # (served-name, context, etc.) actually take effect. No-op on a fresh install.
                if systemctl is-active --quiet vllm.service; then
                    info "vLLM is running — restarting to apply the updated service definition..."
                    run_privileged systemctl try-restart vllm.service
                fi
                success "Created vLLM service at $local_vllm_service"
                info "Default model: ${VLLM_DEFAULT_MODEL} (served as '${VLLM_DEFAULT_SERVED_NAME}')"
                info "Listening on: 0.0.0.0:${VLLM_PORT}"
                info "To switch modes: cachyos-switch-model {mistral|coder|coder-alt|image}"
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
            local imagegen_dir="${HOME}/.local/share/ai-tools/imagegen"
            local imagegen_repo="${imagegen_dir}/HiDream-O1-Image"
            local imagegen_venv="${imagegen_dir}/.venv"

            # Clone inference repo if missing
            if [[ ! -f "${imagegen_repo}/models/pipeline.py" ]]; then
                info "Cloning HiDream-O1-Image inference repo..."
                git clone --depth 1 https://github.com/HiDream-ai/HiDream-O1-Image.git "${imagegen_repo}"
            fi

            # Make flash-attention optional in HiDream's pipeline. Upstream hardcodes use_flash_attn=True,
            # which hard-asserts flash_attn is installed and 500s on generation when it isn't. A fresh
            # clone reverts this, so re-patch every run: fall back to SDPA when flash_attn is absent.
            # (validated on-box 2026-07-07: image gen 500'd until patched.) Idempotent.
            if [[ -f "${imagegen_repo}/models/pipeline.py" ]]; then
                python3 - "${imagegen_repo}/models/pipeline.py" <<'PYEOF' && info "HiDream pipeline.py: flash-attn optional (SDPA fallback)." || add_warning "Could not patch HiDream pipeline.py (image gen may 500 without flash_attn)."
import re, sys
f = sys.argv[1]; s = open(f).read()
if '_FLASH_ATTN_AVAILABLE' not in s:
    detect = ('# Patched by dotFiles local-llm installer: make flash-attention optional (SDPA fallback).\n'
              'try:\n'
              '    from .qwen3_vl_transformers import _flash_attn_func as _FAF\n'
              '    _FLASH_ATTN_AVAILABLE = _FAF is not None\n'
              'except Exception:\n'
              '    _FLASH_ATTN_AVAILABLE = False\n\nTIMESTEP_TOKEN_NUM = 1')
    s = re.sub(r'(?m)^TIMESTEP_TOKEN_NUM = 1\r?$', detect, s, count=1)
    s = s.replace('"use_flash_attn": True,', '"use_flash_attn": _FLASH_ATTN_AVAILABLE,')
    open(f, 'w').write(s)
PYEOF
            fi

            # Create venv if missing
            if [[ ! -f "${imagegen_venv}/bin/python" ]]; then
                info "Creating image generation venv..."
                uv venv "${imagegen_venv}" --python 3.12 --quiet
                VIRTUAL_ENV="${imagegen_venv}" uv pip install --quiet \
                    torch torchvision --index-url https://download.pytorch.org/whl/cu128
                VIRTUAL_ENV="${imagegen_venv}" uv pip install --quiet \
                    "transformers==4.57.1" diffusers accelerate einops scipy numpy pillow tqdm \
                    fastapi uvicorn pydantic huggingface_hub
                # flash-attn is optional: it compiles against the just-installed torch
                # (needs nvcc + --no-build-isolation) and HiDream falls back to SDPA if it
                # is absent. Keep it non-fatal so a build failure doesn't abort the install.
                VIRTUAL_ENV="${imagegen_venv}" uv pip install --quiet --no-build-isolation flash-attn \
                    && success "flash-attn installed." \
                    || add_warning "flash-attn install failed — HiDream will use the SDPA fallback."
            fi

            # Copy server script
            cp "${SCRIPT_DIR}/../windows/imagegen-server.py" "${imagegen_dir}/imagegen-server.py"

            local imagegen_service_content="[Unit]
Description=Image Generation API (HiDream-O1-Image-Dev)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$(whoami)
WorkingDirectory=${imagegen_dir}
ExecStart=${imagegen_venv}/bin/python ${imagegen_dir}/imagegen-server.py \\
    --host 0.0.0.0 \\
    --port ${IMAGEGEN_PORT}
Environment=\"LOCALAPPDATA=${HOME}/.local/share\"
Environment=\"CUDA_HOME=/opt/cuda\"
Restart=on-failure
RestartSec=15

[Install]
WantedBy=multi-user.target
"
            if printf '%s' "$imagegen_service_content" | run_privileged tee "$imagegen_service" >/dev/null; then
                run_privileged systemctl daemon-reload
                success "Created imagegen.service (HiDream-O1-Image-Dev)"
                info "Model: HiDream-O1-Image-Dev on port ${IMAGEGEN_PORT}"
                info "On-demand only — do NOT enable on boot (single GPU). Reach it with: cachyos-switch-model image"
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

            step "Configure model-switch mechanism (cachyos-switch-model)"
            # vLLM holds ONE model at a time in 24GB. Mistral-Small-3.2 (vllm.service) is the
            # standing default; coder/coder-alt/image modes are loaded on demand via templated
            # vllm@<mode>.service instances + the existing imagegen.service (HiDream).
            VLLM_VENV="${HOME}/.local/share/vllm-env"
            run_privileged mkdir -p /etc/vllm/modes

            # Wrapper: builds the vLLM args from the mode env-file (quantization optional).
            local vllm_serve_wrapper="#!/usr/bin/env bash
set -euo pipefail
# flashinfer JIT-compiles its sampling kernel at startup and needs nvcc; CachyOS puts CUDA in /opt/cuda.
export CUDA_HOME=\"\${CUDA_HOME:-/opt/cuda}\"
export PATH=\"\${CUDA_HOME}/bin:\${PATH}\"
VENV=\"${VLLM_VENV}\"
args=(
    --model \"\${VLLM_MODEL}\"
    --host \"\${VLLM_HOST:-0.0.0.0}\"
    --port \"\${VLLM_PORT:-${VLLM_PORT}}\"
    --max-model-len \"\${VLLM_MAX_MODEL_LEN:-32768}\"
    --max-num-seqs \"\${VLLM_MAX_NUM_SEQS:-16}\"
    --gpu-memory-utilization \"\${VLLM_GPU_MEMORY_UTILIZATION:-0.90}\"
    --kv-cache-dtype \"\${VLLM_KV_CACHE_DTYPE:-fp8_e5m2}\"
    --served-model-name \"\${VLLM_SERVED_NAME}\" active-model
)
if [[ -n \"\${VLLM_QUANTIZATION:-}\" ]]; then
    args+=(--quantization \"\${VLLM_QUANTIZATION}\")
fi
if [[ -n \"\${VLLM_TOOL_PARSER:-}\" ]]; then
    args+=(--enable-auto-tool-choice --tool-call-parser \"\${VLLM_TOOL_PARSER}\")
fi
if [[ -n \"\${VLLM_REASONING_PARSER:-}\" ]]; then
    args+=(--reasoning-parser \"\${VLLM_REASONING_PARSER}\")
fi
exec \"\${VENV}/bin/python\" -m vllm.entrypoints.openai.api_server \"\${args[@]}\"
"
            if printf '%s' "$vllm_serve_wrapper" | run_privileged tee /usr/local/bin/cachyos-vllm-serve >/dev/null; then
                run_privileged chmod 0755 /usr/local/bin/cachyos-vllm-serve
                success "Created /usr/local/bin/cachyos-vllm-serve"
            else
                add_failure "Failed to create cachyos-vllm-serve wrapper."
            fi

            # Templated vLLM service: instance name = mode, config from /etc/vllm/modes/<mode>.env
            local vllm_template_service="/etc/systemd/system/vllm@.service"
            local vllm_template_content="[Unit]
Description=vLLM Inference Server (%i mode)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$(whoami)
EnvironmentFile=/etc/vllm/modes/%i.env
ExecStart=/usr/local/bin/cachyos-vllm-serve
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
"
            printf '%s' "$vllm_template_content" | run_privileged tee "$vllm_template_service" >/dev/null \
                && success "Created vllm@.service template" \
                || add_failure "Failed to create vllm@.service template."

            # Mode env-files. coder/coder-alt get full VRAM; image companion shares with HiDream.
            # qwen3_coder tool parser is REQUIRED for agentic use: crush drives coding with tool_choice=auto,
            # which vLLM 400s without --enable-auto-tool-choice + --tool-call-parser. (Instruct, non-thinking
            # -> no reasoning parser.)
            local coder_env="VLLM_MODEL=btbtyler09/Qwen3-Coder-30B-A3B-Instruct-gptq-4bit
VLLM_SERVED_NAME=qwen3-coder
VLLM_QUANTIZATION=gptq
VLLM_TOOL_PARSER=qwen3_coder
VLLM_HOST=0.0.0.0
VLLM_PORT=${VLLM_PORT}
VLLM_MAX_MODEL_LEN=57344
VLLM_GPU_MEMORY_UTILIZATION=0.90
VLLM_KV_CACHE_DTYPE=fp8_e5m2
"
            # coder-alt: Devstral-2 24B (dense, agentic-SWE) — AWQ is compressed-tensors format,
            # so leave VLLM_QUANTIZATION unset and let vLLM auto-detect it. mistral tool parser is REQUIRED
            # for agentic use (Devstral is Mistral-family; verified it emits parseable tool calls without
            # --tokenizer-mode mistral). Non-thinking -> no reasoning parser.
            local coder_alt_env="VLLM_MODEL=cyankiwi/Devstral-Small-2-24B-Instruct-2512-AWQ-4bit
VLLM_SERVED_NAME=devstral
VLLM_TOOL_PARSER=mistral
VLLM_HOST=0.0.0.0
VLLM_PORT=${VLLM_PORT}
VLLM_MAX_MODEL_LEN=57344
VLLM_GPU_MEMORY_UTILIZATION=0.90
VLLM_KV_CACHE_DTYPE=fp8_e5m2
"
            # Image companion: 1.7B AWQ (quant auto-detected), low util to co-reside with HiDream
            # (imagegen.service). Single tier: 16K served desktop-up AND headless (validated 942 MiB free
            # desktop-up, 3x 1024 gens PASS; headless frees only ~530 MiB so no larger tier warrants a swap).
            # served-name stays qwen3-4b so crush/copilot are unchanged. hermes tool parser + qwen3 reasoning
            # parser are REQUIRED: crush's image flow sends the imagegen MCP tools with tool_choice=auto, which
            # vLLM rejects with HTTP 400 unless --enable-auto-tool-choice + --tool-call-parser are set; the
            # reasoning parser keeps the 1.7B's <think> out of the message content.
            local image_env="VLLM_MODEL=Orion-zhen/Qwen3-1.7B-AWQ
VLLM_SERVED_NAME=qwen3-4b
VLLM_TOOL_PARSER=hermes
VLLM_REASONING_PARSER=qwen3
VLLM_HOST=0.0.0.0
VLLM_PORT=${VLLM_PORT}
VLLM_MAX_MODEL_LEN=32768
VLLM_MAX_NUM_SEQS=8
VLLM_GPU_MEMORY_UTILIZATION=0.16
VLLM_KV_CACHE_DTYPE=fp8_e5m2
"
            printf '%s' "$coder_env"     | run_privileged tee /etc/vllm/modes/coder.env     >/dev/null
            printf '%s' "$coder_alt_env" | run_privileged tee /etc/vllm/modes/coder-alt.env >/dev/null
            printf '%s' "$image_env"     | run_privileged tee /etc/vllm/modes/image.env     >/dev/null
            success "Wrote mode env-files (coder, coder-alt, image) to /etc/vllm/modes"

            # The switch CLI (also invoked over ssh by the client launchers).
            local switch_script="#!/usr/bin/env bash
set -euo pipefail
mode=\"\${1:-mistral}\"
SUDO=\"\"
[[ \$EUID -ne 0 ]] && SUDO=\"sudo\"
stop_all() {
    for u in vllm.service vllm@coder.service vllm@coder-alt.service vllm@image.service imagegen.service; do
        \$SUDO systemctl stop \"\$u\" 2>/dev/null || true
    done
}
case \"\$mode\" in
    mistral)   stop_all; \$SUDO systemctl start vllm.service ;;
    coder)     stop_all; \$SUDO systemctl start vllm@coder.service ;;
    coder-alt) stop_all; \$SUDO systemctl start vllm@coder-alt.service ;;
    image)     stop_all; \$SUDO systemctl start imagegen.service; \$SUDO systemctl start vllm@image.service ;;
    *) echo \"Unknown mode: \$mode (use: mistral|coder|coder-alt|image)\" >&2; exit 1 ;;
esac
echo \"cachyos-switch-model: now in '\$mode' mode\"
"
            if printf '%s' "$switch_script" | run_privileged tee /usr/local/bin/cachyos-switch-model >/dev/null; then
                run_privileged chmod 0755 /usr/local/bin/cachyos-switch-model
                success "Created /usr/local/bin/cachyos-switch-model"
            else
                add_failure "Failed to create cachyos-switch-model."
            fi

            # Passwordless sudo for the switch (so client ssh can flip modes non-interactively).
            local switch_user; switch_user="$(whoami)"
            local sudoers_line="${switch_user} ALL=(root) NOPASSWD: /usr/bin/systemctl start vllm.service, /usr/bin/systemctl stop vllm.service, /usr/bin/systemctl start vllm@coder.service, /usr/bin/systemctl stop vllm@coder.service, /usr/bin/systemctl start vllm@coder-alt.service, /usr/bin/systemctl stop vllm@coder-alt.service, /usr/bin/systemctl start vllm@image.service, /usr/bin/systemctl stop vllm@image.service, /usr/bin/systemctl start imagegen.service, /usr/bin/systemctl stop imagegen.service"
            if printf '%s\n' "$sudoers_line" | run_privileged tee /etc/sudoers.d/cachyos-vllm-switch >/dev/null; then
                run_privileged chmod 0440 /etc/sudoers.d/cachyos-vllm-switch
                if run_privileged visudo -c -f /etc/sudoers.d/cachyos-vllm-switch >/dev/null 2>&1; then
                    success "Configured passwordless systemctl for mode switching"
                else
                    run_privileged rm -f /etc/sudoers.d/cachyos-vllm-switch
                    add_warning "sudoers validation failed; removed drop-in. Mode switch will prompt for a password."
                fi
            else
                add_warning "Could not write sudoers drop-in for mode switching."
            fi

            # ── Desktop/headless toggle ───────────────────────────────────────
            # server-desktop {on|off|status}: toggles the KDE Plasma desktop (for RDP). The default model
            # (Mistral-Small-3.2 @ 64K, util 0.92) already fits alongside the ~750 MiB desktop, so this just
            # starts/stops plasmalogin — no vLLM restart or context change needed. Headless simply frees the
            # ~750 MiB back to the GPU (extra KV/concurrency headroom).
            local server_desktop_script="#!/usr/bin/env bash
set -euo pipefail
SUDO=\"\"; [[ \$EUID -ne 0 ]] && SUDO=\"sudo\"
case \"\${1:-}\" in
  off)
    echo 'Going headless: stopping the Plasma desktop (frees ~750 MiB VRAM)...'
    \$SUDO systemctl stop plasmalogin.service 2>/dev/null || true
    echo 'Headless. RDP is unavailable until: server-desktop on'
    ;;
  on)
    echo 'Starting the Plasma desktop for RDP...'
    \$SUDO systemctl start plasmalogin.service
    echo 'Desktop up — RDP via xrdp.'
    ;;
  status)
    systemctl is-active plasmalogin.service >/dev/null 2>&1 && echo 'desktop: up (RDP available)' || echo 'desktop: down (headless)'
    systemctl is-active vllm.service >/dev/null 2>&1 && echo 'vllm: up' || echo 'vllm: down'
    ;;
  *) echo 'Usage: server-desktop {on|off|status}' >&2; exit 1 ;;
esac
"
            if printf '%s' "$server_desktop_script" | run_privileged tee /usr/local/bin/server-desktop >/dev/null; then
                run_privileged chmod 0755 /usr/local/bin/server-desktop
                success "Created /usr/local/bin/server-desktop (toggle desktop/headless)"
            else
                add_warning "Failed to create server-desktop toggle."
            fi

            run_privileged systemctl daemon-reload
            info "Standing default: Mistral-Small-3.2 (vllm.service). Switch with: cachyos-switch-model {mistral|coder|coder-alt|image}"

            # ── Model-switch web service (LAN, port ${VLLM_SWITCH_WEB_PORT}) ──────────────
            # Dependency-free browser button page so LAN users (esp. Windows / non-technical)
            # can switch models without an SSH account or password. Runs as the unprivileged
            # ${VLLM_SWITCH_USER} account; the actual switch is performed by cachyos-switch-model
            # via the narrow passwordless-sudo grant below. LAN-only via ufw.
            step "Configure model-switch web service (port ${VLLM_SWITCH_WEB_PORT})"

            # Dedicated login-less system account (idempotent).
            if id -u "$VLLM_SWITCH_USER" >/dev/null 2>&1; then
                info "Account $VLLM_SWITCH_USER already exists."
            elif run_privileged useradd --system --no-create-home --shell /usr/sbin/nologin "$VLLM_SWITCH_USER"; then
                run_privileged usermod -L "$VLLM_SWITCH_USER" 2>/dev/null || true
                success "Created system account $VLLM_SWITCH_USER (nologin, locked)."
            else
                add_warning "Could not create $VLLM_SWITCH_USER account."
            fi

            # Deploy the daemon (shipped alongside this installer). Gate the unit/firewall/enable
            # steps on a successful copy so we don't register + start a service whose binary is missing.
            local web_daemon_ok=false
            if [[ -f "${SCRIPT_DIR}/vllm-switch-web.py" ]]; then
                if run_privileged install -m 0755 "${SCRIPT_DIR}/vllm-switch-web.py" /usr/local/bin/vllm-switch-web; then
                    success "Installed /usr/local/bin/vllm-switch-web"
                    web_daemon_ok=true
                    # Install the server roster the daemon reads (single source of truth for /models,
                    # MODE_UNIT, VALID_MODE and the switch HTML). Falls back to a built-in roster if absent.
                    if [[ -f "${SCRIPT_DIR}/server-models.json" ]]; then
                        run_privileged install -d -m 0755 /etc/local-llm
                        if run_privileged install -m 0644 "${SCRIPT_DIR}/server-models.json" /etc/local-llm/server-models.json; then
                            success "Installed /etc/local-llm/server-models.json (daemon roster)"
                        else
                            add_warning "Failed to install /etc/local-llm/server-models.json; daemon will use its built-in fallback roster."
                        fi
                    else
                        add_warning "server-models.json not found next to the installer; daemon will use its built-in fallback roster."
                    fi
                else
                    add_failure "Failed to install vllm-switch-web daemon."
                fi
            else
                add_warning "vllm-switch-web.py not found next to the installer — skipping web switch service."
            fi

            if [[ "$web_daemon_ok" == true ]]; then
            # Passwordless sudo for the service account (same narrow unit whitelist as the CLI switch).
            local sw_sudoers="Defaults:${VLLM_SWITCH_USER} !requiretty
${VLLM_SWITCH_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl start vllm.service, /usr/bin/systemctl stop vllm.service, /usr/bin/systemctl start vllm@coder.service, /usr/bin/systemctl stop vllm@coder.service, /usr/bin/systemctl start vllm@coder-alt.service, /usr/bin/systemctl stop vllm@coder-alt.service, /usr/bin/systemctl start vllm@image.service, /usr/bin/systemctl stop vllm@image.service, /usr/bin/systemctl start imagegen.service, /usr/bin/systemctl stop imagegen.service"
            if printf '%s\n' "$sw_sudoers" | run_privileged tee /etc/sudoers.d/vllm-model-control >/dev/null; then
                run_privileged chmod 0440 /etc/sudoers.d/vllm-model-control
                if run_privileged visudo -c -f /etc/sudoers.d/vllm-model-control >/dev/null 2>&1; then
                    success "Configured passwordless systemctl for $VLLM_SWITCH_USER"
                else
                    run_privileged rm -f /etc/sudoers.d/vllm-model-control
                    add_warning "sudoers validation failed for $VLLM_SWITCH_USER; removed drop-in."
                fi
            else
                add_warning "Could not write sudoers drop-in for $VLLM_SWITCH_USER."
            fi

            # systemd unit. Hardened, but deliberately NOT NoNewPrivileges (would break the sudo switch).
            local sw_unit="[Unit]
Description=vLLM model-switch web service (LAN)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${VLLM_SWITCH_USER}
RuntimeDirectory=vllm-switch-web
Environment=\"VLLM_SWITCH_WEB_PORT=${VLLM_SWITCH_WEB_PORT}\"
Environment=\"VLLM_SWITCH_WEB_BIND=0.0.0.0\"
Environment=\"VLLM_SWITCH_LOCK=/run/vllm-switch-web/switch.lock\"
ExecStart=/usr/bin/python3 /usr/local/bin/vllm-switch-web
Restart=on-failure
RestartSec=5
NoNewPrivileges=no
ProtectHome=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target"
            printf '%s\n' "$sw_unit" | run_privileged tee /etc/systemd/system/vllm-switch-web.service >/dev/null

            # Firewall: mirror the vLLM LAN-allow + non-LAN-deny pattern.
            step "Configure firewall (model-switch port ${VLLM_SWITCH_WEB_PORT})"
            if command_exists ufw; then
                local sw_ufw_status; sw_ufw_status="$(run_privileged ufw status 2>/dev/null || true)"
                if grep -Fq "$LAN_CIDR" <<<"$sw_ufw_status" && grep -Fq "${VLLM_SWITCH_WEB_PORT}" <<<"$sw_ufw_status"; then
                    info "ufw already has a LAN rule for port ${VLLM_SWITCH_WEB_PORT}."
                elif run_privileged ufw allow from "$LAN_CIDR" to any port "${VLLM_SWITCH_WEB_PORT}" proto tcp comment 'vLLM model-switch LAN' >/dev/null; then
                    success "Added ufw allow rule for $LAN_CIDR -> ${VLLM_SWITCH_WEB_PORT}/tcp"
                else
                    add_warning "Could not add ufw allow rule for port ${VLLM_SWITCH_WEB_PORT}."
                fi
                if ! grep -Fq "${VLLM_SWITCH_WEB_PORT}/tcp" <<<"$sw_ufw_status" || ! grep -Fq 'DENY' <<<"$sw_ufw_status"; then
                    if run_privileged ufw deny "${VLLM_SWITCH_WEB_PORT}/tcp" comment 'Block non-LAN model-switch' >/dev/null; then
                        success "Added ufw deny rule for non-LAN access to ${VLLM_SWITCH_WEB_PORT}/tcp"
                    else
                        add_warning "Could not add ufw deny rule for port ${VLLM_SWITCH_WEB_PORT}."
                    fi
                fi
            else
                info "ufw is not installed — skipping model-switch firewall."
            fi

            run_privileged systemctl daemon-reload
            if run_privileged systemctl enable --now vllm-switch-web.service >/dev/null 2>&1; then
                success "Enabled + started vllm-switch-web.service — browser: http://<server-ip>:${VLLM_SWITCH_WEB_PORT}/"
            else
                add_warning "Could not enable/start vllm-switch-web.service."
            fi
            else
                add_warning "Skipping model-switch web service (daemon not installed)."
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
        step "Client mode (squire-only)"
        info "Crush will default to the server (vLLM); switch models with copilot-local or the :4090 browser page."
        [[ -n "$OLLAMA_HOST_ARG" ]] && info "Optional extra remote Ollama provider: $OLLAMA_HOST_ARG"
    fi

    # Client tools (Crush/Copilot/uv/MCP/launchers) — skipped for --install ollama-only.
    if [[ "$SHOULD_INSTALL_CLIENT_TOOLS" == true ]]; then
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

    step "Install csharp-ls (C# language server for Crush LSP)"
    info "crush.json declares a csharp-ls LSP; it is a .NET global tool (dotnet tool install)."
    install_csharp_ls || true

    step "Warm office authoring libraries (uv cache)"
    info "Office authoring uses the 'office' skill: the model writes python-docx/python-pptx/openpyxl"
    info "code and runs it via 'uv run --with ...' — no always-on MCP tool schemas. Priming the uv cache."
    if command_exists uv; then
        if uv run --python 3.12 --with python-docx --with python-pptx --with openpyxl \
            python -c "import docx, pptx, openpyxl" >/dev/null 2>&1; then
            success "Office libraries cached (python-docx, python-pptx, openpyxl)"
        else
            add_warning "Office library warm-up failed. It will resolve on first use via 'uv run --with ...'."
        fi
    else
        add_warning "uv not found — cannot warm office libraries. Install uv first."
    fi
    mkdir -p "$CRUSH_HOME_DIR" "$CRUSH_CONFIG_DIR"
    success "Prepared Crush config directories: ${CRUSH_HOME_DIR} and ${CRUSH_CONFIG_DIR}"

    # ── Deploy Crush configuration ───────────────────────────────────────
    step "Deploy Crush configuration"
    local crush_config_source="${SCRIPT_DIR}/../config/crush.json"
    local crush_config_dest="${CRUSH_CONFIG_DIR}/crush.json"

    if [[ -f "$crush_config_source" ]]; then
        if [[ -f "$crush_config_dest" && "$FORCE" != true ]]; then
            info "Crush config already exists at $crush_config_dest — skipping (won't overwrite). Use --force to refresh."
        else
            if [[ -f "$crush_config_dest" ]]; then
                local crush_backup="${crush_config_dest}.$(date +%Y%m%d-%H%M%S).bak"
                cp "$crush_config_dest" "$crush_backup" && info "Backed up existing crush.json to $crush_backup"
            fi
            # Expand template placeholders for Linux
            local linux_app_data="${HOME}/.local/share"
            # Determine vLLM server IP for the placeholder. Non-server installs (5090 full + server-only
            # client) point at the vLLM server, which is fixed at 192.168.1.99 unless overridden.
            local vllm_ip
            if [[ "$IS_SERVER_MODE" == true ]]; then
                vllm_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' || echo '192.168.1.99')"
            elif [[ "$IS_CLIENT_MODE" == true && -n "$OLLAMA_HOST_ARG" ]]; then
                # Back-compat: derive the squire host from a provided --ollama-host URL.
                vllm_ip="$(echo "$OLLAMA_HOST_ARG" | sed -E 's|https?://||;s|:[0-9]+.*||')"
            else
                vllm_ip="192.168.1.99"
            fi
            # Explicit --squire-server-ip overrides the derived value.
            [[ -n "$SQUIRE_SERVER_IP" ]] && vllm_ip="$SQUIRE_SERVER_IP"
            sed -e "s|__LOCALAPPDATA__|${linux_app_data}|g" \
                -e "s|__VENV_BIN__|bin|g" \
                -e "s|__EXE__||g" \
                -e "s|__EXE_SUFFIX__||g" \
                -e "s|__CONFIG_DIR__|${CRUSH_CONFIG_DIR}|g" \
                -e "s|__SQUIRE_SERVER_IP__|${vllm_ip}|g" \
                "$crush_config_source" > "$crush_config_dest"

            # Prune crush providers + set the default per --providers / --default-provider.
            # 'local' -> the localhost Ollama provider ('ollama'); 'server' -> the vLLM server.
            # Cloud providers (mistral/google/groq/openrouter) are always kept. Single-GPU server hosts
            # one model at a time; every mode also answers to the constant 'active-model' name, so crush
            # addresses 'active-model' and always hits whatever is loaded (no 404 from /model).
            CRUSH_PROVIDERS="$PROVIDERS" CRUSH_DEFAULT="$DEFAULT_PROVIDER" python3 -c "
import json, os
p = '$crush_config_dest'
prov = os.environ['CRUSH_PROVIDERS'].split(',')
default = os.environ['CRUSH_DEFAULT']
with open(p) as f:
    cfg = json.load(f)
providers = cfg['providers']
if 'local' not in prov and 'ollama' in providers:
    del providers['ollama']
if 'server' not in prov and 'server' in providers:
    del providers['server']
if default == 'local':
    cfg['default_provider'] = 'ollama'   # template models.large/small are already the Ollama defaults
else:
    cfg['default_provider'] = 'server'
    cfg['models'] = {
        'large': {'model': 'active-model', 'provider': 'server', 'max_tokens': 8192},
        'small': {'model': 'active-model', 'provider': 'server', 'max_tokens': 8192},
    }
with open(p, 'w') as f:
    json.dump(cfg, f, indent=2)
" 2>/dev/null && info "Crush providers=${PROVIDERS}, default=${DEFAULT_PROVIDER}." || add_warning "Could not apply crush provider selection."

            success "Deployed crush.json to $crush_config_dest"
            if [[ ",$PROVIDERS," == *",server,"* ]]; then
                info "server (vLLM) provider configured at http://${vllm_ip}:${VLLM_PORT}/v1"
            fi
            if [[ "$DEFAULT_PROVIDER" == "local" ]]; then
                info "Default provider: local Ollama. Enabled: ${PROVIDERS} (+ Mistral/Google/Groq/OpenRouter when keys are set)."
            else
                info "Default provider: server (vLLM, active-model = whatever is loaded). Enabled: ${PROVIDERS} (+ Mistral/Google/Groq/OpenRouter when keys are set)."
            fi
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
            info "ComfyUI is an optional general image-gen UI. NOTE: this project's"
            info "image model is HiDream-I1 (served via imagegen.service); FLUX is NOT used"
            info "(it performed worse than HiDream in hands-on testing)."
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
        # Resolve the Squire Server IP for the launcher's [S]/[G]/[C]/[D]/[I] entries.
        # Server install = this box (self). Non-server (5090 full or squire-only client) = the
        # squire-server, fixed at 192.168.1.99 unless overridden by --squire-server-ip/--ollama-host.
        local squire_ip="$SQUIRE_SERVER_IP"
        if [[ -z "$squire_ip" ]]; then
            if [[ "$IS_SERVER_MODE" == true ]]; then
                squire_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' || echo '192.168.1.99')"
            elif [[ "${IS_CLIENT_MODE:-false}" == true && -n "$OLLAMA_HOST_ARG" ]]; then
                squire_ip="$(echo "$OLLAMA_HOST_ARG" | sed -E 's|https?://||;s|:[0-9]+.*||')"
            else
                squire_ip="192.168.1.99"
            fi
            [[ -z "$squire_ip" ]] && squire_ip="192.168.1.99"
        fi
        # Substitute the Squire Server placeholders so the Remote [S]/[C]/[V]/[I] options work.
        sed -e "s|__SQUIRE_SERVER_IP__|${squire_ip}|g" \
            -e "s|__SQUIRE_SSH_TARGET__|${SQUIRE_SSH_TARGET}|g" \
            -e "s|__LL_PROVIDERS__|${PROVIDERS}|g" \
            "$launcher_source" > "$launcher_dest"
        chmod 0755 "$launcher_dest"
        success "Deployed copilot-local to $launcher_dest (server $squire_ip, ssh $SQUIRE_SSH_TARGET)"
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
        # Substitute the provider gating + Squire Server placeholders so the Remote [S/G/C/D/I]
        # server group works. Reuses $squire_ip resolved by the copilot-local deploy above.
        sed -e "s|__SQUIRE_SERVER_IP__|${squire_ip:-192.168.1.99}|g" \
            -e "s|__LL_PROVIDERS__|${PROVIDERS}|g" \
            "$crush_task_source" > "$crush_task_dest"
        chmod 0755 "$crush_task_dest"
        success "Deployed crush-task to $crush_task_dest (providers $PROVIDERS, server ${squire_ip:-192.168.1.99})"
        info "Usage: crush-task (from any directory)"
    else
        warn "crush-task script not found at $crush_task_source — skipping."
    fi

    # ── Generate the local model roster the launchers read ────────────────
    # Written whenever the launchers present local Ollama entries (providers include 'local').
    if [[ ",$PROVIDERS," == *",local,"* ]]; then
        step "Generate local model roster (local-models.json)"
        write_local_models_json
    fi

    # ── Deploy the server roster fallback (launchers' offline server page) ─
    if [[ ",$PROVIDERS," == *",server,"* ]]; then
        step "Deploy server model roster fallback"
        local server_roster_src="${SCRIPT_DIR}/server-models.json"
        local server_roster_dst="${HOME}/.config/local-llm/server-models.json"
        if [[ -f "$server_roster_src" ]]; then
            mkdir -p "$(dirname "$server_roster_dst")"
            cp "$server_roster_src" "$server_roster_dst"
            success "Deployed server roster fallback to $server_roster_dst"
        else
            warn "server-models.json not found at $server_roster_src; server page will rely on the live :4090/models endpoint."
        fi
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

    # Deploy local skills from dotFiles (includes the vendored 'office' authoring skill)
    local skills_source_dir="${SCRIPT_DIR}/../config/skills"
    local skills_dest_dir="${CRUSH_CONFIG_DIR}/skills"
    if [[ -d "$skills_source_dir" ]]; then
        mkdir -p "$skills_dest_dir"
        cp -r "$skills_source_dir"/* "$skills_dest_dir"/
        success "Deployed local skills (git-safety, office) to $skills_dest_dir"

        # Copilot discovers skills from ~/.copilot/skills (NOT the crush dir, and its custom-instructions
        # loader ignores SKILL.md) — deploy the 'office' skill there so Copilot sees it in every session.
        if [[ -d "${skills_source_dir}/office" ]]; then
            local copilot_skills_office="${HOME}/.copilot/skills/office"
            mkdir -p "$copilot_skills_office"
            cp -r "${skills_source_dir}/office"/* "$copilot_skills_office"/
            success "Deployed 'office' skill to $copilot_skills_office (Copilot personal skills)"
        fi
    fi

    # ── Deploy Copilot CLI MCP configuration ──────────────────────────────
    step "Deploy Copilot CLI MCP configuration"
    local copilot_mcp_source="${SCRIPT_DIR}/../config/copilot-mcp-config.json"
    local copilot_dir="${HOME}/.copilot"
    local copilot_mcp_dest="${copilot_dir}/mcp-config.json"

    if [[ -f "$copilot_mcp_source" ]]; then
        mkdir -p "$copilot_dir"
        if [[ -f "$copilot_mcp_dest" && "$FORCE" != true ]]; then
            info "Copilot MCP config already exists at $copilot_mcp_dest — skipping (won't overwrite). Use --force to refresh."
        else
            if [[ -f "$copilot_mcp_dest" ]]; then
                local copilot_mcp_backup="${copilot_mcp_dest}.$(date +%Y%m%d-%H%M%S).bak"
                cp "$copilot_mcp_dest" "$copilot_mcp_backup" && info "Backed up existing mcp-config.json to $copilot_mcp_backup"
            fi
            local linux_app_data="${HOME}/.local/share"
            sed -e "s|__LOCALAPPDATA__|${linux_app_data}|g" \
                -e "s|__VENV_BIN__|bin|g" \
                -e "s|__EXE__||g" \
                -e "s|__EXE_SUFFIX__||g" \
                -e "s|__CONFIG_DIR__|${CRUSH_CONFIG_DIR}|g" \
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
    else
        info "Skipping client tools (--no-client-tools): installing the local Ollama server + models only."
    fi
fi

if [[ "$SHOULD_PULL_MODELS" == true ]]; then
    if [[ "$IS_SERVER_MODE" == true ]]; then
        # ── vLLM: Download models from HuggingFace ──────────────────────
        step "Download HuggingFace models for vLLM"
        info "$MODEL_SOURCE_MESSAGE"
        info "This will download about ${EFFECTIVE_MODEL_REQUIRED_GB} GB. Downloads are resumable."

        VLLM_VENV="${HOME}/.local/share/vllm-env"
        HF_CLI="${VLLM_VENV}/bin/hf"

        if [[ ! -x "$HF_CLI" ]]; then
            add_failure "hf CLI not found at $HF_CLI — install vLLM first."
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

            # Download HiDream-O1-Image-Dev for image generation
            echo
            printf '%b\n' "${COLOR_GRAY}  Downloading HiDream-ai/HiDream-O1-Image-Dev (image generation)${COLOR_RESET}"
            info "HiDream-O1-Image-Dev — high-quality image generation (28 steps), ~35 GB"
            if "$HF_CLI" download "HiDream-ai/HiDream-O1-Image-Dev" --quiet; then
                success "HiDream-O1-Image-Dev ready."
            else
                add_warning "HiDream-O1-Image-Dev download failed — image gen will not work until downloaded."
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
                        if "$OLLAMA_BIN" show "$tag" >/dev/null 2>&1; then
                            info "  ${tag} already present — skipping pull."
                            continue
                        fi
                        printf '%b\n' "${COLOR_GRAY}  Pulling ${tag}${COLOR_RESET}"
                        info "$(model_description "$tag")"
                        if "$OLLAMA_BIN" pull "$tag"; then
                            success "$tag ready."
                        else
                            add_failure "Model pull failed: $tag"
                        fi
                    done

                    # Bake num_ctx on the image-companion base (Ollama defaults to 2048).
                    printf '%b\n' "${COLOR_GRAY}  Setting context window (num_ctx) on base models...${COLOR_RESET}"
                    local -A num_ctx_settings=(
                        ["qwen3:8b"]=32768
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

                    # Create named alias models used by launcher scripts, from the tier roster.
                    printf '%b\n' "${COLOR_GRAY}  Creating launcher model aliases (${OLLAMA_TIER} tier)...${COLOR_RESET}"
                    for alias_name in "${!OLLAMA_ALIAS_FROM[@]}"; do
                        local from="${OLLAMA_ALIAS_FROM[$alias_name]}"
                        local ctx="${OLLAMA_ALIAS_CTX[$alias_name]}"
                        local tmpl="${OLLAMA_ALIAS_TEMPLATE[$alias_name]:-}"
                        # Skip aliases whose base tag was not pulled successfully.
                        if ! "$OLLAMA_BIN" show "$from" >/dev/null 2>&1; then
                            add_warning "Base model $from missing — skipping alias $alias_name."
                            continue
                        fi
                        local modelfile_tmp
                        modelfile_tmp="$(mktemp)"
                        printf 'FROM %s\nPARAMETER num_ctx %s\n' "$from" "$ctx" > "$modelfile_tmp"
                        if [[ -n "$tmpl" ]]; then
                            # Bake an explicit ChatML template (qwen3-next's embedded template mis-renders).
                            printf 'TEMPLATE """%s"""\n' "$tmpl" >> "$modelfile_tmp"
                        fi
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
case "$MODE" in
    full)   printf '%b\n' "Install mode: local (Ollama)" ;;
    server) printf '%b\n' "Install mode: server (vLLM)" ;;
    client) printf '%b\n' "Install mode: client (no local engine)" ;;
esac
printf '%b\n' "Ollama roster: ${OLLAMA_TIER_LABEL}"

if [[ "$SHOULD_INSTALL_SOFTWARE" == true ]]; then
    echo
    printf '%b\n' 'Installed / prepared:'
    [[ "$IS_FULL_MODE" == true ]] && printf '%b\n' '  • NVIDIA drivers + CUDA (system)'
    if [[ "$IS_SERVER_MODE" == true ]]; then
        printf '%b\n' '  • vLLM + imagegen (system services)'
    elif [[ "$IS_FULL_MODE" == true ]]; then
        printf '%b\n' '  • Ollama (system service)'
    fi
    printf '%b\n' '  • uv + Python (user-local / uv-managed)'
    printf '%b\n' '  • Crush (CLI agent)'
    printf '%b\n' "  • ${AI_TOOLS_DIR}/mcp-*"
    printf '%b\n' "  • ${CRUSH_HOME_DIR} and ${CRUSH_CONFIG_DIR}"
    [[ -n "$MODEL_PATH" && "$IS_FULL_MODE" == true ]] && printf '%b\n' "  • Custom model path: ${MODEL_PATH}"
fi

if [[ "$IS_CLIENT_MODE" == true ]]; then
    echo
    printf '%b\n' 'Next steps:'
    printf '%b\n' "  1. Run 'crush' — it defaults to the server (vLLM); switch models with 'copilot-local' (or http://<server>:4090/)"
    printf '%b\n' "  2. Verify the server: curl http://${SQUIRE_SERVER_IP:-192.168.1.99}:8000/v1/models"
    printf '%b\n' '  3. Create MCP venvs under ~/.local/share/ai-tools as needed'
elif [[ "$IS_SERVER_MODE" == true ]]; then
    # Detect LAN IP for client connection instructions
    local_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' || hostname -I 2>/dev/null | awk '{print $1}' || echo '<this-server-ip>')"
    echo
    printf '%b\n' "${COLOR_CYAN}── Client Access (vLLM) ───────────────────────────────────────${COLOR_RESET}"
    printf '%b\n' ""
    printf '%b\n' "  vLLM API:    http://${local_ip}:${VLLM_PORT}/v1"
    printf '%b\n' "  Image Gen:   http://${local_ip}:8001/v1/images/generations"
    printf '%b\n' "  Model Switch: http://${local_ip}:${VLLM_SWITCH_WEB_PORT}/  (browser button page — no login)"
    printf '%b\n' "  Firewall:    ufw allow from ${LAN_CIDR} to port ${VLLM_PORT},8001,${VLLM_SWITCH_WEB_PORT}/tcp"
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
    printf '%b\n' "  Switch model (one mode at a time — Mistral is the standing default):"
    printf '%b\n' "    Browser (any LAN device, no login):  http://${local_ip}:${VLLM_SWITCH_WEB_PORT}/"
    printf '%b\n' "    CLI on server:  cachyos-switch-model mistral | coder | coder-alt | image"
    printf '%b\n' ""
    printf '%b\n' "${COLOR_CYAN}──────────────────────────────────────────────────────────────${COLOR_RESET}"
    echo
    printf '%b\n' 'Next steps:'
    printf '%b\n' "  1. Enable the default on boot: sudo systemctl enable --now vllm"
    printf '%b\n' "     (Do NOT enable imagegen — single GPU; it is on-demand via 'cachyos-switch-model image'.)"
    printf '%b\n' "  2. Verify vLLM: curl http://127.0.0.1:${VLLM_PORT}/v1/models"
    printf '%b\n' "  3. Image gen (on demand): cachyos-switch-model image  then  curl http://127.0.0.1:8001/health"
    printf '%b\n' "  4. Verify from LAN: curl http://${local_ip}:${VLLM_PORT}/v1/models"
    printf '%b\n' "  5. Switch models from any LAN device: http://${local_ip}:${VLLM_SWITCH_WEB_PORT}/  (or 'copilot-local')"
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
}

main "$@"
