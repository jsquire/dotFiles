#!/usr/bin/env bash
# crush-task — Task picker for Crush with MCP profile management
#
# Writes a project-level .crush.json with the right MCP servers enabled
# for the selected task, then launches Crush.
#
# Profiles:
#   coding  — no MCP servers (code tools + LSP only)
#   review  — Qwen3-Coder model, no MCP (different perspective)
#   docs    — office authoring (docx/pptx/xlsx) via the 'office' skill: the model writes
#             python-docx/python-pptx/openpyxl and runs it with uv (no document MCP servers)
#   image   — imagegen-mcp (image generation)
set -euo pipefail

# ── Provider gating (local Ollama / remote squire-server) ─────────────────────
# Baked in by the installer; falls back to both if the placeholder was not substituted.
LL_PROVIDERS="__LL_PROVIDERS__"
[[ "$LL_PROVIDERS" == *"__"* || -z "$LL_PROVIDERS" ]] && LL_PROVIDERS="local,server"
_ll_has() { [[ ",${LL_PROVIDERS}," == *",$1,"* ]]; }

# Switch the squire-server's active model via the accountless web endpoint (:4090). The server
# loads one model at a time, so POST the mode then poll /status until it is loaded before launching
# Crush (so we never hand Crush a not-yet-ready model).
squire_switch() {
    local mode="$1" ip="__SQUIRE_SERVER_IP__" port="4090" i st
    if ! curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
            -d "{\"mode\":\"${mode}\"}" "http://${ip}:${port}/switch" >/dev/null 2>&1; then
        echo "  WARN: could not reach the model-switch service at http://${ip}:${port}/ - is the server up?"
        return 0
    fi
    printf '  ... switching server to %s' "$mode"
    for i in $(seq 1 30); do
        st="$(curl -fsS -m 5 "http://${ip}:${port}/status" 2>/dev/null || true)"
        if [[ "$st" == *"\"mode\": \"${mode}\""* && "$st" == *'"api_up": true'* ]]; then
            echo " - ready."
            return 0
        fi
        printf '.'
        sleep 3
    done
    echo " (still loading; give it a few more seconds)"
}

write_crush_config() {
    local imagegen_disabled="$1"
    local system_prompt="${2:-}"
    local model_override="${3:-}"
    local provider="${4:-ollama}"
    local active_label="${5:-}"   # server mode: friendly label for the single 'active-model' entry

    local providers_block=""
    local models_block=""

    # Output cap + context window. For the server provider these come from the advertised roster
    # (SRV_CTX / SRV_MAX, set by the picker from :4090/models); local Ollama runs roomy windows so a
    # fixed cap is cheap.
    local max_tok=16384 ctx_win=65536
    if [[ "$provider" == "server" ]]; then
        ctx_win="${SRV_CTX:-32768}"; max_tok="${SRV_MAX:-8192}"
    fi

    # Point the imagegen MCP tool at the selected environment's image server: local -> localhost,
    # server -> the squire-server (so image generation follows the task context, not a baked host).
    local imagegen_host="127.0.0.1"
    [[ "$provider" == "server" ]] && imagegen_host="$SQUIRE_IP"

    # Per-provider override. For the server provider we expose ONE 'active-model' entry (so crush's
    # /model can never pick a not-yet-loaded model), and relabel it "Active: <model>" for visibility.
    local prov_inner=""
    if [[ -n "$active_label" ]]; then
        prov_inner="\"models\": [
        { \"name\": \"Active: ${active_label}\", \"id\": \"active-model\", \"context_window\": ${ctx_win}, \"default_max_tokens\": ${max_tok} }
      ]"
    fi
    if [[ -n "$system_prompt" ]]; then
        local sp_json
        sp_json="$(printf '%s' "$system_prompt" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')"
        if [[ -n "$prov_inner" ]]; then
            prov_inner="${prov_inner},
      \"system_prompt_prefix\": ${sp_json}"
        else
            prov_inner="\"system_prompt_prefix\": ${sp_json}"
        fi
    fi
    if [[ -n "$prov_inner" ]]; then
        providers_block=",
  \"providers\": {
    \"${provider}\": {
      ${prov_inner}
    }
  }"
    fi
    if [[ -n "$model_override" ]]; then
        models_block=",
  \"models\": {
    \"large\": {
      \"model\": \"${model_override}\",
      \"provider\": \"${provider}\",
      \"max_tokens\": ${max_tok}
    },
    \"small\": {
      \"model\": \"${model_override}\",
      \"provider\": \"${provider}\",
      \"max_tokens\": ${max_tok}
    }
  }"
    fi

    cat > .crush.json <<EOF
{
  "mcp": {
    "imagegen-mcp": { "disabled": ${imagegen_disabled}, "env": { "IMAGEGEN_URL": "http://${imagegen_host}:8001" } }
  }${providers_block}${models_block}
}
EOF
}

task="${1:-}"
SELECTED_MODEL=""
OFFLOAD_MODE=0
PROVIDER="ollama"
SWITCH_MODE=""
SRV_IMG=""
SEL_LABEL=""
SRV_CTX=""
SRV_MAX=""

# ── Data-driven model roster ─────────────────────────────────────────────────
# Local models come from local-models.json (installer-generated per GPU tier; replaces the old
# ollama-tier.sh). Server models are advertised live by the switch daemon at :4090/models, with a
# bundled server-models.json as the offline fallback. Both are read via python3 (no jq dependency).
LL_CONFIG_DIR="${HOME}/.config/local-llm"
_ll_self_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
LL_MODELS_FILE=""
for _c in "${LL_MODELS_FILE:-}" "${LL_CONFIG_DIR}/local-models.json" "${_ll_self_dir}/local-models.json"; do
    [[ -n "$_c" && -f "$_c" ]] && { LL_MODELS_FILE="$_c"; break; }
done
if [[ -z "$LL_MODELS_FILE" ]]; then
    echo "  ERROR: local-models.json not found (looked in ${LL_CONFIG_DIR}/ and beside the launcher)." >&2
    exit 1
fi
LL_SERVER_FALLBACK="${LL_CONFIG_DIR}/server-models.json"
SQUIRE_IP="__SQUIRE_SERVER_IP__"

# python worker over the local roster ($LL_MODELS_FILE). Subcommands: page/resolve/alias/label/tier.
_ll() {
    LL_FILE="$LL_MODELS_FILE" python3 - "$@" <<'PY'
import json, os, sys
d = json.load(open(os.environ["LL_FILE"]))
reg = d.get("registry", {}); ta = d.get("task_alias", {})
cmd = sys.argv[1]
def alias_of(r): return ta.get(r.get("slot", ""), r.get("slot", ""))
def detail(r):
    if "detail" in r: return r["detail"]
    return alias_of(r) + ((" " + r["note"]) if r.get("note") else "")
def cats(launcher, which):
    return d.get("launchers", {}).get(launcher, {}).get(which, {}).get("categories", [])
if cmd == "page":
    for c in cats(sys.argv[2], sys.argv[3]):
        print("CAT\x1f%s\x1f%s" % (c.get("heading", ""), c.get("subtitle", "")))
        for r in c["rows"]:
            print("ROW\x1f%s\x1f%s\x1f%s" % (r["key"], r["label"], detail(r)))
elif cmd == "resolve":
    key = sys.argv[4]
    for c in cats(sys.argv[2], sys.argv[3]):
        for r in c["rows"]:
            if r["key"] == key:
                flags = ",".join(f for f in ("office", "imagegen", "offload") if r.get(f))
                print("%s\x1f%s\x1f%s" % (alias_of(r), flags, r.get("profile", "")))
                sys.exit(0)
    sys.exit(1)
elif cmd == "alias":
    print(ta.get(sys.argv[2], sys.argv[2]))
elif cmd == "label":
    print(reg.get(sys.argv[2], {}).get("label", sys.argv[2]))
elif cmd == "tier":
    print(d.get("tier", ""))
PY
}
_alias() { _ll alias "$1"; }
_ll_label() { _ll label "$1"; }

# Model assignments per task profile (tier-resolved) — used by the direct `crush-task <task>` path.
model_for_task() {
    case "$1" in
        coding)   _alias heavy ;;
        review)   _alias review ;;
        docs)     _alias agentic ;;
        image)    _alias image_llm ;;
        *)        _alias heavy ;;
    esac
}

# Fetch the server roster: live from the switch daemon, else the bundled fallback file.
_srv_json() {
    local out
    out="$(curl -fsS -m 2 "http://${SQUIRE_IP}:4090/models" 2>/dev/null || true)"
    if [[ -n "$out" ]]; then printf '%s' "$out"; return 0; fi
    [[ -f "$LL_SERVER_FALLBACK" ]] && { cat "$LL_SERVER_FALLBACK"; return 0; }
    return 1
}
# python worker over a server roster JSON string ($1). Subcommands: page/resolve.
_srv() {
    SRV_JSON="$1" python3 - "${@:2}" <<'PY'
import json, os, sys
d = json.loads(os.environ["SRV_JSON"]); modes = d.get("modes", [])
cmd = sys.argv[1]
if cmd == "page":
    for m in modes:
        print("ROW\x1f%s\x1f%s\x1f%s" % (m["key"], m["label"], m.get("task", "")))
elif cmd == "resolve":
    for m in modes:
        if m["key"] == sys.argv[2]:
            print("\x1f".join(str(x) for x in (
                m["mode"], m["label"], m["model_id"], m["ctx"],
                m["max_output"], m["max_prompt"], int(bool(m.get("imagegen_disabled", True))))))
            sys.exit(0)
    sys.exit(1)
PY
}

if [[ -z "$task" ]]; then
    W=110
    ESC=$'\033'; FRAME="${ESC}[38;5;25m"; TEXT="${ESC}[97m"; RST="${ESC}[0m"
    bar=$(printf '═%.0s' $(seq 1 $W))
    box_top() { printf '  %s╔%s╗%s\n' "$FRAME" "$bar" "$RST"; }
    box_mid() { printf '  %s╠%s╣%s\n' "$FRAME" "$bar" "$RST"; }
    box_bot() { printf '  %s╚%s╝%s\n' "$FRAME" "$bar" "$RST"; }
    box_line() { printf '  %s║%s%-*.*s%s║%s\n' "$FRAME" "$TEXT" "$W" "$W" "$1" "$FRAME" "$RST"; }
    box_center() { local s="$1"; local p=$(( (W - ${#s}) / 2 )); (( p < 0 )) && p=0; box_line "$(printf '%*s%s' "$p" '' "$s")"; }
    box_row() { box_line "$(printf '       %-5s %-26.26s %s' "[$1]" "$2" "$3")"; }
    rule() { box_line "     $(printf -- '-%.0s' $(seq 1 "$1"))"; }
    render_local() {
        local which="$1" typ a b c first=1 ulen
        box_line ""
        while IFS=$'\x1f' read -r typ a b c; do
            case "$typ" in
                CAT)
                    if [[ $first -eq 0 ]]; then box_line ""; box_line ""; fi
                    first=0
                    box_line "     $a"
                    if [[ -n "$b" ]]; then box_line "         $b"; ulen=$(( ${#b} + 4 )); else ulen=${#a}; fi
                    rule "$ulen"; box_line ""
                    ;;
                ROW) box_row "$a" "$b" "$c" ;;
            esac
        done < <(_ll page crush "$which")
        box_line ""; box_line ""; box_line ""
        box_row "B" "Back to environments" ""; box_row "Q" "Quit" ""; box_line ""
    }
    LL_TIER="$(_ll tier)"
    has_local=false; has_server=false
    _ll_has local && has_local=true
    _ll_has server && has_server=true
    menuerr=""; SRVJSON=""; pg_which=""; res=""; sres=""; s_sub=""
    if $has_local; then page=env; else page=server; fi
    while true; do
        clear; echo
        case "$page" in
            env)
                box_top; box_center "Crush"; box_line ""; box_center "pick an environment"; box_mid
                box_line ""
                box_line "     [1]  Local"; box_line "          Production daily-drivers"; box_line ""
                box_line "     [2]  Local - Experimental"; box_line "          Models under evaluation"
                if $has_server; then box_line ""; box_line "     [3]  Squire-Server"; box_line "          Models hosted on the server"; fi
                box_line ""; box_line ""; box_line "     [Q]  Quit"; box_line ""; box_bot; echo
                [ -n "$menuerr" ] && { echo "   $menuerr"; menuerr=""; }
                read -rp "   Your choice [1]: " sel; sel="${sel:-1}"
                case "${sel^^}" in
                    1) page=local ;;
                    2) page=exp ;;
                    3) if $has_server; then page=server; else menuerr="Invalid selection, try again."; fi ;;
                    Q) clear; exit 0 ;;
                    *) menuerr="Invalid selection, try again." ;;
                esac
                ;;
            local|exp)
                [[ "$page" == "local" ]] && pg_which=production || pg_which=experimental
                box_top; box_center "Crush"; box_line ""
                if [[ "$page" == "local" ]]; then box_center "local : production models"
                else box_center "local : models under evaluation (${LL_TIER} tier)"; fi
                box_mid
                render_local "$pg_which"
                box_bot; echo
                [ -n "$menuerr" ] && { echo "   $menuerr"; menuerr=""; }
                read -rp "   Your choice [1]: " sel; sel="${sel:-1}"
                if [[ "${sel^^}" == "Q" ]]; then clear; exit 0; fi
                if [[ "${sel^^}" == "B" ]]; then page=env; continue; fi
                if res="$(_ll resolve crush "$pg_which" "$sel")"; then
                    IFS=$'\x1f' read -r a_alias a_flags a_profile <<<"$res"
                    task="$a_profile"; SELECTED_MODEL="$a_alias"; PROVIDER="ollama"
                    SEL_LABEL="$(_ll_label "$a_alias")"
                    [[ ",$a_flags," == *",offload,"* ]] && OFFLOAD_MODE=1 || OFFLOAD_MODE=0
                    break
                fi
                menuerr="Invalid selection, try again."
                ;;
            server)
                [[ -z "$SRVJSON" ]] && SRVJSON="$(_srv_json || true)"
                if [[ -z "$SRVJSON" ]]; then
                    clear; echo "  ERROR: could not reach the server model list at :4090/models and no fallback file found." >&2
                    exit 1
                fi
                box_top; box_center "Crush"; box_line ""; box_center "squire-server : remote models"; box_mid
                box_line ""
                s_sub="(server - switches the standing model on pick)"
                box_line "     Remote"; box_line "         $s_sub"; rule $(( ${#s_sub} + 4 )); box_line ""
                while IFS=$'\x1f' read -r typ k l t; do [[ "$typ" == "ROW" ]] && box_row "$k" "$l" "$t"; done < <(_srv "$SRVJSON" page)
                box_line ""; box_line ""; box_line ""
                if $has_local; then box_row "B" "Back to environments" ""; fi
                box_row "Q" "Quit" ""; box_line ""
                box_bot; echo
                [ -n "$menuerr" ] && { echo "   $menuerr"; menuerr=""; }
                read -rp "   Your choice [1]: " sel; sel="${sel:-1}"
                if [[ "${sel^^}" == "Q" ]]; then clear; exit 0; fi
                if [[ "${sel^^}" == "B" ]] && $has_local; then page=env; continue; fi
                if sres="$(_srv "$SRVJSON" resolve "$sel")"; then
                    IFS=$'\x1f' read -r s_mode s_label s_id s_ctx s_out s_prompt s_imgoff <<<"$sres"
                    PROVIDER="server"; SWITCH_MODE="$s_mode"; SELECTED_MODEL="$s_id"; SEL_LABEL="$s_label"
                    [[ "$s_imgoff" == "1" ]] && SRV_IMG=true || SRV_IMG=false
                    SRV_CTX="$s_ctx"; SRV_MAX="$s_out"
                    break
                fi
                menuerr="Invalid selection, try again."
                ;;
        esac
    done
fi

# Resolve model: explicit picker selection wins, else per-task default.
if [[ -z "$SELECTED_MODEL" ]]; then SELECTED_MODEL="$(model_for_task "$task")"; fi
DEFAULT_MODEL="$SELECTED_MODEL"
REVIEW_MODEL="$SELECTED_MODEL"

# Friendly label for the launch-identity banner: the picker's selection wins; otherwise resolve
# the alias against the roster (the direct `crush-task <task>` path).
MODEL_FRIENDLY="${SEL_LABEL:-$(_ll_label "$DEFAULT_MODEL")}"
echo
echo "  ▶ $MODEL_FRIENDLY  ·  alias=$DEFAULT_MODEL"

if [[ "$PROVIDER" == "server" ]]; then
    [[ -n "$SWITCH_MODE" ]] && squire_switch "$SWITCH_MODE"
    write_crush_config "$SRV_IMG" "" "active-model" "server" "$SELECTED_MODEL"
    echo "  Profile: squire-server ($SELECTED_MODEL, addressed as active-model)"
else
case "$task" in
    coding)
        write_crush_config true "" "$DEFAULT_MODEL"
        echo "  Profile: Coding ($DEFAULT_MODEL, no MCP servers)"
        ;;
    review)
        REVIEW_GUIDE="You are a code reviewer. Focus on:
- Bugs, logic errors, and edge cases
- Security vulnerabilities (injection, auth, data exposure)
- Performance issues (N+1 queries, unnecessary allocations, blocking calls)
- API contract violations and type mismatches
- Concurrency issues (race conditions, deadlocks)
Do NOT comment on style, formatting, or naming conventions unless they cause bugs.
Be direct. If the code is correct, say so briefly."
        write_crush_config true "$REVIEW_GUIDE" "$REVIEW_MODEL"
        echo "  Profile: Code review (Qwen3-Coder 30B)"
        ;;
    docs)
        # Office authoring uses the vendored 'office' skill (discovered natively by crush from
        # ~/.config/crush/skills/office). The model writes python-docx/python-pptx/openpyxl and
        # runs it via `uv run --with ...` — no document MCP servers, near-zero context cost.
        write_crush_config true "" "$DEFAULT_MODEL"
        echo "  Profile: Documents / office authoring ($DEFAULT_MODEL + office skill: docx/pptx/xlsx via Python)"
        ;;
    image)
        write_crush_config false "" "$SELECTED_MODEL"
        echo "  Profile: Image generation (HiDream) — using $SELECTED_MODEL for VRAM headroom"
        ;;
    *)
        echo "  Unknown profile '$task', defaulting to coding."
        write_crush_config true "" "$DEFAULT_MODEL"
        echo "  Profile: Coding ($DEFAULT_MODEL, no MCP servers)"
        ;;
esac
fi

echo "  Config: $(pwd)/.crush.json"
echo

if [[ "$OFFLOAD_MODE" == "1" ]]; then
    # Big-MoE offload mode: run a dedicated Ollama serve with expert CPU-offload, then
    # restore the managed server when Crush exits.
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=offload-serve.sh
    source "$SCRIPT_DIR/offload-serve.sh"
    echo "  Offload mode: experts -> system RAM (partial; slower than VRAM-resident)"
    offload_start 24
    trap 'offload_stop' EXIT
    crush
else
    exec crush
fi
