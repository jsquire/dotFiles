#!/bin/bash
#
# test-hardening.sh — NON-DISRUPTIVE, offline, Tier 1.
#
# Asserts the three hardening properties of the install and uninstall paths:
# kill-target identity, SSH host key policy, and install-time supply chain.
#
# The bulk of it is the process-identity contract that install.sh and
# uninstall.sh use before sending a signal.
#
# Why this test exists. Both scripts run as root on the router and send SIGTERM
# and then SIGKILL to a PID read out of /run/adguard-failover.pid, plus every
# PID that `pgrep -f` matches. Neither input is trustworthy on its own:
#
#   - The PID file lives on tmpfs but outlives the process that wrote it, and
#     PIDs are recycled. A stale file naming a recycled PID gets an unrelated
#     process killed.
#   - `pgrep -f` matches a substring of the whole command line, so an operator
#     with `tail -f /data/adguard-failover/dns-failover.sh` or an editor open on
#     the file is a match and gets killed for it.
#
# The contract that fixes both is positional rather than substring:
#
#   A PID is ours if argv[0] is one of our paths, OR argv[0] is a shell and
#   argv[1] is one of our paths.
#
# Two paths are owned, and this is the part that is easy to get wrong:
#
#   /data/on_boot.d/15-adguard-failover.sh   (boot hook, and the supervisor)
#   /data/adguard-failover/dns-failover.sh   (the daemon)
#
# The supervisor is a backgrounded subshell of the boot hook. A forked subshell
# inherits its parent's argv, so the supervisor's /proc/<pid>/cmdline reads
# "/bin/bash /data/on_boot.d/15-adguard-failover.sh" and contains no mention of
# dns-failover.sh at all. An identity check written against the daemon path
# alone matches nothing, silently declines to stop the supervisor, and lets it
# relaunch the daemon after uninstall has already reported success — at which
# point uninstall removes a standby address that is re-added seconds later.
#
# That exact mistake was made and caught during implementation. Case 7 below
# pins the behaviour so it cannot be reintroduced.
#
# The contract is restated here rather than imported. A test that shares an
# implementation with the thing it tests changes its expectations in lockstep
# and keeps passing through a semantic change — the same reasoning that keeps
# the dig parsing contract duplicated in lib.sh.

VERIFY_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$VERIFY_DIR/.." && pwd)"
# shellcheck source=lib.sh
. "$VERIFY_DIR/lib.sh"

hdr "test-hardening.sh — install/uninstall hardening"

TMP="$(mktemp -d)"
cleanup() {
    # Reap fixtures by identity, using the very contract under test. Anything
    # still alive is one of ours by construction — they all live under $TMP.
    for p in ${FIXTURE_PIDS:-}; do
        kill -KILL "$p" 2>/dev/null || true
    done
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

FIXTURE_PIDS=""

# ------------------------------------------------------------------
# The contract, restated
# ------------------------------------------------------------------

# is_ours <pid> <owned-path>...
is_ours() {
    local pid="$1"; shift
    [ -n "$pid" ] || return 1
    [ -r "/proc/$pid/cmdline" ] || return 1

    local a0 a1 owned
    a0=$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | sed -n 1p)
    a1=$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | sed -n 2p)

    for owned in "$@"; do
        [ "$a0" = "$owned" ] && return 0
        case "${a0##*/}" in
            bash|sh|ash|dash)
                [ "$a1" = "$owned" ] && return 0
                ;;
        esac
    done
    return 1
}

cmdline_of() { tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null; }

# ------------------------------------------------------------------
# Fixtures — real processes, shaped exactly like the real ones
# ------------------------------------------------------------------
#
# HOOK is shaped like boot-hook.sh: it backgrounds a subshell and writes that
# subshell's PID to a file, which is precisely how the supervisor comes to have
# the hook's argv rather than its own.

HOOK="$TMP/15-adguard-failover.sh"
DAEMON="$TMP/dns-failover.sh"

cat >"$HOOK" <<'EOF'
#!/bin/bash
(
    while true; do sleep 0.2; done
) </dev/null >/dev/null 2>&1 &
echo "$!" >"$(dirname "$0")/supervisor.pid"
EOF

cat >"$DAEMON" <<'EOF'
#!/bin/bash
trap 'exit 0' TERM
while true; do sleep 0.2; done
EOF

chmod +x "$HOOK" "$DAEMON"

"$HOOK"
SUPERVISOR_PID="$(cat "$TMP/supervisor.pid")"

"$DAEMON" & DAEMON_PID=$!

# An unrelated process, standing in for a recycled PID.
sleep 300 & UNRELATED_PID=$!

# An operator reading the daemon file. `pgrep -f` matches this; the contract
# must not.
tail -f "$DAEMON" >/dev/null 2>&1 & TAIL_PID=$!

FIXTURE_PIDS="$SUPERVISOR_PID $DAEMON_PID $UNRELATED_PID $TAIL_PID"

# Give every fixture time to exist in /proc with its final argv.
sleep 1

info "supervisor  pid=$SUPERVISOR_PID  cmdline: $(cmdline_of "$SUPERVISOR_PID")"
info "daemon      pid=$DAEMON_PID  cmdline: $(cmdline_of "$DAEMON_PID")"
info "unrelated   pid=$UNRELATED_PID  cmdline: $(cmdline_of "$UNRELATED_PID")"
info "tail        pid=$TAIL_PID  cmdline: $(cmdline_of "$TAIL_PID")"

# ------------------------------------------------------------------
# Classification
# ------------------------------------------------------------------

hdr "Classification"

assert "the supervisor is recognised as ours" \
    is_ours "$SUPERVISOR_PID" "$HOOK" "$DAEMON"

assert "the daemon is recognised as ours" \
    is_ours "$DAEMON_PID" "$HOOK" "$DAEMON"

refute "an unrelated process is not ours (the recycled-PID case)" \
    is_ours "$UNRELATED_PID" "$HOOK" "$DAEMON"

refute "a tail(1) reading the daemon file is not ours (the pgrep -f case)" \
    is_ours "$TAIL_PID" "$HOOK" "$DAEMON"

refute "a PID that does not exist is not ours" \
    is_ours 4194303 "$HOOK" "$DAEMON"

refute "an empty PID is not ours" \
    is_ours "" "$HOOK" "$DAEMON"

# ------------------------------------------------------------------
# The trap that was actually hit
# ------------------------------------------------------------------

hdr "Supervisor argv inheritance"

assert_eq "the supervisor's cmdline does NOT mention the daemon path" \
    "absent" \
    "$(cmdline_of "$SUPERVISOR_PID" | grep -q -- "$DAEMON" && echo present || echo absent)"

refute "checking ONLY the daemon path would fail to recognise the supervisor" \
    is_ours "$SUPERVISOR_PID" "$DAEMON"

note "This is why both paths are owned. Checking the daemon path alone leaves"
note "the supervisor running, and it relaunches the daemon after uninstall has"
note "already reported success."

assert "pgrep -f on the daemon path matches the unrelated tail, as expected" \
    bash -c 'pgrep -f "$1" 2>/dev/null | grep -qx "$2"' _ "$DAEMON" "$TAIL_PID"

note "pgrep -f alone is therefore not a safe kill list. The positional check is"
note "what makes the sweep safe."

# ------------------------------------------------------------------
# Signalling behaviour
# ------------------------------------------------------------------
#
# stop_pid must refuse to signal anything that fails the identity check, and
# must stop what does pass it.

hdr "stop_pid"

stop_pid() {
    local pid="$1"; shift
    is_ours "$pid" "$@" || return 0
    kill -TERM "$pid" 2>/dev/null || true
    local n=0
    while [ "$n" -lt 8 ] && kill -0 "$pid" 2>/dev/null; do
        sleep 1
        n=$((n + 1))
    done
    if kill -0 "$pid" 2>/dev/null && is_ours "$pid" "$@"; then
        kill -KILL "$pid" 2>/dev/null || true
    fi
}

stop_pid "$UNRELATED_PID" "$HOOK" "$DAEMON"
assert "stop_pid leaves an unrelated process alive" \
    kill -0 "$UNRELATED_PID"

stop_pid "$TAIL_PID" "$HOOK" "$DAEMON"
assert "stop_pid leaves a tail(1) on the daemon path alive" \
    kill -0 "$TAIL_PID"

stop_pid "$DAEMON_PID" "$HOOK" "$DAEMON"
sleep 0.5
refute "stop_pid stops the daemon" \
    kill -0 "$DAEMON_PID"

stop_pid "$SUPERVISOR_PID" "$HOOK" "$DAEMON"
sleep 0.5
refute "stop_pid stops the supervisor" \
    kill -0 "$SUPERVISOR_PID"

# ------------------------------------------------------------------
# Static assertions on the shipped scripts
# ------------------------------------------------------------------
#
# The contract above is only worth anything if the deployed scripts implement
# it. These assertions are deliberately shallow — they catch a regression to the
# patterns that were removed, not every possible way of getting it wrong.

hdr "Shipped scripts"

INSTALL="$REPO_DIR/install/install.sh"
UNINSTALL="$REPO_DIR/uninstall/uninstall.sh"

# Comment lines are stripped first: both scripts explain in prose why the
# process-group kill was removed, and that explanation must not read as a
# regression.
group_kill_in_code() {
    grep -vE '^[[:space:]]*#' "$1" | grep -qE 'kill +-(TERM|KILL) +-"'
}

refute "uninstall.sh no longer sends a negative-PID process-group kill" \
    group_kill_in_code "$UNINSTALL"

note "A backgrounded subshell in non-interactive bash is not a process-group"
note "leader (verified: pid=280341 pgid=280338), so the negative PID named an"
note "unrelated group. It only appeared to work because the failed call fell"
note "through to the plain kill after it."

refute "install.sh does not send a negative-PID process-group kill either" \
    group_kill_in_code "$INSTALL"

assert "uninstall.sh reads /proc/<pid>/cmdline before signalling" \
    grep -q '/proc/\$1/cmdline' "$UNINSTALL"

assert "install.sh reads /proc/<pid>/cmdline before signalling" \
    grep -q '/proc/\\\$1/cmdline' "$INSTALL"

assert "uninstall.sh owns the boot hook path, not just the daemon path" \
    grep -q 'HOOK_PATH=/data/on_boot.d/15-adguard-failover.sh' "$UNINSTALL"

assert "install.sh checks the boot hook path, since that is the supervisor's argv" \
    grep -q 'HOOK_PATH=/data/on_boot.d/15-adguard-failover.sh' "$INSTALL"

assert "uninstall.sh sweeps both owned paths" \
    grep -q 'OWNED_PATHS="\$HOOK_PATH \$DAEMON_PATH"' "$UNINSTALL"

# ------------------------------------------------------------------
# SSH host key policy
# ------------------------------------------------------------------
#
# Not process hygiene, but the same class: a default that trades a real
# guarantee for one less prompt, in a script that copies executables to a root
# shell on the router.

hdr "SSH host key policy"

refute "install.sh does not silently trust unknown host keys" \
    grep -q 'StrictHostKeyChecking=accept-new' "$INSTALL"

assert "install.sh uses StrictHostKeyChecking=ask" \
    grep -q 'StrictHostKeyChecking=ask' "$INSTALL"

# ------------------------------------------------------------------
# Install-time supply chain
# ------------------------------------------------------------------
#
# The installer previously piped an unpinned HEAD of a third-party script into
# a root shell on the router. The only thing that script does which matters is
# write /etc/systemd/system/udm-boot.service and enable it, so the unit is
# vendored and the fetch is gone.
#
# There is nothing to pin, because there is nothing to fetch. These assertions
# exist to stop the fetch coming back.

hdr "Install-time supply chain"

UNIT="$REPO_DIR/install/udm-boot.service"

pipes_to_shell() {
    grep -vE '^[[:space:]]*#' "$1" | grep -qE 'curl[^|]*\|[[:space:]]*(/bin/)?(ba)?sh'
}

refute "install.sh does not pipe a download into a shell" \
    pipes_to_shell "$INSTALL"

refute "install.sh does not fetch anything from the network at all" \
    bash -c 'grep -vE "^[[:space:]]*#" "$1" | grep -qE "\b(curl|wget)\b"' _ "$INSTALL"

assert "the udm-boot systemd unit is vendored in the repo" \
    test -f "$UNIT"

assert "the vendored unit records the upstream commit it came from" \
    grep -qE 'unifi-common @ [0-9a-f]{40}' "$UNIT"

assert "the vendored unit keeps upstream's service name, so hooks cannot run twice" \
    grep -q 'WantedBy=multi-user.target' "$UNIT"

assert "the vendored unit runs /data/on_boot.d" \
    grep -q '/data/on_boot.d' "$UNIT"

assert "install.sh installs the vendored unit" \
    grep -q 'install/udm-boot.service' "$INSTALL"

assert "install.sh leaves an already-enabled udm-boot.service alone" \
    grep -q "systemctl is-enabled udm-boot.service" "$INSTALL"


# ------------------------------------------------------------------
# Vendored unit — digest, offline
# ------------------------------------------------------------------
#
# The claim being asserted is narrow and exact: every directive in our copy is
# upstream's, and the only difference is the comment header. Upstream's file
# contains no comment lines at all, so stripping `^#` from ours must reproduce
# upstream's whole file byte for byte.
#
# The expected digest is a PINNED LITERAL. It is never fetched at runtime. A
# test that reaches the network to learn what it expects has no fixed
# expectation: it fails when GitHub is down, and — far worse — it would silently
# start accepting an upstream change as correct, which is the exact opposite of
# what pinning is for.
#
# TO REFRESH (a deliberate manual act, not something a test run does):
#
#   curl -fsSL https://raw.githubusercontent.com/unifi-utilities/unifi-common/<commit>/udm-boot.service \
#     | sha256sum
#
# then update BOTH the constant below and the commit recorded in the unit's
# header, and diff the two files by eye before trusting the new digest.
#
# Pinned at unifi-common @ 216dee314248afb5a3c279e5b25112eff083c107.
UPSTREAM_UNIT_SHA256=19d900a0cb3e5a1f632a2d5a8373b3ac9d0542f89acb1eb451eb1c475fecf5a1

hdr "Vendored unit matches upstream (offline digest)"

unit_digest() { grep -v '^#' "$UNIT" | sha256sum | cut -d' ' -f1; }

assert_eq "comment-stripped unit reproduces upstream byte for byte" \
    "$UPSTREAM_UNIT_SHA256" "$(unit_digest)"

assert "the digest constant records which upstream commit it pins" \
    grep -qE 'unifi-common @ [0-9a-f]{40}\.$' "$0"

# The digest is only meaningful if the comment header is genuinely comments —
# a stray directive inside the header would be stripped from the hash and
# shipped to the router unnoticed.
assert "no unit directive hides among the stripped comment lines" \
    bash -c 'grep -c "^#" "$1" | grep -qv "^0$"' _ "$UNIT"

refute "the vendored unit no longer claims to be byte-identical as a file" \
    grep -q 'byte-for-byte upstream' "$UNIT"

refute "install.sh no longer claims the unit is vendored verbatim" \
    grep -q 'vendored verbatim' "$INSTALL"

# ------------------------------------------------------------------
# Helper vocabulary — every helper used is defined in the same file
# ------------------------------------------------------------------
#
# This is the class that shipped `info` undefined in install.sh: a helper name
# borrowed from lib.sh while editing a branch that no test executed. `bash -n`
# parses but does not resolve command names, and ShellCheck has no undefined-
# function check, so nothing in the toolchain catches it.
#
# Execution alone is not a reliable detector either. On a workstation with GNU
# texinfo installed, an undefined `info` resolves to /usr/bin/info and fails
# with a texinfo error rather than "command not found" — the symptom depends on
# what happens to be installed. This static check does not.

hdr "Helper vocabulary is self-contained"

HELPERS='say ok warn die info note hdr'

helpers_used() {
    # Helper invocations only ever appear at the start of a command: line start,
    # or after ;, &&, ||, {, ( or a pipe. This deliberately does not match inside
    # a quoted remote command string, where these words would be UDM-side.
    local f="$1" h
    for h in $HELPERS; do
        grep -vE '^[[:space:]]*#' "$f" \
            | grep -qE "(^|;|&&|\|\||\{|\()[[:space:]]*$h[[:space:]]+" && echo "$h"
    done
    return 0
}

helper_defined() { grep -qE "^[[:space:]]*$2\(\)" "$1"; }

for f in "$INSTALL" "$UNINSTALL"; do
    name=$(basename "$f")
    for h in $(helpers_used "$f"); do
        assert "$name: helper '$h' is used and defined in the same file" \
            helper_defined "$f" "$h"
    done
done

# Guard the guard: if the extractor silently found nothing, every assertion
# above would vacuously pass and the check would be decoration.
extractor_found_something() { [ -n "$(helpers_used "$1")" ]; }

assert "the helper extractor actually found helpers in install.sh" \
    extractor_found_something "$INSTALL"

assert "the helper extractor actually found helpers in uninstall.sh" \
    extractor_found_something "$UNINSTALL"

# ------------------------------------------------------------------
# IP matching must be address-anchored
# ------------------------------------------------------------------
#
# REGRESSION GUARD. The DHCP-claim gate shipped as a bare
# `grep -- '192.168.1.2'`. That substring is also present in 192.168.1.20,
# 192.168.1.254 and 192.168.1.255, and since the dhcp-range ceiling on a /24 is
# almost always .254 the gate reported a phantom reservation on every real
# network. It was found on a live UDM, not by this suite.
#
# It then turned out to exist in TWO places — install.sh and test-normal.sh —
# and the second was missed because the by-hand audit scoped tests/ to lib.sh
# alone. Hence a static check over the whole tree: remembering to look in every
# directory is exactly the step that failed.
#
# The rule: an IP-valued variable interpolated into a grep pattern must be
# anchored. Either it carries the _RE suffix (dots escaped, bounded by
# [^0-9.]), or it is not a pattern at all.

hdr "IP matching is address-anchored"

SCAN_ROOT="$REPO_DIR"

# Command-position greps whose pattern interpolates a bare IP variable.
unanchored_ip_greps() {
    grep -rnE "grep[^|;]*'[^']*\\\$\{?(FAILOVER_IP|ADGUARD_IP)\}?'" \
        --include='*.sh' "$SCAN_ROOT" 2>/dev/null |
        grep -v '_RE' || true
}

found="$(unanchored_ip_greps)"
if [ -n "$found" ]; then
    _fail "an unanchored IP grep is present"
    while IFS= read -r line; do note "  $line"; done <<<"$found"
else
    _pass "no unanchored IP grep anywhere in the tree"
fi

# Guard the guard. The detector must actually fire on the exact shape that
# shipped, or its silence means nothing. Build the offending line at runtime so
# the fixture cannot be "fixed" by a well-meaning search-and-replace.
# NOTE: deliberately no `trap ... EXIT` here. This script already installs
# `trap cleanup EXIT` (top of file) to reap its fixture processes. Overriding
# that trap orphaned a tail(1), which held the suite's stdout open and hung the
# run indefinitely. Clean up inline instead.
scratch="$(mktemp -d)"

# The variable name is assembled at runtime rather than written literally. Spelt
# out inline, this fixture is itself an unanchored IP grep in command position,
# so the detector matched its own test data and reported a defect that did not
# exist in any shipping code.
ipvar='FAILOVER''_IP'

{
    printf '%s\n' '#!/bin/bash'
    printf 'udm "grep -rqs -- %s$%s%s /run/dnsmasq.dhcp.conf.d/"\n' "'" "$ipvar" "'"
} >"$scratch/regression.sh"

detector_fires_on() ( SCAN_ROOT="$scratch"; [ -n "$(unanchored_ip_greps)" ] )

assert "the detector fires on the exact form that shipped" \
    detector_fires_on

# And it must NOT fire on the anchored replacement, or it is just noise that
# will be silenced rather than obeyed.
{
    printf '%s\n' '#!/bin/bash'
    printf 'udm "grep -rEqs -- %s(^|[^0-9.])${FAILOVER_IP_RE}([^0-9.]|\\$)%s /run/dnsmasq.dhcp.conf.d/"\n' "'" "'"
} >"$scratch/regression.sh"

refute "the detector stays quiet on the anchored form" \
    detector_fires_on

rm -rf "$scratch"

# ------------------------------------------------------------------
# Killing the supervisor must take the daemon with it
# ------------------------------------------------------------------
#
# REGRESSION. The daemon ran in the foreground of the supervisor subshell. A
# non-interactive bash defers traps until the foreground child returns and does
# not forward the signal, so `kill <supervisor>` — exactly what install.sh does
# before starting a fresh copy — left the daemon reparented to init. Found on
# the UDM after a re-install: two daemons on independent schedules, every log
# line duplicated, both managing the same standby address.
#
# This runs the REAL boot-hook.sh against a stub daemon, with only its hardcoded
# paths repointed at a scratch directory.

hdr "supervisor stop takes the daemon with it"

SUP="$(mktemp -d)"

sed -e "s|^INSTALL_DIR=.*|INSTALL_DIR=\"$SUP\"|" \
    -e "s|^PIDFILE=.*|PIDFILE=\"$SUP/sup.pid\"|" \
    "$REPO_DIR/scripts/boot-hook.sh" >"$SUP/boot-hook.sh"
chmod +x "$SUP/boot-hook.sh"

# Guard the rewrite. If sed matched nothing the test would run against the real
# /data paths, find no daemon, and pass for entirely the wrong reason.
assert "the boot-hook copy is repointed at the scratch dir" \
    grep -qF "INSTALL_DIR=\"$SUP\"" "$SUP/boot-hook.sh"
assert "the boot-hook copy has no /data/adguard-failover left in its paths" \
    sh -c "! grep -qE '^(INSTALL_DIR|PIDFILE)=.*/data/' '$SUP/boot-hook.sh'"

cat >"$SUP/dns-failover.sh" <<'STUBEOF'
#!/bin/bash
trap 'exit 0' TERM INT
while true; do sleep 1 & wait $!; done
STUBEOF
chmod +x "$SUP/dns-failover.sh"

"$SUP/boot-hook.sh"
sleep 2

sup_pid="$(cat "$SUP/sup.pid" 2>/dev/null || true)"
assert "the supervisor started and wrote a PID file" test -n "$sup_pid"

# Locate the daemon by its exact path, not by name.
find_stub_daemon() {
    local p pid a0 a1
    for p in /proc/[0-9]*; do
        pid="${p#/proc/}"
        a0="$(tr '\0' '\n' <"/proc/$pid/cmdline" 2>/dev/null | sed -n 1p)"
        a1="$(tr '\0' '\n' <"/proc/$pid/cmdline" 2>/dev/null | sed -n 2p)"
        if [ "$a0" = "$SUP/dns-failover.sh" ] || [ "$a1" = "$SUP/dns-failover.sh" ]; then
            printf '%s\n' "$pid"; return 0
        fi
    done
    return 1
}

daemon_pid="$(find_stub_daemon || true)"
assert "the supervisor launched the daemon" test -n "$daemon_pid"

FIXTURE_PIDS="$FIXTURE_PIDS ${sup_pid:-} ${daemon_pid:-}"

if [ -n "$sup_pid" ] && [ -n "$daemon_pid" ]; then
    kill "$sup_pid" 2>/dev/null || true

    gone=0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        sleep 1
        kill -0 "$daemon_pid" 2>/dev/null || { gone=1; break; }
    done

    if [ "$gone" -eq 1 ]; then
        _pass "the daemon dies when the supervisor is killed"
    else
        _fail "the daemon SURVIVED the supervisor — it is now an orphan"
        kill "$daemon_pid" 2>/dev/null || true
    fi

    refute "no orphaned daemon is left behind" find_stub_daemon
else
    _fail "could not establish the supervisor/daemon fixture"
fi

rm -rf "$SUP"

summary
