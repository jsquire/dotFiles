#!/bin/bash
#
# test-lib.sh — Tier 1: the Tier 2 plumbing, exercised offline.
#
# Runs against a fake UDM: `udm()` is redefined after sourcing lib.sh so that
# iptables operations act on a local file. No SSH, no network, no UDM.
#
# Everything asserted here is load-bearing and silently breakable:
#
#   * Upstream enumeration. The suppression test's validity rests entirely on
#     this being complete. dnsmasq runs with `all-servers`, so one missed
#     upstream leaves the WAN outage un-induced and the test passes having
#     tested nothing at all. The `server=` forms are fiddly enough
#     (`server=/domain/addr`, `server=addr#port`, IPv6) that a parsing slip is
#     the most likely way that happens.
#
#   * Cleanup verification. A rule whose deletion silently failed strands the
#     UDM believing AdGuard is down, pinning the standby up and letting clients
#     bypass AdGuard with no symptom. Cleanup must therefore CONFIRM removal
#     with -C rather than trust the exit status of -D, and must report loudly
#     when it could not. That failure path never executes in a healthy run, so
#     without this test it is never exercised at all.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/lib.sh"

hdr "Tier 1 — Tier 2 plumbing (offline, fake UDM)"

FAKE="$(mktemp -d -t dns-failover-lib.XXXXXX)"
trap 'rm -rf "$FAKE"' EXIT

: >"$FAKE/iptables"
: >"$FAKE/ip6tables"
: >"$FAKE/resolv"
mkdir -p "$FAKE/dnsmasq"
FAKE_DELETE_FAILS=0

# ------------------------------------------------------------------
# Fake UDM
# ------------------------------------------------------------------

udm() {
    local cmd="$*"

    case "$cmd" in
        *iptables-save*)
            # Matches ip6tables-save too; emit both when both are asked for.
            case "$cmd" in
                *ip6tables-save*) cat "$FAKE/iptables" "$FAKE/ip6tables" ;;
                *)                cat "$FAKE/iptables" ;;
            esac
            return 0
            ;;
        *"command -v ip6tables"*) return 0 ;;
    esac

    local bin op rule store
    bin="${cmd%% *}"
    local tail_="${cmd#* }"
    op="${tail_%% *}"
    rule="${tail_#* }"

    case "$bin" in
        iptables)  store="$FAKE/iptables" ;;
        ip6tables) store="$FAKE/ip6tables" ;;
        *)
            # Anything else in this harness is an unmodelled call; make it loud
            # rather than let it quietly succeed.
            echo "fake udm: unmodelled command: $cmd" >&2
            return 127
            ;;
    esac

    case "$op" in
        -I) printf -- '-A %s\n' "$rule" >>"$store"; return 0 ;;
        -C) grep -qxF -- "-A $rule" "$store" ;;
        -D)
            [ "$FAKE_DELETE_FAILS" -eq 1 ] && return 0    # claims success, does nothing
            grep -vxF -- "-A $rule" "$store" >"$store.tmp" || true
            mv "$store.tmp" "$store"
            return 0
            ;;
        *) return 0 ;;
    esac
}

# Component tests, not lifecycle tests: detach the EXIT trap t2_init installs so
# a real teardown (which would try to SSH) never runs.
t2_init
trap 'rm -rf "$FAKE" "$T2_STATE"' EXIT INT TERM

# ------------------------------------------------------------------
hdr "Upstream enumeration"
# ------------------------------------------------------------------

RESOLV_FILE="$FAKE/resolv"
DNSMASQ_CONF_DIR="$FAKE/dnsmasq"

cat >"$FAKE/resolv" <<'EOF'
nameserver 9.9.9.9
nameserver 149.112.112.112
nameserver 2620:fe::fe
EOF

cat >"$FAKE/dnsmasq/main.conf" <<'EOF'
bind-dynamic
no-hosts
cache-size=10000
all-servers
server=1.1.1.1
server=/lan/192.168.1.1
server=8.8.8.8#53
server=2606:4700:4700::1111
server=/corp.example/10.0.0.53
host-record=nas.lan,192.168.1.100
EOF

# The enumerating function shells out through udm(), which the fake above only
# models for iptables. Point it at the real files instead for this section.
udm() { eval "$*"; }

mapfile -t GOT < <(enumerate_upstreams)

expected=(1.1.1.1 10.0.0.53 149.112.112.112 192.168.1.1 2606:4700:4700::1111 2620:fe::fe 8.8.8.8 9.9.9.9)
assert_eq "enumerates every upstream from both sources" \
    "${expected[*]}" "${GOT[*]}"

for want in "1.1.1.1:server=addr" \
            "192.168.1.1:server=/domain/addr" \
            "10.0.0.53:server=/domain/addr" \
            "8.8.8.8:server=addr#port" \
            "2606:4700:4700::1111:IPv6 server=" \
            "2620:fe::fe:IPv6 nameserver"; do
    addr="${want%:*}"; form="${want##*:}"
    if printf '%s\n' "${GOT[@]}" | grep -qxF "$addr"; then
        _pass "parsed ${form} → ${addr}"
    else
        _fail "failed to parse ${form} (expected ${addr})"
        note "got: ${GOT[*]}"
    fi
done

# ------------------------------------------------------------------
hdr "Address-family classification"
# ------------------------------------------------------------------

assert_eq "IPv4 literal"            "inet"  "$(upstream_family 9.9.9.9)"
assert_eq "IPv6 literal"            "inet6" "$(upstream_family 2620:fe::fe)"
assert_eq "IPv6 full form"          "inet6" "$(upstream_family 2606:4700:4700::1111)"
assert_eq "IPv4 in RFC1918 space"   "inet"  "$(upstream_family 192.168.1.1)"

v6=0
for u in "${GOT[@]}"; do
    [ "$(upstream_family "$u")" = "inet6" ] && v6=$((v6 + 1))
done
assert_eq "both IPv6 upstreams classified as inet6" "2" "$v6"

# ------------------------------------------------------------------
hdr "Non-standard transport detection"
# ------------------------------------------------------------------
#
# A --dport 53 rule silently misses an upstream on any other port, which is the
# exact false confidence the suppression gate exists to prevent.

assert_eq "port 53 explicitly stated is not flagged" \
    "" "$(enumerate_nonstandard_transports)"

printf 'server=1.0.0.1#853\n' >>"$FAKE/dnsmasq/main.conf"
if [ -n "$(enumerate_nonstandard_transports)" ]; then
    _pass "DoT upstream on #853 is detected"
else
    _fail "DoT upstream on #853 was NOT detected"
fi
sed -i '/#853/d' "$FAKE/dnsmasq/main.conf"

# ------------------------------------------------------------------
hdr "Rule lifecycle"
# ------------------------------------------------------------------

# Restore the iptables-modelling fake.
udm() {
    # Drain stdin, exactly as ssh does. This fake previously did not, which is
    # why the suite stayed green while the real cleanup loop lost every rule
    # after the first: inside `while read ... done <rules`, stdin is the rules
    # file, and the first ssh ate the rest of it. A fake that is more polite
    # with stdin than the thing it stands in for cannot detect that class of
    # bug at all.
    if [ ! -t 0 ]; then cat >/dev/null 2>&1 || true; fi
    local cmd="$*"
    case "$cmd" in
        *iptables-save*)
            case "$cmd" in
                *ip6tables-save*) cat "$FAKE/iptables" "$FAKE/ip6tables" ;;
                *)                cat "$FAKE/iptables" ;;
            esac
            return 0 ;;
    esac
    local bin op rule store tail_
    bin="${cmd%% *}"; tail_="${cmd#* }"; op="${tail_%% *}"; rule="${tail_#* }"
    case "$bin" in
        iptables)  store="$FAKE/iptables" ;;
        ip6tables) store="$FAKE/ip6tables" ;;
        *) return 127 ;;
    esac
    case "$op" in
        -I) printf -- '-A %s\n' "$rule" >>"$store"; return 0 ;;
        -C) grep -qxF -- "-A $rule" "$store" ;;
        -D) [ "$FAKE_DELETE_FAILS" -eq 1 ] && return 0
            grep -vxF -- "-A $rule" "$store" >"$store.tmp" || true
            mv "$store.tmp" "$store"; return 0 ;;
        *) return 0 ;;
    esac
}

: >"$FAKE/iptables"; : >"$FAKE/ip6tables"; : >"$T2_STATE/rules"

induce_rule iptables  "-d 192.168.1.99 -p udp --dport 53" "DROP" >/dev/null
induce_rule ip6tables "-d 2620:fe::fe -p udp --dport 53"  "DROP" >/dev/null

assert_eq "both rules recorded for teardown" "2" "$(wc -l <"$T2_STATE/rules")"

if grep -qF "$INDUCE_TAG" "$FAKE/iptables" && grep -qF "$INDUCE_TAG" "$FAKE/ip6tables"; then
    _pass "rules are tagged in both address families"
else
    _fail "rules are not tagged in both address families"
fi

# ------------------------------------------------------------------
hdr "Leftover detection covers both address families"
# ------------------------------------------------------------------

leftovers="$(induced_leftovers)"
assert_eq "leftover scan finds both rules" "2" "$(printf '%s\n' "$leftovers" | grep -cF "$INDUCE_TAG")"

# An orphaned ip6tables rule is exactly as harmful as a v4 one and much easier
# to overlook, so it must be found on its own.
: >"$FAKE/iptables"
assert_eq "IPv6-only leftover is still found" \
    "1" "$(induced_leftovers | grep -cF "$INDUCE_TAG")"

# ------------------------------------------------------------------
hdr "Cleanup verifies removal rather than assuming it"
# ------------------------------------------------------------------

: >"$FAKE/iptables"; : >"$FAKE/ip6tables"; : >"$T2_STATE/rules"
induce_rule iptables  "-d 192.168.1.99 -p udp --dport 53" "DROP" >/dev/null
induce_rule ip6tables "-d 2620:fe::fe -p udp --dport 53"  "DROP" >/dev/null

if _t2_remove_rules 2>/dev/null; then
    _pass "cleanup reports success when rules really are gone"
else
    _fail "cleanup reported failure on a clean removal"
fi
assert_eq "no rules remain in either family" "" "$(cat "$FAKE/iptables" "$FAKE/ip6tables")"
assert_eq "teardown list emptied" "0" "$(wc -c <"$T2_STATE/rules")"

# Now sabotage deletion: -D claims success but removes nothing. This is the
# path that never runs in a healthy test and would otherwise never be
# exercised. Trusting -D's exit status here would report a clean teardown while
# leaving the UDM blind to AdGuard.
: >"$FAKE/iptables"; : >"$T2_STATE/rules"
induce_rule iptables "-d 192.168.1.99 -p udp --dport 53" "DROP" >/dev/null
FAKE_DELETE_FAILS=1

if _t2_remove_rules 2>/dev/null; then
    _fail "cleanup reported SUCCESS while the rule is still installed"
    note "this is the silent-strand failure mode; -C verification is not working"
else
    _pass "cleanup detects that a rule survived its own deletion"
fi

err="$(_t2_remove_rules 2>&1 >/dev/null || true)"
if printf '%s' "$err" | grep -q 'CLEANUP FAILED'; then
    _pass "cleanup failure is reported loudly"
else
    _fail "cleanup failure produced no visible message"
fi
if printf '%s' "$err" | grep -q -- '-D OUTPUT'; then
    _pass "failure message includes the exact removal command"
else
    _fail "failure message does not include a runnable removal command"
fi

FAKE_DELETE_FAILS=0
_t2_remove_rules >/dev/null 2>&1

# ------------------------------------------------------------------
# Cleanup removes EVERY rule, not just the first
# ------------------------------------------------------------------
#
# REGRESSION. `udm` is ssh and ssh reads stdin. In `while read ... done <rules`
# the loop's stdin is the rules file, so the first ssh drained the remainder and
# the loop ended after one iteration. Found on a live UDM: two rules induced
# (udp, then tcp), udp removed, tcp stranded on the router — and silently, since
# the -C verification only runs for rules the loop reaches.

hdr "cleanup drains every rule, not just the first"

: >"$FAKE/iptables"; : >"$FAKE/ip6tables"; : >"$T2_STATE/rules"

induce_rule iptables "-d 192.168.1.99 -p udp --dport 53" "REJECT" >/dev/null
induce_rule iptables "-d 192.168.1.99 -p tcp --dport 53" "REJECT" >/dev/null
induce_rule iptables "-d 192.168.1.99 -p udp --dport 853" "REJECT" >/dev/null

before="$(wc -l <"$FAKE/iptables")"
assert_eq "three induction rules are in place" 3 "$before"

_t2_remove_rules >/dev/null 2>&1

# NOTE: `grep -c` prints 0 AND exits 1 when there are no matches, so the
# obvious `|| echo 0` fallback appends a second zero and yields "0\n0".
after="$(grep -c . "$FAKE/iptables" 2>/dev/null || true)"
assert_eq "all three rules are removed, not merely the first" 0 "$after"

refute "no tcp rule is left stranded" grep -q -- '-p tcp' "$FAKE/iptables"
refute "the rules ledger is cleared" test -s "$T2_STATE/rules"

# ------------------------------------------------------------------
# The watchdog caps BOUND time, not wall-clock time
# ------------------------------------------------------------------
#
# REGRESSION. The watchdog was `sleep "$ceiling"`, armed at induction, so it
# fired on elapsed test duration. test-suppression.sh spends ~52s deliberately
# holding the WAN down with the standby correctly unbound; on a run where the
# standby was bound for 33s the watchdog fired anyway, tore down induction
# mid-test, and forced exit 3 on a run whose every assertion passed.

hdr "watchdog measures bound time, not elapsed time"

WD="$(mktemp -d)"
: >"$WD/rules"

MAX_ENGAGED_SECS=6
RECOVER_DEADLINE=2
T2_STATE="$WD"

# Standby is never bound: the watchdog must stay silent no matter how long the
# "test" runs. Ten seconds is comfortably past the 6s ceiling.
standby_bound() { return 1; }

_t2_start_watchdog
sleep 10
_t2_stop_watchdog

refute "watchdog stays silent while the standby is never bound" \
    test -f "$WD/watchdog_fired"

# Guard the guard: with the standby permanently bound it MUST fire, or the
# assertion above would pass simply because the watchdog never works.
rm -f "$WD/watchdog_fired" "$WD/disarmed"
standby_bound() { return 0; }
udm() { return 0; }

# 14s, not 10s: with a 5s poll and a 6s ceiling the counter first crosses at
# t=10s, which is exactly when the previous case stopped watching. Sampling at
# the instant of the transition is a race, and a flaky guard is not a guard.
_t2_start_watchdog
sleep 14
_t2_stop_watchdog

assert "watchdog fires when the standby really is bound past the ceiling" \
    test -f "$WD/watchdog_fired"

rm -rf "$WD"

summary
