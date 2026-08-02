#!/bin/bash
#
# test-state-machine.sh — Tier 1: offline state-machine harness.
#
# Runs the REAL dns-failover.sh against stubbed `dig`, `ip`, `arping` and
# `sleep` placed ahead of the system ones on PATH. Nothing touches the network,
# no interface is modified, and no UDM is contacted. Every scenario completes in
# well under a second because `sleep` is a no-op.
#
# This is the only tier that can exercise timing boundaries, error paths and
# RCODEs such as SERVFAIL and REFUSED, which cannot be induced on demand
# against a live resolver.
#
# What the stubs give us:
#
#   dig     — returns a scripted RCODE per iteration, in real dig wire format,
#             and records every query so we can assert on WHICH queries were
#             issued and WHEN. A scripted TIMEOUT emits no header line at all,
#             matching dig's real behaviour on no reply.
#   ip      — maintains an in-file set of "bound" addresses, records every
#             invocation with the iteration number, and can be made to fail
#             `addr add` so the bind-failure path is reachable.
#   arping  — recorded no-op. Stubbing this is NOT optional: the daemon calls
#             `command -v arping`, and an unstubbed run would find the real one
#             and fire gratuitous ARP at a real interface.
#   sleep   — no-op that advances scenario state and terminates the daemon once
#             the scripted iterations are exhausted.
#
# Run: ./tests/test-state-machine.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAEMON="${SCRIPT_DIR}/../scripts/dns-failover.sh"

# ------------------------------------------------------------------
# Safety gate — this harness must never run on the UDM
# ------------------------------------------------------------------
#
# The daemon hardcodes CONFIG_FILE and sources it unconditionally, so on the
# UDM it would pick up the live configuration regardless of the environment we
# set here. Its presence is also a reliable "this is the UDM" signal.

if [ -f /data/adguard-failover/config.env ]; then
    echo "REFUSING TO RUN: /data/adguard-failover/config.env exists, which means" >&2
    echo "this looks like the UDM. This harness is offline-only and must run on a" >&2
    echo "workstation, where the daemon cannot source live configuration." >&2
    exit 2
fi

if [ ! -f "$DAEMON" ]; then
    echo "FATAL: daemon not found at $DAEMON" >&2
    exit 2
fi

# ------------------------------------------------------------------
# Fixed parameters for every scenario
# ------------------------------------------------------------------

T_ADGUARD_IP="192.168.1.99"
T_FAILOVER_IP="192.168.1.2"
T_LAN_IF="br0"
T_PROBE_NAME="dns.quad9.net"
T_CORROBORATE_SERVER="127.0.0.1"
T_CORROBORATE_ZONE="example.com"
T_FAIL_THRESHOLD=3
T_RECOVER_THRESHOLD=3

PASS=0
FAIL=0
CURRENT=""

RED=''; GREEN=''; YELLOW=''; BOLD=''; RESET=''
if [ -t 1 ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
    BOLD=$'\033[1m'; RESET=$'\033[0m'
fi

ok()   { PASS=$((PASS + 1)); printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; }
bad()  {
    FAIL=$((FAIL + 1))
    printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"
    [ $# -gt 1 ] && printf '        %s\n' "$2"
    return 0
}
scenario() {
    CURRENT="$1"
    printf '\n%s%s%s\n' "$BOLD" "$1" "$RESET"
}

ROOT="$(mktemp -d -t dns-failover-sm.XXXXXX)"
cleanup_root() { rm -rf "$ROOT"; }
trap cleanup_root EXIT

# ------------------------------------------------------------------
# Stub construction
# ------------------------------------------------------------------

WORK=""

make_stubs() {
    local bin="$WORK/bin"
    mkdir -p "$bin" "$WORK/state"

    # ---- dig ----------------------------------------------------
    cat >"$bin/dig" <<'STUB'
#!/bin/bash
# Scripted dig. Emits real dig-format output so the daemon's parser is
# exercised for real rather than bypassed.
W="$STUB_WORK"
server=""; name=""
for a in "$@"; do
    case "$a" in
        @*)          server="${a#@}" ;;
        +*)          ;;
        A|AAAA|ANY)  ;;
        *)           [ -z "$name" ] && name="$a" ;;
    esac
done

if [ "$server" = "$STUB_ADGUARD_IP" ]; then
    kind="primary"
    n=$(( $(cat "$W/iter") + 1 ))
    printf '%s' "$n" >"$W/iter"
    rcode="$(sed -n "${n}p" "$W/primary.script")"
else
    kind="corroborate"
    n="$(cat "$W/iter")"
    [ "$n" -ge 1 ] 2>/dev/null || n=1
    rcode="$(sed -n "${n}p" "$W/corroborate.script")"
fi
[ -n "$rcode" ] || rcode="NOERROR"

printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$kind" "$server" "$name" "$rcode" >>"$W/dig.log"

if [ "$rcode" = "TIMEOUT" ]; then
    # Real dig prints this to stderr and emits NO header line. Absence of the
    # header is the sole timeout signal in the parsing contract.
    echo ";; communications error to ${server}#53: timed out" >&2
    echo ";; connection timed out; no servers could be reached" >&2
    exit 9
fi

cat <<EOF

; <<>> DiG 9.16.1 <<>> @${server} ${name} A
;; global options: +cmd
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: ${rcode}, id: 4242
;; flags: qr rd ra; QUERY: 1, ANSWER: 0, AUTHORITY: 0, ADDITIONAL: 1

;; QUESTION SECTION:
;${name}.			IN	A

;; Query time: 4 msec
;; SERVER: ${server}#53(${server})
;; MSG SIZE  rcvd: 56
EOF
exit 0
STUB

    # ---- ip -----------------------------------------------------
    cat >"$bin/ip" <<'STUB'
#!/bin/bash
# Emulates the address operations the daemon performs, against a file.
W="$STUB_WORK"
ADDRS="$W/state/addrs"
touch "$ADDRS"
printf '%s\t%s\n' "$(cat "$W/iter")" "$*" >>"$W/ip.log"

target=""
prev=""
for a in "$@"; do
    case "$prev" in
        add|del) target="$a"; break ;;
    esac
    prev="$a"
done

case "$*" in
    *"addr show"*)
        while IFS= read -r a; do
            [ -n "$a" ] || continue
            printf '2: %s    inet %s brd 192.168.1.255 scope global %s\n' \
                "$STUB_LAN_IF" "$a" "$STUB_LAN_IF"
        done <"$ADDRS"
        exit 0
        ;;
    *"addr add"*)
        if [ -f "$W/state/add_fails" ]; then
            echo "RTNETLINK answers: Operation not permitted" >&2
            exit 2
        fi
        if grep -qxF "$target" "$ADDRS"; then
            echo "RTNETLINK answers: File exists" >&2
            exit 2
        fi
        printf '%s\n' "$target" >>"$ADDRS"
        exit 0
        ;;
    *"addr del"*)
        if [ -f "$W/state/del_fails" ]; then
            echo "RTNETLINK answers: Operation not permitted" >&2
            exit 2
        fi
        if ! grep -qxF "$target" "$ADDRS"; then
            echo "RTNETLINK answers: Cannot assign requested address" >&2
            exit 2
        fi
        grep -vxF "$target" "$ADDRS" >"$ADDRS.tmp" || true
        mv "$ADDRS.tmp" "$ADDRS"
        exit 0
        ;;
esac
exit 0
STUB

    # ---- arping -------------------------------------------------
    cat >"$bin/arping" <<'STUB'
#!/bin/bash
printf '%s\t%s\n' "$(cat "$STUB_WORK/iter")" "arping $*" >>"$STUB_WORK/ip.log"
exit 0
STUB

    # ---- sleep --------------------------------------------------
    cat >"$bin/sleep" <<'STUB'
#!/bin/bash
# No-op in place of the interval wait. Two side effects:
#   1. stages the resolv.conf state for the NEXT iteration, so drift can be
#      introduced and removed mid-run at a deterministic point;
#   2. terminates the daemon once the scripted iterations are exhausted, which
#      also exercises the SIGTERM path in every scenario.
W="$STUB_WORK"
n="$(cat "$W/iter")"

if [ -f "$W/resolv.script" ]; then
    nxt=$((n + 1))
    s="$(sed -n "${nxt}p" "$W/resolv.script")"
    [ -n "$s" ] || s="$(tail -n 1 "$W/resolv.script")"
    if [ "$s" = "drifted" ]; then
        printf 'nameserver 9.9.9.9\nnameserver %s\n' "$STUB_ADGUARD_IP" >"$W/resolv"
    else
        printf 'nameserver 9.9.9.9\n' >"$W/resolv"
    fi
fi

if [ -f "$W/steal.at" ] && grep -qx -- "$n" "$W/steal.at"; then
    # Simulate an external agent removing the standby between iterations —
    # a UniFi settings write or firmware update rewriting the bridge. Done
    # here, not via the `ip` stub, so the daemon has no idea it happened:
    # that invisibility is the whole point of the scenario.
    grep -vxF -- "${STUB_FAILOVER_IP}/32" "$W/state/addrs" >"$W/state/addrs.tmp" || true
    mv "$W/state/addrs.tmp" "$W/state/addrs"
    [ -f "$W/steal_wedge" ] && : >"$W/state/add_fails"
fi

if [ "$n" -ge "$STUB_MAX_ITER" ]; then
    kill -TERM "$(cat "$W/daemon.pid")" 2>/dev/null || true
fi
exit 0
STUB

    chmod +x "$bin/dig" "$bin/ip" "$bin/arping" "$bin/sleep"
}

# ------------------------------------------------------------------
# Scenario plumbing
# ------------------------------------------------------------------

new_scenario() {
    WORK="$ROOT/$1"
    mkdir -p "$WORK/state"
    printf '0' >"$WORK/iter"
    : >"$WORK/dig.log"
    : >"$WORK/ip.log"
    : >"$WORK/state/addrs"
    printf 'nameserver 9.9.9.9\n' >"$WORK/resolv"
    printf 'NOERROR\n' >"$WORK/primary.script"
    printf 'NOERROR\n' >"$WORK/corroborate.script"
    rm -f "$WORK/resolv.script" "$WORK/steal.at" "$WORK/steal_wedge"
    make_stubs
}

# set_primary NOERROR SERVFAIL ...  — one RCODE per iteration; the last value
# repeats for any iteration beyond the list.
set_primary()     { printf '%s\n' "$@" >"$WORK/primary.script"; }
set_corroborate() { printf '%s\n' "$@" >"$WORK/corroborate.script"; }
set_resolv()      { printf '%s\n' "$@" >"$WORK/resolv.script"
                    # iteration 1's state must be in place before startup
                    if [ "$1" = "drifted" ]; then
                        printf 'nameserver 9.9.9.9\nnameserver %s\n' "$T_ADGUARD_IP" >"$WORK/resolv"
                    else
                        printf 'nameserver 9.9.9.9\n' >"$WORK/resolv"
                    fi }
seed_bound()      { printf '%s/32\n' "$T_FAILOVER_IP" >"$WORK/state/addrs"; }
fail_adds()       { : >"$WORK/state/add_fails"; }

# steal_at N...  — have an external agent remove the standby after iteration N,
# without the daemon performing or observing the removal.
steal_at()        { printf '%s\n' "$@" >"$WORK/steal.at"; }

# Make every subsequent re-add fail, so the recovery path itself can be tested.
steal_wedges()    { : >"$WORK/steal_wedge"; }

# The scripts are 1-indexed per iteration; sed returns empty past the end, and
# the dig stub falls back to NOERROR. To make "last value repeats" work as
# documented, pad the scripts out to MAX_ITER before launching.
pad_scripts() {
    local max="$1" f last n
    for f in primary corroborate; do
        n=$(wc -l <"$WORK/${f}.script")
        last="$(tail -n 1 "$WORK/${f}.script")"
        while [ "$n" -lt "$max" ]; do
            printf '%s\n' "$last" >>"$WORK/${f}.script"
            n=$((n + 1))
        done
    done
}

run_daemon() {
    local max="$1" waited
    pad_scripts "$max"

    STUB_WORK="$WORK" \
    STUB_ADGUARD_IP="$T_ADGUARD_IP" \
    STUB_LAN_IF="$T_LAN_IF" \
    STUB_FAILOVER_IP="$T_FAILOVER_IP" \
    STUB_MAX_ITER="$max" \
    PATH="$WORK/bin:$PATH" \
    ADGUARD_IP="$T_ADGUARD_IP" \
    FAILOVER_IP="$T_FAILOVER_IP" \
    LAN_IF="$T_LAN_IF" \
    PROBE_NAME="$T_PROBE_NAME" \
    CORROBORATE_SERVER="$T_CORROBORATE_SERVER" \
    CORROBORATE_ZONE="$T_CORROBORATE_ZONE" \
    PROBE_TIMEOUT=2 \
    INTERVAL=1 \
    FAIL_THRESHOLD="$T_FAIL_THRESHOLD" \
    RECOVER_THRESHOLD="$T_RECOVER_THRESHOLD" \
    RESOLV_FILE="$WORK/resolv" \
    LOG_FILE="$WORK/failover.log" \
    bash -c 'printf "%s" $$ >"$STUB_WORK/daemon.pid"; exec bash "$0"' "$DAEMON" \
        >"$WORK/stdout" 2>"$WORK/stderr" &

    local pid=$!
    waited=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 0.1
        waited=$((waited + 1))
        if [ "$waited" -gt 150 ]; then
            kill -9 "$pid" 2>/dev/null
            bad "daemon did not terminate within 15s (scenario wedged)"
            return 1
        fi
    done
    wait "$pid" 2>/dev/null
    return 0
}

# ------------------------------------------------------------------
# Assertions
# ------------------------------------------------------------------

logfile() { printf '%s' "$WORK/failover.log"; }

count_in() { grep -cF -- "$2" "$1" 2>/dev/null || true; }

expect_log() {
    local n; n=$(count_in "$(logfile)" "$1")
    if [ "$n" -ge 1 ]; then ok "log contains: $1"
    else bad "log missing: $1" "see $(logfile)"; fi
}

refute_log() {
    local n; n=$(count_in "$(logfile)" "$1")
    if [ "$n" -eq 0 ]; then ok "log does not contain: $1"
    else bad "log unexpectedly contains ($n×): $1"; fi
}

expect_log_count() {
    local n; n=$(count_in "$(logfile)" "$1")
    if [ "$n" -eq "$2" ]; then ok "log has exactly $2 × \"$1\""
    else bad "expected $2 × \"$1\", got $n"; fi
}

# expect_dig_count KIND N
expect_dig_count() {
    local n; n=$(awk -F'\t' -v k="$1" '$2 == k' "$WORK/dig.log" | wc -l)
    if [ "$n" -eq "$2" ]; then ok "$1 queries: exactly $2"
    else bad "expected $2 $1 queries, got $n" "$(cat "$WORK/dig.log")"; fi
}

# expect_dig_at_iter KIND ITER  — was a query of this kind issued in iteration N?
expect_dig_at_iter() {
    if awk -F'\t' -v k="$1" -v i="$2" '$2 == k && $1 == i { found = 1 }
                                       END { exit !found }' "$WORK/dig.log"; then
        ok "$1 query issued in iteration $2"
    else
        bad "no $1 query in iteration $2" "$(cat "$WORK/dig.log")"
    fi
}

# expect_ip_op_at_iter "addr add" ITER
expect_ip_op_at_iter() {
    if awk -F'\t' -v op="$1" -v i="$2" '$1 == i && index($2, op) { found = 1 }
                                        END { exit !found }' "$WORK/ip.log"; then
        ok "\"$1\" occurred in iteration $2"
    else
        bad "\"$1\" did not occur in iteration $2" "$(cat "$WORK/ip.log")"
    fi
}

expect_ip_op_count() {
    local n; n=$(awk -F'\t' -v op="$1" 'index($2, op)' "$WORK/ip.log" | wc -l)
    if [ "$n" -eq "$2" ]; then ok "\"$1\" occurred exactly $2 ×"
    else bad "expected $2 × \"$1\", got $n" "$(cat "$WORK/ip.log")"; fi
}

expect_not_bound() {
    if grep -qxF "${T_FAILOVER_IP}/32" "$WORK/state/addrs"; then
        bad "${T_FAILOVER_IP} is STILL BOUND at end of run — standby stranded"
    else
        ok "${T_FAILOVER_IP} is not bound at end of run"
    fi
}

# Every scenario ends by signalling the daemon, and the daemon correctly
# withdraws the standby on TERM — so "bound at end of run" is never the right
# assertion for an engaged scenario. The meaningful claim is that the address
# was bound and STAYED bound until the signal arrived.
expect_held_until_exit() {
    local adds dels sig clr
    adds=$(awk -F'\t' 'index($2, "addr add")' "$WORK/ip.log" | wc -l)
    dels=$(awk -F'\t' 'index($2, "addr del")' "$WORK/ip.log" | wc -l)
    sig=$(grep -nF "signal received" "$(logfile)" | head -1 | cut -d: -f1)
    clr=$(grep -nF "FAILOVER CLEARED" "$(logfile)" | tail -1 | cut -d: -f1)

    if [ "$adds" -ge 1 ] && [ "$dels" -eq 1 ] \
       && [ -n "$sig" ] && [ -n "$clr" ] && [ "$clr" -gt "$sig" ]; then
        ok "standby held from engagement until SIGTERM, then withdrawn"
    else
        bad "standby was not held until exit" \
            "adds=$adds dels=$dels signal_line=${sig:-none} cleared_line=${clr:-none}"
    fi
}

# ==================================================================
# Scenarios
# ==================================================================

printf '%s%s%s\n' "$BOLD" "dns-failover state machine — offline harness" "$RESET"
printf 'daemon:  %s\n' "$DAEMON"
printf 'workdir: %s\n' "$ROOT"
printf 'params:  FAIL_THRESHOLD=%s  RECOVER_THRESHOLD=%s\n' \
    "$T_FAIL_THRESHOLD" "$T_RECOVER_THRESHOLD"

# ------------------------------------------------------------------
scenario "1. Steady UP — one query per cycle, nothing bound, no corroboration"
# ------------------------------------------------------------------
# The single most important negative result in the suite. Corroboration in UP
# would still produce correct failover behaviour, so no functional test would
# catch it — but it would leak a continuous trickle of random-label lookups off
# the network and mask a genuine state-machine regression.
new_scenario steady_up
set_primary NOERROR
run_daemon 8
expect_dig_count primary 8
expect_dig_count corroborate 0
expect_ip_op_count "addr add" 0
refute_log "state: UP"
refute_log "FAILOVER ENGAGED"
expect_not_bound

# ------------------------------------------------------------------
scenario "2. FAIL_THRESHOLD boundary — 2 failures is not enough"
# ------------------------------------------------------------------
new_scenario below_threshold
set_primary SERVFAIL SERVFAIL NOERROR NOERROR NOERROR NOERROR
run_daemon 6
refute_log "UP → PENDING"
expect_dig_count corroborate 0
expect_ip_op_count "addr add" 0
expect_not_bound

# ------------------------------------------------------------------
scenario "3. FAIL_THRESHOLD boundary — 3 failures engages, in the SAME iteration"
# ------------------------------------------------------------------
# Guards the hoisted primary probe. If UP → PENDING deferred corroboration to
# the next iteration, failover would engage at iteration 4 and the documented
# detection latency would be silently understated by one INTERVAL.
new_scenario at_threshold
set_primary SERVFAIL SERVFAIL SERVFAIL SERVFAIL
set_corroborate NOERROR
run_daemon 5
expect_log "UP → PENDING"
expect_dig_at_iter corroborate 3
expect_dig_count corroborate 1
expect_ip_op_at_iter "addr add" 3
expect_log "FAILOVER ENGAGED"
expect_held_until_exit

# ------------------------------------------------------------------
scenario "4. RECOVER_THRESHOLD boundary — 2 successes hold, the 3rd clears"
# ------------------------------------------------------------------
new_scenario recover_threshold
set_primary SERVFAIL SERVFAIL SERVFAIL NOERROR NOERROR NOERROR NOERROR
set_corroborate NOERROR
run_daemon 8
expect_ip_op_at_iter "addr add" 3
expect_ip_op_at_iter "addr del" 6
expect_ip_op_count "addr del" 1
expect_log "FAILED_OVER → UP"
expect_not_bound

# ------------------------------------------------------------------
scenario "5. Suppression — holds during a WAN outage, then engages within one INTERVAL"
# ------------------------------------------------------------------
# The critical assertion is that engagement happens at iteration 6, the first
# iteration where corroboration succeeds — not three iterations later. The
# mechanism is that PENDING corroborates every iteration and does not
# re-accumulate a failure threshold, so there is no fresh FAIL_THRESHOLD cycle
# to wait through. An implementation that only re-corroborated after another
# FAIL_THRESHOLD run of failures would engage at iteration 9.
new_scenario suppression
set_primary SERVFAIL SERVFAIL SERVFAIL SERVFAIL SERVFAIL SERVFAIL SERVFAIL
set_corroborate NOERROR NOERROR TIMEOUT TIMEOUT TIMEOUT NOERROR NOERROR
run_daemon 7
expect_log "SUPPRESSED"
expect_log_count "SUPPRESSED  AdGuard is down" 1
expect_dig_at_iter corroborate 3
expect_dig_at_iter corroborate 4
expect_dig_at_iter corroborate 5
expect_dig_at_iter corroborate 6
expect_log "SUPPRESSION CLEARED  upstream reachable again"
expect_ip_op_at_iter "addr add" 6
expect_ip_op_count "addr add" 1
expect_held_until_exit

# ------------------------------------------------------------------
scenario "6. PENDING → UP — AdGuard recovers before failover was ever needed"
# ------------------------------------------------------------------
new_scenario pending_to_up
set_primary SERVFAIL SERVFAIL SERVFAIL NOERROR NOERROR NOERROR NOERROR
set_corroborate NOERROR NOERROR TIMEOUT TIMEOUT TIMEOUT TIMEOUT TIMEOUT
run_daemon 8
expect_log "UP → PENDING"
expect_log "SUPPRESSED"
expect_log "SUPPRESSION CLEARED  AdGuard recovered before failover was needed"
expect_log "PENDING → UP (AdGuard recovered without failover)"
expect_ip_op_count "addr add" 0
expect_not_bound

# ------------------------------------------------------------------
scenario "7. Bind failure is edge-triggered and does not falsely advance state"
# ------------------------------------------------------------------
# A persistently failing `ip addr add` is retried every INTERVAL. Logging each
# attempt would flood the log at exactly the moment it most needs to be
# readable. The daemon must also stay in PENDING: claiming FAILED_OVER while no
# address is bound would be a lie in both the log and the state machine.
new_scenario bind_failure
set_primary SERVFAIL
set_corroborate NOERROR
fail_adds
run_daemon 8
expect_log_count "ERROR  failed to add" 1
expect_ip_op_count "addr add" 6
refute_log "FAILOVER ENGAGED"
expect_not_bound

# ------------------------------------------------------------------
scenario "8. Startup reconciliation — a stranded standby is removed before the loop"
# ------------------------------------------------------------------
# After a crash or reboot the address can survive with no daemon watching it,
# silently routing clients around AdGuard with no indication anywhere.
new_scenario startup_reconcile
seed_bound
set_primary NOERROR
run_daemon 4
expect_log "startup: stale"
expect_log "FAILOVER CLEARED"
expect_ip_op_at_iter "addr del" 0
expect_not_bound

# ------------------------------------------------------------------
scenario "9. SIGTERM withdraws the standby"
# ------------------------------------------------------------------
new_scenario sigterm
set_primary SERVFAIL
set_corroborate NOERROR
run_daemon 5
expect_log "FAILOVER ENGAGED"
expect_log "signal received"
expect_log "FAILOVER CLEARED"
expect_not_bound

# ------------------------------------------------------------------
scenario "10. Upstream drift logging is edge-triggered"
# ------------------------------------------------------------------
# Drift is checked every iteration. Logging every iteration would bury the
# transition under thousands of identical lines and defeat the purpose.
new_scenario drift
set_primary NOERROR
set_resolv clean clean drifted drifted drifted clean clean clean
run_daemon 8
expect_log_count "upstream check:" 1
expect_log_count "DRIFT  " 1
expect_log_count "DRIFT CLEARED" 1

# ------------------------------------------------------------------
scenario "11. Drift present at startup logs once, not once per iteration"
# ------------------------------------------------------------------
new_scenario drift_at_startup
set_primary NOERROR
set_resolv drifted drifted drifted drifted drifted
run_daemon 5
expect_log_count "DRIFT  " 1
expect_log_count "DRIFT CLEARED" 0
refute_log "upstream check:"

# ------------------------------------------------------------------
# RCODE classification table, driven end to end through the daemon
# ------------------------------------------------------------------
printf '\n%sRCODE classification — three consecutive of each code%s\n' "$BOLD" "$RESET"

rcode_case() {
    local code="$1" expect="$2"
    new_scenario "rcode_${code}"
    set_primary "$code" "$code" "$code" "$code"
    set_corroborate NOERROR
    run_daemon 4
    local engaged; engaged=$(count_in "$(logfile)" "FAILOVER ENGAGED")
    if [ "$expect" = "engage" ]; then
        if [ "$engaged" -ge 1 ]; then ok "$code → failure (engages failover)"
        else bad "$code should be classified as failure but did not engage"; fi
    else
        if [ "$engaged" -eq 0 ]; then ok "$code → success (no failover)"
        else bad "$code should be classified as success but engaged failover"; fi
    fi
}

rcode_case NOERROR  hold
rcode_case NXDOMAIN hold
rcode_case SERVFAIL engage
rcode_case REFUSED  engage
rcode_case TIMEOUT  engage
rcode_case NOTIMP   engage
rcode_case FORMERR  engage
rcode_case NOTAUTH  engage

# ------------------------------------------------------------------
scenario "12. Recovery counter resets on a single relapse"
# ------------------------------------------------------------------
# Two successes, one failure, two successes must NOT clear failover: the
# threshold is three CONSECUTIVE successes. An implementation that accumulated
# non-consecutive successes would flap the standby.
new_scenario relapse
set_primary SERVFAIL SERVFAIL SERVFAIL NOERROR NOERROR SERVFAIL NOERROR NOERROR
set_corroborate NOERROR
run_daemon 8
expect_ip_op_at_iter "addr add" 3
expect_ip_op_count "addr del" 1     # only the SIGTERM withdrawal at exit
expect_log "signal received"
refute_log "FAILED_OVER → UP"

# ------------------------------------------------------------------
scenario "13. Flap below threshold never engages"
# ------------------------------------------------------------------
new_scenario flap
set_primary SERVFAIL NOERROR SERVFAIL NOERROR SERVFAIL NOERROR SERVFAIL NOERROR
run_daemon 8
refute_log "UP → PENDING"
expect_dig_count corroborate 0
expect_ip_op_count "addr add" 0
expect_not_bound

# ------------------------------------------------------------------
scenario "14. Self-heal — an externally removed standby is restored while engaged"
# ------------------------------------------------------------------
# The failure this guards against: the daemon bound the address once, on the
# UP → FAILED_OVER edge, and never looked at it again. Anything that rewrites
# br0 takes it away — and on this device firmware updates are automatic and
# unattended, so "an outage that overlaps a bridge rewrite" is a scheduled
# event, not a freak one. Without self-heal, clients spend the remainder of the
# outage with no fallback and the log never says so.
new_scenario selfheal
set_primary SERVFAIL
steal_at 5
run_daemon 9

expect_log "FAILOVER ENGAGED"
expect_log "SELF-HEAL"
expect_log "SELF-HEAL COMPLETE"
# Engage on iteration 3, self-heal re-add on 6 (the iteration after the steal).
expect_ip_op_at_iter "addr add" 3
expect_ip_op_at_iter "addr add" 6
expect_held_until_exit
# One disappearance must produce exactly one announcement, not one per iteration
# for the four iterations that follow it.
expect_log_count "SELF-HEAL  " 1

# ------------------------------------------------------------------
scenario "15. Self-heal is silent when nothing removes the standby"
# ------------------------------------------------------------------
# A self-heal that fires on a healthy engaged episode would re-add an address
# that is already there every INTERVAL and bury the log. This is the assertion
# that keeps the check edge-triggered rather than merely present.
new_scenario selfheal_quiet
set_primary SERVFAIL
run_daemon 9

expect_log "FAILOVER ENGAGED"
refute_log "SELF-HEAL"
expect_ip_op_count "addr add" 1
expect_held_until_exit

# ------------------------------------------------------------------
scenario "16. Self-heal never re-adds on the iteration that disengages"
# ------------------------------------------------------------------
# The check runs at the end of the FAILED_OVER branch, so it must be guarded on
# the state AFTER the recovery test. Guarded on the state before it, a recovery
# iteration would remove the address and then immediately put it back, leaving
# the standby stranded on the network while the log claimed FAILED_OVER → UP.
new_scenario selfheal_disengage
set_primary SERVFAIL SERVFAIL SERVFAIL NOERROR
run_daemon 9

expect_log "FAILOVER ENGAGED"
expect_log "FAILOVER CLEARED"
expect_log "FAILED_OVER → UP"
refute_log "SELF-HEAL"
expect_ip_op_count "addr add" 1
expect_ip_op_count "addr del" 1
expect_not_bound

# ------------------------------------------------------------------
scenario "17. A wedged self-heal reports once and keeps retrying silently"
# ------------------------------------------------------------------
# If the re-add itself fails, the daemon is in the worst state it can be in:
# engaged, unprotected, and unable to fix itself. That must be said once,
# loudly — and then not repeated every INTERVAL, because a flooded log is
# unreadable at exactly the moment someone is reading it.
new_scenario selfheal_wedged
set_primary SERVFAIL
steal_at 5
steal_wedges
run_daemon 10

expect_log "FAILOVER ENGAGED"
expect_log_count "SELF-HEAL  " 1
expect_log_count "self-heal could not re-add" 1
refute_log "SELF-HEAL COMPLETE"
expect_not_bound


printf '\n%s%s%s\n' "$BOLD" "────────────────────────────────────────" "$RESET"
printf '  passed: %s%d%s\n' "$GREEN" "$PASS" "$RESET"
if [ "$FAIL" -gt 0 ]; then
    printf '  failed: %s%d%s\n' "$RED" "$FAIL" "$RESET"
    printf '\n%sArtifacts retained for inspection are under %s%s\n' \
        "$YELLOW" "$ROOT" "$RESET"
    trap - EXIT
    exit 1
fi
printf '  failed: 0\n'
printf '\n%sAll state-machine assertions passed.%s\n' "$GREEN" "$RESET"
exit 0
