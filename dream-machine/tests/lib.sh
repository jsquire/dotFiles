#!/bin/bash
#
# lib.sh — shared plumbing for the test suite.
#
# Sourced, not executed. Provides config loading, assertion helpers, UDM and
# AdGuard-host SSH wrappers, and daemon-state inspection.
#
# A note on where assertions run, because the retired suite got this wrong and
# passed for months against a design that never worked:
#
#   Client-visible behaviour is asserted FROM THE WORKSTATION, over the same
#   L2 path a real client uses. Asserting from the UDM tests the UDM's view of
#   the network, which is not the thing under test. UDM-side checks here are
#   restricted to inspecting daemon state and logs — never to standing in for
#   a client.

set -u

VERIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$VERIFY_DIR/.." && pwd)"
CONFIG_FILE="$REPO_DIR/scripts/config.env"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: $CONFIG_FILE not found. Copy scripts/config.env.example and edit it." >&2
    exit 1
fi
# shellcheck disable=SC1090
. "$CONFIG_FILE"

: "${UDM_HOST:?UDM_HOST must be set in config.env}"
: "${UDM_SSH_USER:?UDM_SSH_USER must be set in config.env}"
: "${ADGUARD_IP:?ADGUARD_IP must be set in config.env}"
: "${FAILOVER_IP:?FAILOVER_IP must be set in config.env}"
: "${LAN_IF:=br0}"
: "${PROBE_NAME:=dns.quad9.net}"
: "${PROBE_TIMEOUT:=2}"
: "${INTERVAL:=10}"
: "${FAIL_THRESHOLD:=3}"
: "${RECOVER_THRESHOLD:=3}"
: "${CORROBORATE_SERVER:=127.0.0.1}"
: "${CORROBORATE_ZONE:=example.com}"
: "${RESOLV_FILE:=/run/resolv.conf.d/main}"
: "${LOG_FILE:=/data/adguard-failover/failover.log}"

# Optional — enables only the secondary "host stays administrable" check.
: "${ADGUARD_SSH_USER:=}"

SSH_TARGET="${UDM_SSH_USER}@${UDM_HOST}"
SSH_OPTS=(-o ConnectTimeout=5 -o BatchMode=yes)

# Worst-case time for the daemon to notice AdGuard is gone and engage, plus
# slack for the corroborating probe and the ip-addr round trip.
DETECT_SECS=$(( INTERVAL * FAIL_THRESHOLD + PROBE_TIMEOUT ))
ENGAGE_DEADLINE=$(( DETECT_SECS + INTERVAL + 10 ))
RECOVER_DEADLINE=$(( INTERVAL * RECOVER_THRESHOLD + PROBE_TIMEOUT + INTERVAL + 10 ))

# ------------------------------------------------------------------
# Output helpers
# ------------------------------------------------------------------

pass_count=0
fail_count=0
skip_count=0

hdr()   { printf '\n\033[1;36m=== %s ===\033[0m\n' "$*"; }
info()  { printf '  \033[0;36mi\033[0m %s\n' "$*"; }
note()  { printf '      %s\n' "$*"; }

_pass() { printf '  \033[1;32m✓\033[0m %s\n' "$*"; pass_count=$((pass_count + 1)); }
_fail() { printf '  \033[1;31m✗\033[0m %s\n' "$*"; fail_count=$((fail_count + 1)); }
_skip() { printf '  \033[1;33m-\033[0m %s (skipped)\n' "$*"; skip_count=$((skip_count + 1)); }

# assert "description" <command...>
# Passes when the command exits 0.
assert() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then _pass "$desc"; else _fail "$desc"; fi
}

# refute "description" <command...>
# Passes when the command exits non-zero.
refute() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then _fail "$desc"; else _pass "$desc"; fi
}

# assert_eq "description" expected actual
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        _pass "$desc"
    else
        _fail "$desc"
        note "expected: $expected"
        note "actual:   $actual"
    fi
}

summary() {
    printf '\n'
    if [ "$fail_count" -eq 0 ]; then
        printf '\033[1;32mPASS\033[0m  %d passed' "$pass_count"
    else
        printf '\033[1;31mFAIL\033[0m  %d passed, %d failed' "$pass_count" "$fail_count"
    fi
    [ "$skip_count" -gt 0 ] && printf ', %d skipped' "$skip_count"
    printf '\n\n'
    [ "$fail_count" -eq 0 ]
}

# ------------------------------------------------------------------
# Remote execution
# ------------------------------------------------------------------

udm() { ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "$@"; }

adguard_host() {
    [ -n "$ADGUARD_SSH_USER" ] || return 127
    ssh "${SSH_OPTS[@]}" "${ADGUARD_SSH_USER}@${ADGUARD_IP}" "$@"
}

require_udm() {
    if ! udm 'echo ok' >/dev/null 2>&1; then
        echo "ERROR: cannot SSH to ${SSH_TARGET}." >&2
        exit 1
    fi
}

# Is the AdGuard host still administrable?
#
# Secondary signal only. The primary assertion that ADGUARD_IP is never
# impersonated is adguard_ip_unbound_on_udm(), which needs no credentials and
# cannot be confounded by an unrelated SSH problem.
adguard_host_reachable() {
    [ -n "$ADGUARD_SSH_USER" ] || return 127
    adguard_host 'echo ok' >/dev/null 2>&1
}

# Has anything on the UDM claimed ADGUARD_IP?
#
# This is the requirement that killed the previous design: impersonating the
# AdGuard address severs SSH to the host at precisely the moment an operator
# needs it. Asserted directly rather than inferred from SSH working.
adguard_ip_unbound_on_udm() {
    ! udm "ip -4 -o addr show 2>/dev/null" \
        | awk -v ip="$ADGUARD_IP" '{ split($4, a, "/"); if (a[1] == ip) found = 1 } END { exit !found }'
}

# ------------------------------------------------------------------
# The dig parsing contract, reimplemented here deliberately.
# ------------------------------------------------------------------
#
# This is a duplicate of dig_rcode() in scripts/dns-failover.sh, and that is
# intentional rather than an oversight. If the test imported the daemon's
# implementation, a change in parsing would change the test's expectations in
# lockstep and every assertion would keep passing. Restating the contract
# independently is what makes test-parsing.sh able to fail.
#
#   1. Select the line containing '->>HEADER<<-'.
#   2. Extract the token following 'status: ', up to the next comma.
#   3. If no such line exists, the result is TIMEOUT.
#
# NOT part of the contract: dig's exit status, +short output, emptiness of the
# answer section.
rcode_of() {
    local server="$1" name="$2" timeout="${3:-$PROBE_TIMEOUT}" out
    out="$(dig @"$server" "$name" A +tries=1 +time="$timeout" 2>/dev/null)"
    parse_rcode "$out"
}

# The parsing half on its own, so fixtures can be fed to it directly. Live
# queries cannot reliably produce every RCODE on demand — REFUSED in
# particular — so the classification table is asserted against captured output
# rather than against whatever the internet happens to return today.
parse_rcode() {
    local rcode
    rcode="$(printf '%s\n' "$1" | awk '
        /->>HEADER<<-/ {
            if (match($0, /status: [A-Z]+/)) {
                print substr($0, RSTART + 8, RLENGTH - 8)
                exit
            }
        }')"
    [ -n "$rcode" ] || rcode="TIMEOUT"
    printf '%s\n' "$rcode"
}

# Success classification: NOERROR and NXDOMAIN only.
rcode_is_ok() {
    case "$1" in NOERROR|NXDOMAIN) return 0 ;; *) return 1 ;; esac
}

random_label() { printf 'x%s' "$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }

# ------------------------------------------------------------------
# State inspection
# ------------------------------------------------------------------

# Is the standby address bound on the UDM?
standby_bound() {
    udm "ip -4 -o addr show dev '${LAN_IF}' 2>/dev/null" \
        | awk -v ip="$FAILOVER_IP" '{ split($4, a, "/"); if (a[1] == ip) found = 1 } END { exit !found }'
}

# Does the standby actually ANSWER DNS, as seen from this workstation?
# This is the client-visible assertion and the one that matters; standby_bound
# only tells you the address exists.
standby_answers() {
    local rcode
    rcode="$(rcode_of "$FAILOVER_IP" "$PROBE_NAME" 3)"
    rcode_is_ok "$rcode"
}

adguard_answers() {
    local rcode
    rcode="$(rcode_of "$ADGUARD_IP" "$PROBE_NAME" 3)"
    rcode_is_ok "$rcode"
}

# Does the standby resolve a name it cannot possibly have cached?
#
# standby_answers() can be satisfied by a cached record. This one cannot: a
# fresh random label forces the full recursion chain, proving the standby is
# genuinely resolving rather than replaying a warm cache entry.
standby_resolves_fresh() {
    local rcode
    rcode="$(rcode_of "$FAILOVER_IP" "$(random_label).${CORROBORATE_ZONE}" 3)"
    rcode_is_ok "$rcode"
}

daemon_running() {
    udm 'pgrep -f "/data/adguard-failover/[d]ns-failover.sh" >/dev/null 2>&1'
}

daemon_log() { udm "cat '${LOG_FILE}' 2>/dev/null || true"; }

daemon_log_lines() { udm "wc -l < '${LOG_FILE}' 2>/dev/null || echo 0"; }

# Log content added since a previously captured line count.
daemon_log_since() {
    local from="$1"
    udm "tail -n +$((from + 1)) '${LOG_FILE}' 2>/dev/null || true"
}

# Wait for the log to stop growing before reading it.
#
# The daemon writes its state-change line after the syscall that effects the
# change, so a test that observes the address and reads the log in the same
# breath races the very line it is looking for. This cost a false failure on a
# run where failover worked perfectly: the address was bound, DNS was answering,
# and the assertion said the daemon never logged FAILOVER ENGAGED — it had, ~3s
# later.
#
# Deliberately expectation-neutral: it waits for quiescence rather than for a
# particular string, so it cannot be used to wait for a line that never comes
# and call that a pass.
daemon_log_settle() {
    local quiet_needed="${1:-2}" limit="${2:-20}"
    local waited=0 stable=0 last cur
    last="$(daemon_log_lines)"
    while [ "$waited" -lt "$limit" ]; do
        sleep 1
        waited=$((waited + 1))
        cur="$(daemon_log_lines)"
        if [ "$cur" = "$last" ]; then
            stable=$((stable + 1))
            [ "$stable" -ge "$quiet_needed" ] && return 0
        else
            stable=0
            last="$cur"
        fi
    done
    return 0
}

# ------------------------------------------------------------------
# Waiting
# ------------------------------------------------------------------

# wait_for <seconds> <description> <command...>
# Polls once a second until the command succeeds or the deadline passes.
# Reports how long it actually took, which is the number worth knowing.
wait_for() {
    local deadline="$1" desc="$2"; shift 2
    local elapsed=0
    while [ "$elapsed" -lt "$deadline" ]; do
        if "$@" >/dev/null 2>&1; then
            _pass "$desc (after ${elapsed}s)"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    _fail "$desc (still false after ${deadline}s)"
    return 1
}

# wait_for_false <seconds> <description> <command...>
# The inverse of wait_for: polls until the command FAILS.
wait_for_false() {
    local deadline="$1" desc="$2"; shift 2
    local elapsed=0
    while [ "$elapsed" -lt "$deadline" ]; do
        if ! "$@" >/dev/null 2>&1; then
            _pass "$desc (after ${elapsed}s)"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    _fail "$desc (still true after ${deadline}s)"
    return 1
}

# wait_while <seconds> <description> <command...>
# Passes only if the command stays FALSE for the whole window.
stays_false() {
    local window="$1" desc="$2"; shift 2
    local elapsed=0
    while [ "$elapsed" -lt "$window" ]; do
        if "$@" >/dev/null 2>&1; then
            _fail "$desc (became true after ${elapsed}s)"
            return 1
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    _pass "$desc (held for ${window}s)"
    return 0
}

# ==================================================================
# Tier 2 — UDM-local induction
# ==================================================================
#
# Tier 2 induces AdGuard failure by severing the UDM's OWN VIEW of it, using
# reversible changes confined to the UDM. AdGuard itself is never touched and
# stays healthy throughout; clients reach it L2-direct without traversing the
# UDM's OUTPUT chain, and the upstream-blocking rules are OUTPUT-scoped so
# forwarded traffic — including AdGuard's own upstream queries — is unaffected.
#
# The one genuine client-visible effect is the standby address itself. Once
# FAILOVER_IP is advertised in DHCP, binding it makes it a live resolver for
# every client holding a lease, and clients that use it resolve UNFILTERED and
# UNATTRIBUTED. That is the exact silent-bypass failure this project exists to
# prevent, so engaged time is measured, capped and reported rather than assumed
# to be brief.
#
# Ordering note: running the full Tier 2 suite BEFORE adding FAILOVER_IP to
# DHCP removes this exposure entirely, and is the documented deployment
# sequence.

INDUCE_TAG="dns-failover-test"

: "${STANDBY_IN_DHCP:=yes}"

# Ceiling on how long the standby may stay bound during one test.
#
# 60s was the first proposal and is WRONG for the deployed parameters: the
# standby cannot come down faster than RECOVER_THRESHOLD x INTERVAL (30s at
# 3 x 10s), and worst case is that plus a probe timeout and a partial interval,
# so a 60s ceiling would fire spuriously on healthy runs. The ceiling must
# exceed the recovery path with margin, not merely feel small.
: "${MAX_ENGAGED_SECS:=$(( INTERVAL * RECOVER_THRESHOLD + PROBE_TIMEOUT + INTERVAL + 60 ))}"

T2_STATE=""
T2_WATCHDOG_PID=""
T2_ENGAGED_AT=""
T2_ENGAGED_TOTAL=0

EXIT_ASSERTION_FAILED=1
EXIT_WATCHDOG_FIRED=3

# ------------------------------------------------------------------
# Leftover detection
# ------------------------------------------------------------------
#
# A stranded induction rule makes the UDM permanently believe AdGuard is down,
# pinning the standby up. Clients then have a reachable standby and may begin
# bypassing AdGuard with no visible symptom — silent, and indistinguishable
# from normal operation without looking. Both address families are scanned; an
# orphaned ip6tables rule is exactly as harmful and far easier to overlook.

induced_leftovers() {
    udm "iptables-save 2>/dev/null | grep -F -- '${INDUCE_TAG}' || true
         ip6tables-save 2>/dev/null | grep -F -- '${INDUCE_TAG}' || true"
}

# Hard refusal, for use as a Tier 2 preflight.
require_no_leftovers() {
    local found
    found="$(induced_leftovers)"
    if [ -n "$found" ]; then
        printf '\n\033[1;31mREFUSING TO RUN\033[0m\n'
        printf 'Induction rules from an aborted previous run are still present on the UDM.\n'
        printf 'While they exist the UDM cannot see AdGuard, so any result here is meaningless.\n\n'
        printf '%s\n\n' "$found"
        printf 'Remove them with:\n'
        printf '  ssh %s "iptables-save | grep -v %s | iptables-restore"\n' "$SSH_TARGET" "$INDUCE_TAG"
        printf '  ssh %s "ip6tables-save | grep -v %s | ip6tables-restore"\n\n' "$SSH_TARGET" "$INDUCE_TAG"
        exit 2
    fi
}

# Soft check, for use as a routine assertion in test-normal.sh.
assert_no_leftovers() {
    local found
    found="$(induced_leftovers)"
    if [ -z "$found" ]; then
        _pass "no stranded test-induction rules on the UDM"
    else
        _fail "STRANDED INDUCTION RULES PRESENT — the UDM cannot see AdGuard"
        note "$found"
        note "clients may be silently bypassing AdGuard via the standby right now"
    fi
}

# ------------------------------------------------------------------
# Rule lifecycle
# ------------------------------------------------------------------

t2_init() {
    T2_STATE="$(mktemp -d -t dns-failover-t2.XXXXXX)"
    : >"$T2_STATE/rules"
    : >"$T2_STATE/restore"
    trap t2_teardown EXIT INT TERM
}

# induce_rule <iptables|ip6tables> "<match spec>" "<target>"
induce_rule() {
    local bin="$1" match="$2" target="$3"
    local rule="OUTPUT ${match} -m comment --comment ${INDUCE_TAG} -j ${target}"

    if ! udm "${bin} -I ${rule}" >/dev/null 2>&1; then
        _fail "could not install induction rule: ${bin} -I ${rule}"
        return 1
    fi
    printf '%s\t%s\n' "$bin" "$rule" >>"$T2_STATE/rules"

    if ! udm "${bin} -C ${rule}" >/dev/null 2>&1; then
        _fail "induction rule absent immediately after insert: ${bin} ${rule}"
        return 1
    fi
    info "induced: ${bin} ${rule}"
    return 0
}

# Register a file to be restored verbatim on teardown, capturing its current
# contents now. Used by the drift test.
register_restore() {
    local path="$1" backup
    backup="$T2_STATE/restore.$(printf '%s' "$path" | tr '/' '_')"
    udm "cat '${path}' 2>/dev/null || true" >"$backup"
    printf '%s\t%s\n' "$path" "$backup" >>"$T2_STATE/restore"
}

# ------------------------------------------------------------------
# Teardown
# ------------------------------------------------------------------
#
# Removal is VERIFIED with -C rather than inferred from the exit status of -D.
# Confirming the file was restored and confirming the standby came down are
# separate facts, and neither implies the other.

# NOTE the </dev/null on every udm call below. `udm` is ssh, and ssh reads
# stdin. Inside a `while read ... done <file` loop, stdin IS the rules file, so
# the first ssh drains the remaining lines and the loop silently ends after one
# iteration. Observed on a real run: two rules induced (udp, then tcp), the udp
# rule removed, the tcp rule left behind on the router — and no CLEANUP FAILED
# reported, because the loop never saw the line it failed to clean.
#
# The verification `-C` call cannot catch this. It only ever runs for rules the
# loop actually reached.
_t2_remove_rules() {
    local bin rule failed=0
    [ -s "$T2_STATE/rules" ] || return 0
    while IFS=$'\t' read -r bin rule; do
        [ -n "$bin" ] || continue
        udm "${bin} -D ${rule}" </dev/null >/dev/null 2>&1 || true
        if udm "${bin} -C ${rule}" </dev/null >/dev/null 2>&1; then
            printf '  \033[1;31mCLEANUP FAILED\033[0m rule still present: %s -D %s\n' "$bin" "$rule" >&2
            failed=1
        fi
    done <"$T2_STATE/rules"
    [ "$failed" -eq 0 ] && : >"$T2_STATE/rules"
    return "$failed"
}

_t2_restore_files() {
    local path backup
    [ -s "$T2_STATE/restore" ] || return 0
    while IFS=$'\t' read -r path backup; do
        [ -n "$path" ] || continue
        udm "cat >'${path}'" <"$backup" >/dev/null 2>&1 || \
            printf '  \033[1;31mCLEANUP FAILED\033[0m could not restore %s\n' "$path" >&2
    done <"$T2_STATE/restore"
    : >"$T2_STATE/restore"
}

_t2_force_unbind() {
    standby_bound || return 0

    # Stop the daemon rather than try to outrun it.
    #
    # reassert_failover() re-adds the standby within one INTERVAL whenever it is
    # missing while the daemon is FAILED_OVER — which is precisely the situation
    # this function is called in. A bare `ip addr del` therefore appears to work
    # and then silently loses: the address is gone when teardown re-checks it a
    # second later, and back on the wire well after the suite has exited and
    # reported success. That is the one outcome this harness exists to prevent.
    #
    # The daemon's own TERM handler unbinds the standby, and the supervisor
    # restarts it into the startup reconcile, which removes a stale standby
    # unconditionally. The direct delete is kept as a last resort for a daemon
    # that is wedged, absent, or failed to unbind.
    #
    # The pattern is bracketed to exclude the SSH-side shell running it. This is
    # a compound command, so that shell persists with the pattern in its own
    # command line and would otherwise match itself.
    udm 'pgrep -f "/data/adguard-failover/[d]ns-failover.sh" | while read -r p; do kill "$p" 2>/dev/null; done; true' \
        </dev/null >/dev/null 2>&1 || true

    local waited=0
    while standby_bound && [ "$waited" -lt 15 ]; do
        sleep 1
        waited=$((waited + 1))
    done

    if standby_bound; then
        udm "ip addr del '${FAILOVER_IP}/32' dev '${LAN_IF}'" </dev/null >/dev/null 2>&1 || true
    fi

    # Wait for the supervisor to bring the daemon back, so the device is not
    # left unprotected and the next run's preflight does not trip on its absence.
    waited=0
    while ! daemon_running && [ "$waited" -lt 30 ]; do
        sleep 1
        waited=$((waited + 1))
    done
}

t2_teardown() {
    local rc=$?
    trap - EXIT INT TERM
    [ -n "$T2_STATE" ] || exit "$rc"

    _t2_stop_watchdog

    _t2_remove_rules || rc=$EXIT_ASSERTION_FAILED
    _t2_restore_files

    # The daemon needs a recovery cycle to notice and withdraw the standby.
    local waited=0
    while standby_bound && [ "$waited" -lt "$RECOVER_DEADLINE" ]; do
        sleep 1
        waited=$((waited + 1))
    done
    if standby_bound; then
        printf '  \033[1;33mforcing standby withdrawal\033[0m (daemon did not disengage in %ss)\n' \
            "$RECOVER_DEADLINE" >&2
        _t2_force_unbind
    fi

    _t2_report_engaged

    if standby_bound; then
        printf '\n\033[1;31mSTANDBY STILL BOUND\033[0m — clients may be bypassing AdGuard.\n' >&2
        printf 'Remove it manually:\n  ssh %s "ip addr del %s/32 dev %s"\n\n' \
            "$SSH_TARGET" "$FAILOVER_IP" "$LAN_IF" >&2
        rc=$EXIT_ASSERTION_FAILED
    fi

    if [ -f "$T2_STATE/watchdog_fired" ]; then
        rc=$EXIT_WATCHDOG_FIRED
    fi

    rm -rf "$T2_STATE"
    exit "$rc"
}

# ------------------------------------------------------------------
# Engaged-duration accounting and watchdog
# ------------------------------------------------------------------

mark_engaged()   { T2_ENGAGED_AT="$(date +%s)"; }
mark_disengaged() {
    [ -n "$T2_ENGAGED_AT" ] || return 0
    T2_ENGAGED_TOTAL=$(( T2_ENGAGED_TOTAL + ($(date +%s) - T2_ENGAGED_AT) ))
    T2_ENGAGED_AT=""
}

_t2_report_engaged() {
    mark_disengaged
    if [ "$T2_ENGAGED_TOTAL" -gt 0 ]; then
        info "standby was bound for ${T2_ENGAGED_TOTAL}s total during this run (ceiling ${MAX_ENGAGED_SECS}s)"
        if [ "$STANDBY_IN_DHCP" = "yes" ]; then
            note "this is the window in which clients could have resolved unfiltered"
        fi
    fi
}

# The watchdog runs as a detached subshell and cannot touch the parent's
# counters, so it signals through a file the teardown checks. It reads the rule
# list from disk rather than from memory, so rules installed after it started
# are still removed.
_t2_start_watchdog() {
    local state="$T2_STATE" ceiling="$MAX_ENGAGED_SECS"
    (
        # The ceiling caps how long the STANDBY IS BOUND, which is the only
        # quantity with any client exposure attached to it. It is emphatically
        # not a limit on how long the test runs.
        #
        # This was `sleep "$ceiling"` — a wall-clock timer armed at induction.
        # test-suppression.sh deliberately holds the WAN down for ~52s while the
        # standby is correctly NOT bound, so total elapsed crossed the ceiling on
        # a run where the standby was bound for 33s. The watchdog then tore down
        # induction mid-test and forced exit 3 on a run whose every assertion had
        # passed, while printing "standby exceeded 102s" — a statement the run's
        # own accounting contradicted in the very next line.
        #
        # A watchdog that fires on healthy runs is worse than none: it trains you
        # to discount the one signal that is supposed to mean something.
        poll=5
        bound_for=0
        while :; do
            sleep "$poll"
            [ -d "$state" ] || exit 0
            [ -f "$state/disarmed" ] && exit 0
            if standby_bound; then
                bound_for=$(( bound_for + poll ))
                [ "$bound_for" -ge "$ceiling" ] && break
            fi
        done

        printf '\n\033[1;31mWATCHDOG\033[0m standby bound %ss, exceeding the %ss ceiling; forcing teardown.\n' \
            "$bound_for" "$ceiling" >&2
        touch "$state/watchdog_fired"

        # Induction first. While it is in place the daemon considers AdGuard
        # down and re-adds the standby within one INTERVAL, so unbinding first
        # is a race the watchdog loses.
        local bin rule
        while IFS=$'\t' read -r bin rule; do
            [ -n "$bin" ] || continue
            udm "${bin} -D ${rule}" </dev/null >/dev/null 2>&1 || true
            udm "${bin} -C ${rule}" </dev/null >/dev/null 2>&1 && \
                printf '  WATCHDOG could not remove: %s -D %s\n' "$bin" "$rule" >&2
        done <"$state/rules"

        # Give the daemon its recovery cycle before overriding it.
        local waited=0
        while standby_bound && [ "$waited" -lt "$RECOVER_DEADLINE" ]; do
            sleep 1; waited=$((waited + 1))
        done
        standby_bound && _t2_force_unbind

        if standby_bound; then
            printf '\n  WATCHDOG COULD NOT WITHDRAW THE STANDBY. Run:\n' >&2
            printf '    ssh %s "ip addr del %s/32 dev %s"\n' "$SSH_TARGET" "$FAILOVER_IP" "$LAN_IF" >&2
        fi
    ) </dev/null &
    T2_WATCHDOG_PID=$!
}

_t2_stop_watchdog() {
    [ -n "$T2_STATE" ] && touch "$T2_STATE/disarmed"
    if [ -n "$T2_WATCHDOG_PID" ]; then
        kill "$T2_WATCHDOG_PID" 2>/dev/null || true
        wait "$T2_WATCHDOG_PID" 2>/dev/null || true
        T2_WATCHDOG_PID=""
    fi
}

# ------------------------------------------------------------------
# Maintenance-window gate
# ------------------------------------------------------------------
#
# Only meaningful once FAILOVER_IP is advertised in DHCP. Before that, binding
# the standby is invisible to every client and there is nothing to declare.

require_window() {
    local what="$1"
    if [ "$STANDBY_IN_DHCP" != "yes" ]; then
        info "STANDBY_IN_DHCP=no — binding the standby is not yet client-visible"
        return 0
    fi
    printf '\n\033[1;33mMAINTENANCE WINDOW REQUIRED\033[0m\n'
    printf '  %s\n\n' "$what"
    printf '%s is advertised in DHCP, so while this test holds failover engaged,\n' "$FAILOVER_IP"
    printf 'clients may resolve through the UDM UNFILTERED and UNATTRIBUTED.\n'
    printf 'AdGuard itself is not touched and stays healthy throughout.\n'
    printf 'Engaged time is capped at %ss and reported at the end.\n' "$MAX_ENGAGED_SECS"
    printf '\nProceed? [y/N] '

    # Deliberately NOT read from stdin.
    #
    # lib.sh runs its SSH preflight at source time, and ssh reads stdin — so on
    # a piped run the prompt read EOF and aborted a run the operator had already
    # authorised. The inverse is the dangerous one: reading stdin means a stray
    # `yes |` or an inherited pipe can silently approve real client exposure.
    # An authorisation that can be answered by an accident is not one.
    #
    # So: an explicit, auditable environment variable, or the terminal. Never
    # the byte stream that ssh is also competing for.
    local reply=""
    if [ -n "${T2_WINDOW_APPROVED:-}" ]; then
        reply="$T2_WINDOW_APPROVED"
        printf '%s   (pre-authorised via T2_WINDOW_APPROVED)\n' "$reply"
    elif ( : </dev/tty ) 2>/dev/null; then
        # `[ -r /dev/tty ]` is not enough: the node can be readable by mode
        # while having no controlling terminal to open, which produced a raw
        # "No such device or address" instead of the actionable message below.
        read -r reply </dev/tty || reply=""
    else
        printf '\n'
        echo "Aborted: no terminal to confirm on." >&2
        echo "This test exposes clients, so it will not proceed on an assumed yes." >&2
        echo "Re-run interactively, or set T2_WINDOW_APPROVED=yes to record that" >&2
        echo "a human authorised this exposure." >&2
        exit 0
    fi

    case "$reply" in
        y|Y|yes|YES) return 0 ;;
        *) echo "Aborted."; exit 0 ;;
    esac
}

# ------------------------------------------------------------------
# Upstream enumeration, for the suppression test
# ------------------------------------------------------------------
#
# The suppression test's validity rests ENTIRELY on this being complete.
# dnsmasq runs with `all-servers`, so queries fan out to every upstream in
# parallel and a single unblocked resolver defeats the test WHILE IT APPEARS TO
# PASS. resolv.conf alone is not authoritative: UniFi also writes `server=`
# directives into the dnsmasq config, and the two can differ.

DNSMASQ_CONF_DIR="/run/dnsmasq.dns.conf.d"

# Prints one upstream per line. Handles `server=1.2.3.4`,
# `server=/domain/1.2.3.4` and `server=1.2.3.4#5353`.
enumerate_upstreams() {
    udm "
        awk '\$1 == \"nameserver\" { print \$2 }' '${RESOLV_FILE}' 2>/dev/null || true
        grep -rhoE '^server=[^[:space:]]+' '${DNSMASQ_CONF_DIR}' 2>/dev/null | sed 's/^server=//' || true
    " | awk -F/ '{ print $NF }' | sed 's/#.*$//' | sed '/^$/d' | LC_ALL=C sort -u
}

upstream_family() {
    case "$1" in *:*) printf 'inet6\n' ;; *) printf 'inet\n' ;; esac
}

# Non-53 upstream ports mean a --dport 53 rule would miss the path entirely —
# the precise false confidence this whole pattern exists to eliminate.
enumerate_nonstandard_transports() {
    udm "grep -rhoE '^server=[^[:space:]]*#[0-9]+' '${DNSMASQ_CONF_DIR}' 2>/dev/null || true" \
        | grep -v '#53$' || true
}

# Public wrapper: drop induction mid-test so recovery can be asserted while the
# script is still running. Teardown then finds nothing left to do.
remove_induction() { _t2_remove_rules; }

# Can the UDM reach the AdGuard host at all?
#
# This is what separates the two Tier 2 failure modes. Both present to `dig` as
# TIMEOUT — neither a REJECTed nor a DROPped query produces a ->>HEADER<<- line,
# so the RCODE is identical (verified against real dig output). What differs is
# whether the host is otherwise reachable:
#
#   container-down  udp/53 only is blocked; ICMP and SSH still work
#   host-down       all traffic to the address is blocked; nothing works
udm_can_reach_adguard() {
    udm "ping -c 1 -W 2 '${ADGUARD_IP}' >/dev/null 2>&1"
}

# Corroborating probe, issued from the UDM exactly as the daemon issues it.
# Used to assert the suppression precondition really holds before the test
# draws any conclusion from it.
corroborate_rcode_from_udm() {
    local label; label="$(random_label)"
    udm "dig @'${CORROBORATE_SERVER}' '${label}.${CORROBORATE_ZONE}' A +tries=1 +time='${PROBE_TIMEOUT}' 2>/dev/null" \
        | { out="$(cat)"; parse_rcode "$out"; }
}

# Standard Tier 2 preflight. Refuses rather than reports, because every
# assertion downstream is meaningless if these do not hold.
t2_preflight() {
    require_udm
    require_no_leftovers

    if ! daemon_running; then
        echo "ERROR: dns-failover daemon is not running on the UDM. Nothing to test." >&2
        exit 2
    fi
    if standby_bound; then
        echo "ERROR: ${FAILOVER_IP} is already bound on ${LAN_IF} before the test started." >&2
        echo "       Either a previous run left it stranded or failover is genuinely engaged." >&2
        exit 2
    fi
    if ! adguard_answers; then
        echo "ERROR: AdGuard at ${ADGUARD_IP} is not answering from this workstation." >&2
        echo "       Tier 2 requires a healthy AdGuard: it induces failure on the UDM only." >&2
        exit 2
    fi
}
