#!/usr/bin/env bash
# copilot-local — Launch GitHub Copilot CLI with local Ollama models
set -euo pipefail

# Which provider groups this install enabled (baked in by the installer). Falls back to both.
LL_PROVIDERS="__LL_PROVIDERS__"
[[ "$LL_PROVIDERS" == *"__"* || -z "$LL_PROVIDERS" ]] && LL_PROVIDERS="local,server"
_ll_has() { [[ ",${LL_PROVIDERS}," == *",$1,"* ]]; }

export COPILOT_PROVIDER_MAX_PROMPT_TOKENS=51200
export COPILOT_PROVIDER_MAX_OUTPUT_TOKENS=16384

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

# python worker over the local roster ($LL_MODELS_FILE). Subcommands: page/keys/resolve/label.
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
elif cmd == "label":
    print(reg.get(sys.argv[2], {}).get("label", sys.argv[2]))
elif cmd == "tier":
    print(d.get("tier", ""))
PY
}
model_label() { _ll label "$1"; }

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

# Switch the Squire server's active model via the accountless web endpoint (:4090) — no SSH account
# needed. The server loads one model at a time, so we POST the desired mode then poll /status until it
# is loaded (bounded), so the client isn't launched against a not-yet-ready model.
squire_switch() {
    local mode="$1" ip="__SQUIRE_SERVER_IP__" port="4090" i st
    if ! curl -fsS -m 10 -X POST -H 'Content-Type: application/json' \
            -d "{\"mode\":\"${mode}\"}" "http://${ip}:${port}/switch" >/dev/null 2>&1; then
        echo "  ⚠  Could not reach the model-switch service at http://${ip}:${port}/ — is the server up?"
        return 0
    fi
    printf '  ⋯ switching server to %s' "$mode"
    for i in $(seq 1 30); do
        st="$(curl -fsS -m 5 "http://${ip}:${port}/status" 2>/dev/null || true)"
        if [[ "$st" == *"\"mode\": \"${mode}\""* && "$st" == *'"api_up": true'* ]]; then
            echo " — ready."
            return 0
        fi
        printf '.'
        sleep 3
    done
    echo " (still loading; give it a few more seconds)"
}

# If a model was passed as first argument (contains ':'), use it directly
if [[ "${1:-}" == *":"* ]]; then
    COPILOT_MODEL="$1"
    shift
    echo "  ▶ $(model_label "$COPILOT_MODEL")  ·  alias=$COPILOT_MODEL"
    export COPILOT_PROVIDER_BASE_URL="http://localhost:11434/v1"
    exec copilot --model "$COPILOT_MODEL" "$@"
fi

# No model specified — show the two-level environment picker (colour box UI, data-driven).
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

# Render a data-driven local page (production|experimental) with computed underlines + spacing.
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
    done < <(_ll page copilot "$which")
    box_line ""; box_line ""; box_line ""
    box_row "B" "Back to environments" ""; box_row "Q" "Quit" ""; box_line ""
}

LL_TIER="$(_ll tier)"
has_local=false; has_server=false
_ll_has local && has_local=true
_ll_has server && has_server=true
SEL_MODEL=""; SEL_LABEL=""; SEL_TAG=""; SEL_IMAGEGEN=0; SEL_OFFICE=0; OFFLOAD_MODE=0; SEL_REMOTE=0
menuerr=""; SRVJSON=""; pg_which=""; res=""; sres=""; s_sub=""
if $has_local; then page=env; else page=server; fi
while true; do
    clear; echo
    case "$page" in
        env)
            box_top; box_center "Copilot Local"; box_line ""; box_center "pick an environment"; box_mid
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
            box_top; box_center "Copilot Local"; box_line ""
            if [[ "$page" == "local" ]]; then box_center "local : production models"
            else box_center "local : models under evaluation (${LL_TIER} tier)"; fi
            box_mid
            render_local "$pg_which"
            box_bot; echo
            [ -n "$menuerr" ] && { echo "   $menuerr"; menuerr=""; }
            read -rp "   Your choice [1]: " sel; sel="${sel:-1}"
            if [[ "${sel^^}" == "Q" ]]; then clear; exit 0; fi
            if [[ "${sel^^}" == "B" ]]; then page=env; continue; fi
            if res="$(_ll resolve copilot "$pg_which" "$sel")"; then
                IFS=$'\x1f' read -r a_alias a_flags a_profile <<<"$res"
                export COPILOT_MODEL="$a_alias"
                SEL_MODEL="$a_alias"; SEL_LABEL="$(_ll label "$a_alias")"; SEL_REMOTE=0
                [[ ",$a_flags," == *",imagegen,"* ]] && SEL_IMAGEGEN=1 || SEL_IMAGEGEN=0
                [[ ",$a_flags," == *",office,"* ]] && SEL_OFFICE=1 || SEL_OFFICE=0
                [[ ",$a_flags," == *",offload,"* ]] && OFFLOAD_MODE=1 || OFFLOAD_MODE=0
                [[ "$page" == "exp" ]] && SEL_TAG="[$sel] experimental" || SEL_TAG="[$sel] task profile"
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
            box_top; box_center "Copilot Local"; box_line ""; box_center "squire-server : remote models"; box_mid
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
                squire_switch "$s_mode"
                export COPILOT_PROVIDER_BASE_URL="http://${SQUIRE_IP}:8000/v1"
                export COPILOT_MODEL="$s_id"
                export COPILOT_PROVIDER_MAX_PROMPT_TOKENS="$s_prompt"
                export COPILOT_PROVIDER_MAX_OUTPUT_TOKENS="$s_out"
                SEL_MODEL="$s_id"; SEL_LABEL="$s_label"; SEL_REMOTE=1; SEL_TAG="[$sel] squire-server"
                SEL_IMAGEGEN=$(( s_imgoff == 0 ? 1 : 0 )); SEL_OFFICE=0
                break
            fi
            menuerr="Invalid selection, try again."
            ;;
    esac
done
# ── Finalise flags from the selection ────────────────────────────────────────
# MCP: imagegen-mcp stays enabled only for image profiles; off elsewhere.
if [[ "$SEL_IMAGEGEN" == "1" ]]; then MCP_FLAGS=(); else MCP_FLAGS=(--disable-mcp-server imagegen-mcp); fi

# Point the imagegen MCP tool at the selected environment's image server (the mcp-config expands
# ${COPILOT_MCP_IMAGEGEN_HOST}): local -> localhost, server -> the squire-server.
if [[ "$SEL_REMOTE" == "1" ]]; then export COPILOT_MCP_IMAGEGEN_HOST="$SQUIRE_IP"; else export COPILOT_MCP_IMAGEGEN_HOST="127.0.0.1"; fi

# Git safety: block git write operations
GIT_SAFETY=(
    --deny-tool='shell(git add)' --deny-tool='shell(git commit)'
    --deny-tool='shell(git push)' --deny-tool='shell(git merge)'
    --deny-tool='shell(git rebase)' --deny-tool='shell(git reset)'
    --deny-tool='shell(git stash)' --deny-tool='shell(git cherry-pick)'
    --deny-tool='shell(git revert)' --deny-tool='shell(git tag)'
)

# Office authoring guidance: point Copilot at the vendored 'office' skill dir via
# COPILOT_CUSTOM_INSTRUCTIONS_DIRS (Copilot loads custom-instructions files from these dirs; it has
# no --custom-instructions flag).
EXTRA_FLAGS=()
if [[ "$SEL_OFFICE" == "1" ]]; then
    OFFICE_SKILL_DIR="${HOME}/.config/crush/skills/office"
    [[ -d "$OFFICE_SKILL_DIR" ]] && export COPILOT_CUSTOM_INSTRUCTIONS_DIRS="$OFFICE_SKILL_DIR"
fi

echo "  ▶ ${SEL_LABEL}  ·  alias=${SEL_MODEL}${SEL_TAG:+  ·  $SEL_TAG}"
echo
if [[ -n "${COPILOT_PROVIDER_BASE_URL:-}" ]]; then
    # Remote mode: launch copilot directly (skip ollama wrapper)
    echo "  Remote: $COPILOT_PROVIDER_BASE_URL"
    exec copilot --model "$COPILOT_MODEL" "${MCP_FLAGS[@]}" "${GIT_SAFETY[@]}" "${EXTRA_FLAGS[@]}" "$@"
elif [[ "$OFFLOAD_MODE" == "1" ]]; then
    # Big-MoE offload mode: dedicated Ollama serve with expert CPU-offload, restored on exit.
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=offload-serve.sh
    source "$SCRIPT_DIR/offload-serve.sh"
    echo "  Offload mode: experts -> system RAM (partial; slower than VRAM-resident)"
    offload_start 24
    trap 'offload_stop' EXIT
    export COPILOT_PROVIDER_BASE_URL="http://localhost:11434/v1"
    copilot --model "$COPILOT_MODEL" "${MCP_FLAGS[@]}" "${GIT_SAFETY[@]}" "${EXTRA_FLAGS[@]}" "$@"
else
    export COPILOT_PROVIDER_BASE_URL="http://localhost:11434/v1"
    exec copilot --model "$COPILOT_MODEL" "${MCP_FLAGS[@]}" "${GIT_SAFETY[@]}" "${EXTRA_FLAGS[@]}" "$@"
fi
