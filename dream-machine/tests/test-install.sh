#!/bin/bash
#
# test-install.sh — NON-DISRUPTIVE, offline, Tier 1.
#
# Runs the REAL install.sh and uninstall.sh against a fake UDM.
#
# Why this exists. install.sh and uninstall.sh were, until this file, the only
# executables in the tree that no test ever *executed* — they were `bash -n`'d
# and grepped, nothing more. `bash -n` parses; it does not resolve command
# names. That gap shipped a real defect: install.sh called `info`, which is
# defined in tests/lib.sh and not in install.sh, on the branch taken by every
# first-time install. With `set -euo pipefail` that is exit 127. The path that
# had been exercised by hand was the idempotent re-install path, where the
# branch is skipped.
#
# ShellCheck would not have caught it either — it has no undefined-function
# check. Executing the script is the only thing that finds this class.
#
# ==================================================================
# WHAT THIS DOES AND DOES NOT VALIDATE
# ==================================================================
#
# Validates: the installers' own control flow, branch selection, quoting across
# the ssh boundary, helper usage, gate polarity, and the failure branches that
# static analysis cannot reach.
#
# Does NOT validate UDM semantics. The fake answers whatever the scenario tells
# it to. Whether dnsmasq really binds an added alias is Phase 1 Gate 1, is still
# unverified, and still has no fallback. A green run here says the installer is
# correct, not that the design works.
#
# One further divergence, stated plainly: commands executed in sandboxed mode
# are PATH-REWRITTEN (/data, /run, /etc/systemd/system are redirected into a
# temp sandbox). The literal production paths are therefore NOT what executes.
# S2 below exists to make sure a *partial* rewrite can never happen silently,
# which would be worse than no rewrite at all — it would touch real paths and
# still pass.
#
# ==================================================================
# SAFETY — read this before adding a scenario
# ==================================================================
#
# Sandboxed mode executes UDM snippets locally, and those snippets call `kill`.
# /proc is deliberately NOT rewritten, because the whole point of scenarios 4
# and 7 is to exercise the real /proc/<pid>/cmdline identity check. A scenario
# that sets its fixtures up wrongly could therefore aim a signal at an unrelated
# process on this workstation.
#
# Three invariants prevent that. All fail closed. All are enforced by this
# harness rather than by the care of whoever writes the next scenario.
#
#   S1  No signal may reach a PID this harness did not spawn.
#   S2  No unrewritten production path may reach execution.
#   S3  An unrecognised remote invocation is a failure, not a default.
#
# S1 is layered, because the obvious implementation does not work:
#
#   A PATH stub named `kill` is NEVER INVOKED. `kill` is a bash builtin and
#   builtins beat PATH. Measured:
#       $ PATH=stub:$PATH bash -c 'kill -0 1'
#       bash: kill: (1) - Operation not permitted     <- the builtin ran
#
#   Layer 1: a kill() shell function, injected via BASH_ENV. Functions DO beat
#            builtins, and BASH_ENV is read by every non-interactive bash — so
#            the guard is present in nested `bash -c` too, which a plain
#            function definition would not survive. Verified to hold through two
#            levels of nesting, and inside ( ) subshells and $( ) substitution.
#   Layer 2: the PATH stub, retained but demoted, to catch `command kill`,
#            `env kill`, and any nested NON-bash shell that ignores BASH_ENV.
#   Layer 3: a pre-execution text scan rejecting `builtin kill` and absolute
#            /bin/kill — the two forms layers 1 and 2 cannot intercept.
#   Layer 4: a pre-execution text scan rejecting nested shell execution
#            (bash -c, sh -c, dash -c, ash -c) outright. This is the primary
#            defence against nesting, not the inheritance in layer 1, because
#            inheritance is a BASH feature: where /bin/sh is dash, neither
#            BASH_ENV nor `export -f` works at all. /bin/sh is bash on this
#            workstation, so an inheritance-only strategy would pass here and
#            fail elsewhere. Nothing in install.sh or uninstall.sh nests a shell
#            today, so rejecting costs nothing.
#
#   `enable -n kill` is deliberately NOT used, despite working: it disables the
#   builtin that the layer-1 guard needs in order to deliver permitted signals.
#
# The guard is itself tested — see the GUARD scenarios at the end. An
# unexercised safety mechanism is an assumption, and this one was wrong twice
# before it was right.

set -uo pipefail

VERIFY_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_SRC="$(cd "$VERIFY_DIR/.." && pwd)"
# shellcheck source=lib.sh
. "$VERIFY_DIR/lib.sh"

hdr "test-install.sh — installer control flow against a fake UDM"

# ------------------------------------------------------------------
# Sandbox
# ------------------------------------------------------------------

SB="$(mktemp -d)"
export SB

FIXTURE_PIDS=""

cleanup() {
    for p in $FIXTURE_PIDS; do
        [ -n "$p" ] || continue
        kill -KILL "$p" 2>/dev/null || true
    done
    rm -rf "$SB"
}
trap cleanup EXIT INT TERM

fatal() {
    printf '\n\033[1;31mHARNESS ABORTED\033[0m %s\n' "$*" >&2
    [ -s "$SB/fatal" ] && { echo "--- guard diagnostics ---" >&2; cat "$SB/fatal" >&2; }
    exit 1
}

mkdir -p "$SB/bin" "$SB/root" "$SB/log"
: >"$SB/allowlist"

# ------------------------------------------------------------------
# S1 — the kill guard
# ------------------------------------------------------------------
#
# Sourced by every non-interactive bash under BASH_ENV, and re-implemented in
# the PATH stub for the shells that ignore BASH_ENV.

cat >"$SB/guard.sh" <<'GUARD'
# Injected via BASH_ENV into every non-interactive bash in sandboxed mode.
# A function beats the builtin; BASH_ENV means nested bash gets it too.
kill() {
    local _sig="" _p
    for _p in "$@"; do
        case "$_p" in
            -*) _sig="$_p"; continue ;;
        esac
        if ! grep -qx -- "$_p" "$SB/allowlist" 2>/dev/null; then
            {
                echo "S1 VIOLATION: signal ${_sig:-default} aimed at PID $_p"
                echo "  which this harness did not spawn."
                echo "  allowlist: $(tr '\n' ' ' <"$SB/allowlist")"
            } >>"$SB/fatal"
            return 99
        fi
    done
    builtin kill "$@"
}
export -f kill 2>/dev/null || true
GUARD

# Layer 2: the PATH stub. Not the primary mechanism — it is never reached from
# plain `kill` in bash — but it is what catches `command kill`, `env kill`, and
# a nested shell that does not honour BASH_ENV.
cat >"$SB/bin/kill" <<'STUB'
#!/bin/bash
for p in "$@"; do
    case "$p" in -*) continue ;; esac
    if ! grep -qx -- "$p" "$SB/allowlist" 2>/dev/null; then
        echo "S1 VIOLATION (via PATH stub): signal aimed at non-fixture PID $p" >>"$SB/fatal"
        exit 99
    fi
done
exec /bin/kill "$@"
STUB

# ------------------------------------------------------------------
# S1 — structural checks on fixtures
# ------------------------------------------------------------------

# Record a PID as ours. Refuses anything that cannot possibly be a fixture, so
# a mistake in scenario setup is caught at registration rather than at signal
# time.
register_fixture() {
    local pid="$1"
    [ -n "$pid" ] || fatal "register_fixture called with an empty PID"
    [ "$pid" != "1" ] || fatal "refusing to register PID 1 as a fixture"
    [ "$pid" != "$$" ] || fatal "refusing to register the harness itself as a fixture"
    is_descendant "$pid" || fatal "PID $pid is not a descendant of this harness ($$); refusing to register it"
    echo "$pid" >>"$SB/allowlist"
    FIXTURE_PIDS="$FIXTURE_PIDS $pid"
}

# Walk /proc/<pid>/stat's ppid field up to the harness.
is_descendant() {
    local pid="$1" depth=0 ppid
    while [ "$depth" -lt 50 ]; do
        [ "$pid" = "$$" ] && return 0
        [ "$pid" = "1" ] && return 1
        [ -r "/proc/$pid/stat" ] || return 1
        # Field 4 is ppid, but field 2 (comm) may contain spaces or parens, so
        # cut everything up to the final ')' before splitting.
        ppid=$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null | awk '{print $2}')
        [ -n "$ppid" ] || return 1
        pid="$ppid"
        depth=$((depth + 1))
    done
    return 1
}

# ------------------------------------------------------------------
# S2 / S3 / layers 3 and 4 — the pre-execution scan
# ------------------------------------------------------------------
#
# Lives in a file so the ssh stub (a separate process) can source it.

cat >"$SB/scan.sh" <<'SCAN'
# scan_command <rewritten-command>
# Returns 0 if safe to execute. On violation, appends to $SB/fatal and
# returns 1. Never "warns and continues".
scan_command() {
    local cmd="$1"
    # Blank the REWRITTEN prefixes whole — sandbox root *and* the production
    # component. Blanking only "$SB/root" would leave "/data" behind and
    # flag every correctly rewritten command. Longest first.
    local probe="$cmd"
    probe="${probe//$SB\/root\/etc\/systemd\/system/@SB_ETC@}"
    probe="${probe//$SB\/root\/data/@SB_DATA@}"
    probe="${probe//$SB\/root\/run/@SB_RUN@}"
    probe="${probe//$SB\/root/@SB_ROOT@}"
    probe="${probe//$SB/@SB@}"

    local p
    for p in /data /run /etc/systemd/system; do
        case "$probe" in
            *"$p"*)
                echo "S2 VIOLATION: unrewritten production path '$p' would have executed:" >>"$SB/fatal"
                echo "  $cmd" >>"$SB/fatal"
                return 1
                ;;
        esac
    done

    # Layer 3 — forms that bypass both the guard function and the PATH stub.
    case "$cmd" in
        *"builtin kill"*|*/bin/kill*|*/usr/bin/kill*)
            echo "S1 LAYER 3 VIOLATION: unguardable kill invocation:" >>"$SB/fatal"
            echo "  $cmd" >>"$SB/fatal"
            return 1
            ;;
    esac

    # Layer 4 — nested shells get a fresh builtin kill. Reject outright; the
    # BASH_ENV inheritance underneath is belt-and-braces, not the defence,
    # because it does not exist where /bin/sh is dash.
    case "$cmd" in
        *"bash -c"*|*"sh -c"*|*"dash -c"*|*"ash -c"*)
            echo "S1 LAYER 4 VIOLATION: nested shell execution in a sandboxed snippet:" >>"$SB/fatal"
            echo "  $cmd" >>"$SB/fatal"
            return 1
            ;;
    esac
    return 0
}
SCAN

# ------------------------------------------------------------------
# The fake UDM — ssh stub
# ------------------------------------------------------------------
#
# Two modes, and no third:
#   canned    — a scripted answer, for probes the fake cannot meaningfully run.
#   sandboxed — path-rewritten and actually executed, for the branches whose
#               logic is the thing under test.
# Anything matching neither is S3: hard failure, printing the command, so a
# newly added `udm '...'` cannot silently bypass coverage while the suite
# stays green.

cat >"$SB/bin/ssh" <<'SSHSTUB'
#!/bin/bash
# shellcheck disable=SC1090
. "$SB/scan.sh"

# Last argument is the remote command; everything before it is options/target.
cmd="${*: -1}"
printf '%s\n---8<---\n' "$cmd" >>"$SB/log/ssh"

emit_fatal() {
    echo "$*" >>"$SB/fatal"
    exit 99
}

# --- canned -------------------------------------------------------
# Format: MARKER<TAB>EXIT<TAB>STDOUT   (STDOUT may be empty)
if [ -f "$SB/canned" ]; then
    while IFS=$'\t' read -r marker rc out; do
        [ -n "${marker:-}" ] || continue
        case "$cmd" in
            *"$marker"*)
                [ -n "${out:-}" ] && printf '%s\n' "$out"
                exit "$rc"
                ;;
        esac
    done <"$SB/canned"
fi

# --- sandboxed execute --------------------------------------------
while IFS= read -r pat; do
    [ -n "${pat:-}" ] || continue
    case "$cmd" in
        *"$pat"*)
            rewritten="${cmd//\/etc\/systemd\/system/$SB/root/etc/systemd/system}"
            rewritten="${rewritten//\/data/$SB/root/data}"
            rewritten="${rewritten//\/run/$SB/root/run}"
            scan_command "$rewritten" || exit 99
            BASH_ENV="$SB/guard.sh" PATH="$SB/bin:$PATH" bash -c "$rewritten"
            exit $?
            ;;
    esac
done <"$SB/sandboxed"

emit_fatal "S3 VIOLATION: unrecognised remote command, neither canned nor sandbox-allowlisted:
  $cmd"
SSHSTUB

# ------------------------------------------------------------------
# Remaining stubs
# ------------------------------------------------------------------

cat >"$SB/bin/scp" <<'SCPSTUB'
#!/bin/bash
args=()
for a in "$@"; do
    case "$a" in
        -o) continue ;;
        StrictHostKeyChecking=*|ConnectTimeout=*) continue ;;
        *) args+=("$a") ;;
    esac
done
n=${#args[@]}
dest="${args[$((n - 1))]}"
remote="${dest#*:}"
local_dest="$SB/root${remote}"
printf '%s\n' "$remote" >>"$SB/log/scp"
mkdir -p "$(dirname "$local_dest")" 2>/dev/null || true
i=0
while [ "$i" -lt $((n - 1)) ]; do
    src="${args[$i]}"
    printf '  <- %s\n' "$src" >>"$SB/log/scp"
    case "$remote" in
        */) cp "$src" "$local_dest" 2>/dev/null || true ;;
        *)
            if [ $((n - 1)) -gt 1 ]; then
                mkdir -p "$local_dest" 2>/dev/null || true
                cp "$src" "$local_dest/" 2>/dev/null || true
            else
                cp "$src" "$local_dest" 2>/dev/null || true
            fi
            ;;
    esac
    i=$((i + 1))
done
exit 0
SCPSTUB

# `ip` stub, backed by a plain-text address table so scenarios can assert on it
# and so `ip addr del` can be made to no-op for the removal-failure scenario.
cat >"$SB/bin/ip" <<'IPSTUB'
#!/bin/bash
TABLE="$SB/root/addrs"
touch "$TABLE"
args="$*"
case "$args" in
    *"addr add"*)
        for a in "$@"; do case "$a" in */*) cidr="$a" ;; esac; done
        dev=""; prev=""
        for a in "$@"; do [ "$prev" = "dev" ] && dev="$a"; prev="$a"; done
        grep -qx "$dev $cidr" "$TABLE" 2>/dev/null || echo "$dev $cidr" >>"$TABLE"
        exit 0
        ;;
    *"addr del"*)
        [ "${SCN_IP_DEL_NOOP:-0}" = "1" ] && exit 0
        for a in "$@"; do case "$a" in */*) cidr="$a" ;; esac; done
        dev=""; prev=""
        for a in "$@"; do [ "$prev" = "dev" ] && dev="$a"; prev="$a"; done
        grep -vx "$dev $cidr" "$TABLE" >"$TABLE.new" 2>/dev/null || true
        mv "$TABLE.new" "$TABLE"
        exit 0
        ;;
    *"addr show"*)
        n=1
        while read -r dev cidr; do
            [ -n "${dev:-}" ] || continue
            n=$((n + 1))
            printf '%d: %s    inet %s scope global %s\\       valid_lft forever\n' \
                "$n" "$dev" "$cidr" "$dev"
        done <"$TABLE"
        exit 0
        ;;
esac
exit 0
IPSTUB

cat >"$SB/bin/systemctl" <<'SYSCTL'
#!/bin/bash
MARK="$SB/root/etc/systemd/system/.enabled"
case "$1" in
    is-enabled) [ -f "$MARK" ] && exit 0 || exit 1 ;;
    enable)     mkdir -p "$(dirname "$MARK")"; touch "$MARK"; exit 0 ;;
    *)          exit 0 ;;
esac
SYSCTL

# pgrep is structurally incapable of returning a non-fixture PID: it can only
# ever echo entries drawn from the allowlist.
cat >"$SB/bin/pgrep" <<'PGREP'
#!/bin/bash
pat=""
for a in "$@"; do case "$a" in -*) ;; *) pat="$a" ;; esac; done
while read -r p; do
    [ -n "${p:-}" ] || continue
    [ -r "/proc/$p/cmdline" ] || continue
    if tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null | grep -qF -- "$pat"; then
        echo "$p"
    fi
done <"$SB/allowlist"
exit 0
PGREP

cat >"$SB/bin/nohup" <<'NOHUP'
#!/bin/bash
printf '%s\n' "$*" >>"$SB/log/nohup"
exit 0
NOHUP

# sleep is a no-op so the hard gate's own `sleep 2` and the daemon launch's
# `sleep 3` do not make the suite slow. Nothing under test depends on real
# elapsed time; the watchdog is driven explicitly instead (see below).
cat >"$SB/bin/sleep" <<'SLEEP'
#!/bin/bash
exit 0
SLEEP

# Only reached when the hard gate is executed rather than answered from the
# canned table. SCN_DIG_BOUND=0 simulates dnsmasq NOT picking up the alias,
# which is the outcome that voids the design and the one whose cleanup path
# most needs proving.
cat >"$SB/bin/dig" <<'DIG'
#!/bin/bash
if [ "${SCN_DIG_BOUND:-1}" = "1" ]; then
    echo ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1'
fi
exit 0
DIG

chmod +x "$SB/bin/"*

# ------------------------------------------------------------------
# Repo copy + synthetic config
# ------------------------------------------------------------------
#
# Hermetic: never reads the operator's real scripts/config.env, so the suite
# works on a fresh clone and no real hostname ends up in a test.

REPO="$SB/repo"
mkdir -p "$REPO"
cp -r "$REPO_SRC/install" "$REPO_SRC/uninstall" "$REPO_SRC/scripts" "$REPO/"

cat >"$REPO/scripts/config.env" <<'CFG'
UDM_HOST=udm.test.invalid
UDM_SSH_USER=root
ADGUARD_IP=192.168.1.99
FAILOVER_IP=192.168.1.2
LAN_IF=br0
CORROBORATE_SERVER=127.0.0.1
RESOLV_FILE=/run/resolv.conf.d/main
LOG_FILE=/data/adguard-failover/failover.log
CFG

# ------------------------------------------------------------------
# Scenario plumbing
# ------------------------------------------------------------------

# Healthy answers for every canned probe. Polarity matters and is not
# uniform — three of these gates PASS on a non-zero exit.
write_canned_healthy() {
    printf '%s\t%s\t%s\n' \
        'echo ok'                        0 ''   \
        'command -v dig'                 0 ''   \
        'bind-dynamic'                   0 ''   \
        'interface=br0'                  0 ''   \
        'nameserver'                     1 ''   \
        'ping -c 2'                      1 ''   \
        "dig @'127.0.0.1'"               0 ''   \
        'NOT_BOUND'                      0 'BOUND' \
        'dhcp-option=option6'            1 ''   \
        >"$SB/canned"
}

# Commands that are executed rather than answered. Order-independent; first
# substring match wins.
#
# The DHCP-claim entry is keyed on the PATH, not on the match expression. S3's
# job is to answer "is this command classified?", not "is its regex correct?".
# Keying it on the regex conflated the two: changing the expression tripped a
# safety invariant and aborted the run at scenario 1, so the semantic assertion
# in scenario 15 never got the chance to fail. A safety guard that pre-empts the
# test it is meant to protect hides the defect instead of surfacing it.
write_sandboxed_default() {
    cat >"$SB/sandboxed" <<'PATS'
/run/dnsmasq.dhcp.conf.d/
cat > '/data/.adguard-failover-provenance'
[ -f '/data/.adguard-failover-provenance' ]
sed -n 's/^udm_boot_service_before_install=
sed -n 's/^on_boot_d_before_install=
[ -d /data/on_boot.d ]
ls -A /data/on_boot.d
systemctl is-enabled udm-boot.service
chmod 0644
mkdir -p /data/adguard-failover /data/on_boot.d
chmod +x /data/adguard-failover
HOOK_PATH=/data/on_boot.d
tail -n 25
DAEMON_PATH=/data/adguard-failover
for _path in /data/on_boot.d
ip -4 -o addr show
ip addr del
rm -f /data/on_boot.d/15-adguard-failover.sh
for f in /data/adguard-failover
PATS
}

reset_sandbox_state() {
    rm -rf "$SB/root" "$SB/log" "$SB/fatal"
    mkdir -p "$SB/root/etc/systemd/system" "$SB/root/data/on_boot.d" \
             "$SB/root/data/adguard-failover" "$SB/root/run" "$SB/log"
    : >"$SB/root/addrs"
    write_dhcp_conf_clean
    write_canned_healthy
    write_sandboxed_default
    unset SCN_IP_DEL_NOOP
}

# The DHCP-reservation gate is executed for real, not canned, because the thing
# under test IS the match expression. A canned "exit 1 = not found" row asserts
# nothing about anchoring, and that is exactly how the unanchored-substring bug
# reached a live UDM with 290 green assertions behind it.
#
# Content below is copied from the real UDM's
# /run/dnsmasq.dhcp.conf.d/dhcp.dhcpServers-net_Default_br0_192-168-1-0-24.conf.
# It deliberately contains .20, .254 and .255 — the three addresses that all
# contain "192.168.1.2" as a substring — and NOT .2 itself.
write_dhcp_conf_clean() {
    mkdir -p "$SB/root/run/dnsmasq.dhcp.conf.d"
    cat >"$SB/root/run/dnsmasq.dhcp.conf.d/default.conf" <<'DHCPCONF'
dhcp-host=set:net_Default_br0_192-168-1-0-24,id:*,00:00:00:00:00:00,192.168.1.20
dhcp-range=set:net_Default_br0_192-168-1-0-24,192.168.1.6,192.168.1.254,255.255.255.0,86400
dhcp-option=tag:net_Default_br0_192-168-1-0-24,28,192.168.1.255
dhcp-option=tag:net_Default_br0_192-168-1-0-24,6,192.168.1.99
DHCPCONF
}

# A genuine static reservation for the failover address — the condition the
# gate actually exists to catch.
write_dhcp_conf_claimed() {
    write_dhcp_conf_clean
    echo 'dhcp-host=set:net_Default_br0_192-168-1-0-24,aa:bb:cc:dd:ee:ff,192.168.1.2' \
        >>"$SB/root/run/dnsmasq.dhcp.conf.d/default.conf"
}

# The INTENDED deployed state: the failover address handed to clients as the
# second DNS server. Copied verbatim from the live UDM after the DHCP change.
# This must PASS the claim gate — being named as a resolver is not a claim.
write_dhcp_conf_advertised() {
    write_dhcp_conf_clean
    echo 'dhcp-option=tag:net_Default_br0_192-168-1-0-24,option:dns-server,192.168.1.99,192.168.1.2' \
        >>"$SB/root/run/dnsmasq.dhcp.conf.d/default.conf"
}

# Run a script under the fake UDM. Never inherits the real PATH's ssh/scp.
run_installer() {
    local script="$1"; shift
    ( PATH="$SB/bin:$PATH" SB="$SB" "$script" "$@" ) >"$SB/log/out" 2>&1
    echo $? >"$SB/log/rc"
}

rc_of()  { cat "$SB/log/rc"; }
out_of() { cat "$SB/log/out"; }

check_no_fatal() {
    [ -f "$SB/fatal" ] && fatal "a safety invariant fired during '$1'"
    return 0
}

out_has()  { grep -qF -- "$1" "$SB/log/out"; }
sent_has() { grep -qF -- "$1" "$SB/log/ssh" 2>/dev/null; }
scp_has()  { grep -qF -- "$1" "$SB/log/scp" 2>/dev/null; }

# ------------------------------------------------------------------
# Scenario 1 — fresh install
# ------------------------------------------------------------------
#
# udm-boot.service absent, so the vendored-unit branch is taken. This is the
# regression test for the `info` defect: before the fix this scenario exits 127
# and deploys nothing.

hdr "Scenario 1 — fresh install (udm-boot.service absent)"

reset_sandbox_state
run_installer "$REPO/install/install.sh"
check_no_fatal "scenario 1"

assert_eq "install.sh exits 0 on a fresh install" 0 "$(rc_of)"
[ "$(rc_of)" = "0" ] || { note "--- installer output ---"; sed 's/^/      /' "$SB/log/out"; }

# Verified red: with `info()` removed from install.sh, this scenario fails six
# assertions and deploys nothing.
#
# It does NOT fail on a "command not found" match, and that is a finding rather
# than a gap. `info` is GNU texinfo's binary and exists at /usr/bin/info on this
# workstation, so the undefined helper silently resolves to an unrelated program
# which exits 1 and trips `set -e`. On the UDM, where texinfo is absent, the same
# defect is a 127. The symptom is environment-dependent; the abort is not. That
# is precisely why the static helper-vocabulary check in test-hardening.sh is the
# primary defence for this class, and this harness is corroboration.

assert "no helper it calls is missing or shadowed" \
    bash -c '! grep -qiE "command not found|No menu item" "$SB/log/out"'

assert "it takes the install-the-unit branch" \
    out_has "installing the vendored unit"

assert "the vendored unit is copied" \
    scp_has "/etc/systemd/system/udm-boot.service"

assert "udm-boot.service ends up enabled" \
    test -f "$SB/root/etc/systemd/system/.enabled"

assert "the daemon is deployed" scp_has "/data/adguard-failover/"
assert "the boot hook is deployed" scp_has "/data/on_boot.d/15-adguard-failover.sh"
assert "it reports the unit as installed" out_has "udm-boot.service installed and enabled"

# ------------------------------------------------------------------
# Scenario 2 — re-install, unit already enabled
# ------------------------------------------------------------------

hdr "Scenario 2 — re-install (udm-boot.service already enabled)"

reset_sandbox_state
touch "$SB/root/etc/systemd/system/.enabled"
printf 'PRE-EXISTING\n' >"$SB/root/etc/systemd/system/udm-boot.service"
run_installer "$REPO/install/install.sh"
check_no_fatal "scenario 2"

assert_eq "install.sh exits 0 on re-install" 0 "$(rc_of)"
assert "it reports the unit as already enabled" out_has "already enabled"
refute "it does NOT take the install-the-unit branch" out_has "installing the vendored unit"
assert_eq "an already-present unit file is left untouched" \
    "PRE-EXISTING" "$(cat "$SB/root/etc/systemd/system/udm-boot.service")"
refute "the unit is not re-copied" scp_has "/etc/systemd/system/udm-boot.service"

# ------------------------------------------------------------------
# Scenario 3 — each preflight gate fails in turn
# ------------------------------------------------------------------
#
# Polarity is not uniform: three of these gates pass on a NON-ZERO exit, so a
# table that flipped every probe to "1" would test nothing. Each row therefore
# names the failing value explicitly.

hdr "Scenario 3 — preflight gates refuse and deploy nothing"

# marker | failing-rc | failing-stdout | expected substring in the refusal
gate_case() {
    local marker="$1" rc="$2" out="$3" expect="$4" desc="$5"
    reset_sandbox_state
    # Replace that marker's canned row.
    grep -vF "$marker" "$SB/canned" >"$SB/canned.new"
    printf '%s\t%s\t%s\n' "$marker" "$rc" "$out" >>"$SB/canned.new"
    mv "$SB/canned.new" "$SB/canned"

    run_installer "$REPO/install/install.sh"
    check_no_fatal "gate: $desc"

    if [ "$(rc_of)" = "0" ]; then
        _fail "$desc — installer exited 0 instead of refusing"
    else
        _pass "$desc — installer refused"
    fi

    if out_has "$expect"; then
        _pass "$desc — refusal names the cause"
    else
        _fail "$desc — refusal did not mention '$expect'"
        note "output: $(tail -2 "$SB/log/out" | tr '\n' ' ')"
    fi

    if scp_has "/data/adguard-failover/"; then
        _fail "$desc — DEPLOYED ANYWAY after a failed gate"
    else
        _pass "$desc — nothing was deployed"
    fi
}

gate_case 'command -v dig'            1 ''  'dig is not installed'        'gate: dig missing'
gate_case 'bind-dynamic'              1 ''  "does not contain 'bind-dynamic'" 'gate: no bind-dynamic'
gate_case 'interface=br0'             1 ''  "does not list 'interface=br0'"   'gate: dnsmasq not on br0'
gate_case 'nameserver'                0 ''  'as one of'                   'gate: UDM upstream is AdGuard'
# NOTE: the DHCP-claim gate is deliberately absent from this list. It is no
# longer answered by a canned row — it executes the real grep against real
# dnsmasq config — so its failure cannot be injected by rewriting the canned
# table. Scenario 15b covers the identical three properties (refuses, names the
# cause, deploys nothing) by planting an actual reservation.
gate_case 'ping -c 2'                 0 ''  'answers ICMP'                'gate: failover IP already answers'
gate_case "dig @'127.0.0.1'"          1 ''  'no DNS response'             'gate: no corroboration path'
gate_case 'NOT_BOUND'                 0 'NOT_BOUND' 'did not answer on it' 'HARD GATE: dnsmasq did not bind'
gate_case 'NOT_BOUND'                 0 'ADD_FAILED' 'could not add'       'HARD GATE: address add failed'

# ------------------------------------------------------------------
# Fixtures for the process-identity scenarios
# ------------------------------------------------------------------
#
# These are real processes. Their argv must match the SANDBOX paths, because
# that is what the rewritten snippet checks against.

HOOK_SB="$SB/root/data/on_boot.d/15-adguard-failover.sh"
DAEMON_SB="$SB/root/data/adguard-failover/dns-failover.sh"

spawn_fixtures() {
    mkdir -p "$(dirname "$HOOK_SB")" "$(dirname "$DAEMON_SB")"
    printf '#!/bin/bash\nwhile true; do sleep 0.2; done\n' >"$HOOK_SB"
    printf '#!/bin/bash\ntrap "exit 0" TERM\nwhile true; do sleep 0.2; done\n' >"$DAEMON_SB"
    chmod +x "$HOOK_SB" "$DAEMON_SB"

    "$HOOK_SB" & SUP_PID=$!
    "$DAEMON_SB" & DAE_PID=$!
    sleep 300 & DECOY_PID=$!

    register_fixture "$SUP_PID"
    register_fixture "$DAE_PID"
    register_fixture "$DECOY_PID"
    sleep 1
}

# ------------------------------------------------------------------
# Scenario 4 — install path, stale / non-owned PID file
# ------------------------------------------------------------------
#
# Reachable in production every time a PID is recycled across a reboot: the
# file survives on tmpfs, the process it named does not. Getting this wrong
# sends SIGTERM to an unrelated process as root.

hdr "Scenario 4 — install path, PID file names a non-owned process"

reset_sandbox_state
touch "$SB/root/etc/systemd/system/.enabled"
spawn_fixtures
echo "$DECOY_PID" >"$SB/root/run/adguard-failover.pid"

run_installer "$REPO/install/install.sh"
check_no_fatal "scenario 4"

assert_eq "install.sh still exits 0" 0 "$(rc_of)"
assert "it warns that the PID is not ours" out_has "does not look like ours"
assert "the non-owned process is left ALIVE" kill -0 "$DECOY_PID"
refute "the stale PID file is cleared" test -f "$SB/root/run/adguard-failover.pid"

# ------------------------------------------------------------------
# Scenario 5 — uninstall, standby removal verification fails
# ------------------------------------------------------------------
#
# `ip addr del` is made a no-op so the address survives. uninstall.sh must hard
# fail rather than report success and go on to delete the daemon that would
# otherwise have cleaned it up. This branch has never executed anywhere.

hdr "Scenario 5 — uninstall, standby removal fails verification"

reset_sandbox_state
echo "br0 192.168.1.2/32" >"$SB/root/addrs"
export SCN_IP_DEL_NOOP=1
run_installer "$REPO/uninstall/uninstall.sh"
unset SCN_IP_DEL_NOOP
check_no_fatal "scenario 5"

if [ "$(rc_of)" = "0" ]; then
    _fail "uninstall.sh must NOT exit 0 when the standby address survives"
else
    _pass "uninstall.sh hard-fails when the standby address survives"
fi
assert "it says the address is still bound" out_has "STILL bound"
assert "it prints the manual remediation command" out_has "ip addr del 192.168.1.2/32 dev br0"
refute "it does NOT go on to delete the daemon files" \
    test ! -d "$SB/root/data/adguard-failover"

# ------------------------------------------------------------------
# Scenario 6 — uninstall, clean, with and without a bound standby
# ------------------------------------------------------------------

hdr "Scenario 6 — uninstall (clean)"

reset_sandbox_state
echo "br0 192.168.1.2/32" >"$SB/root/addrs"
printf 'x\n' >"$SB/root/data/on_boot.d/15-adguard-failover.sh"
run_installer "$REPO/uninstall/uninstall.sh"
check_no_fatal "scenario 6a"

assert_eq "uninstall.sh exits 0 with a bound standby" 0 "$(rc_of)"
[ "$(rc_of)" = "0" ] || { note "--- uninstall output ---"; sed 's/^/      /' "$SB/log/out"; }
refute "the standby address is gone" grep -q '192.168.1.2' "$SB/root/addrs"
assert "it reports the address unbound" out_has "is not bound"
refute "the boot hook is removed" test -f "$SB/root/data/on_boot.d/15-adguard-failover.sh"
refute "the install directory is removed" test -d "$SB/root/data/adguard-failover"
assert "it reports nothing left behind" out_has "Nothing left behind"

reset_sandbox_state
run_installer "$REPO/uninstall/uninstall.sh"
check_no_fatal "scenario 6b"
assert_eq "uninstall.sh exits 0 with no standby bound" 0 "$(rc_of)"

# ------------------------------------------------------------------
# Scenario 7 — uninstall, PID file names a non-owned process
# ------------------------------------------------------------------

hdr "Scenario 7 — uninstall, PID file names a non-owned process"

reset_sandbox_state
spawn_fixtures
echo "$DECOY_PID" >"$SB/root/run/adguard-failover.pid"

run_installer "$REPO/uninstall/uninstall.sh"
check_no_fatal "scenario 7"

assert "the non-owned process survives uninstall" kill -0 "$DECOY_PID"
assert "it warns rather than signalling" out_has "does not look like ours"
assert "the owned daemon fixture is stopped" bash -c '! kill -0 '"$DAE_PID"' 2>/dev/null'
assert "the owned supervisor fixture is stopped" bash -c '! kill -0 '"$SUP_PID"' 2>/dev/null'

# ------------------------------------------------------------------
# GUARD scenarios — the safety net is itself tested
# ------------------------------------------------------------------
#
# A safety mechanism that has never been observed firing is an assumption.
# These drive violations deliberately and assert the harness refuses.

# ------------------------------------------------------------------
# Scenario 8 — --preflight-only writes nothing
# ------------------------------------------------------------------
#
# The whole point of the flag. A preflight mode that quietly deploys is worse
# than having no preflight mode at all, because it would be run precisely by
# someone trying to avoid deploying.
#
# "Deployed nothing" is asserted against the filesystem and the scp log, not
# against the installer's own claim about itself.

hdr "Scenario 8 — --preflight-only deploys nothing"

reset_sandbox_state
run_installer "$REPO/install/install.sh" --preflight-only
check_no_fatal "scenario 8"

assert_eq "--preflight-only exits 0 when every gate passes" 0 "$(rc_of)"
[ "$(rc_of)" = "0" ] || { note "--- output ---"; sed 's/^/      /' "$SB/log/out"; }

assert "it says nothing was installed" out_has "Nothing was installed"
assert "it reaches the gates" out_has "All preflight gates passed"

refute "NOTHING was copied to the UDM" test -s "$SB/log/scp"
refute "the daemon was not deployed" test -f "$SB/root/data/adguard-failover/dns-failover.sh"
refute "the config was not deployed" test -f "$SB/root/data/adguard-failover/config.env"
refute "the boot hook was not deployed" test -f "$SB/root/data/on_boot.d/15-adguard-failover.sh"
refute "the unit was not installed" test -f "$SB/root/etc/systemd/system/udm-boot.service"
refute "udm-boot.service was not enabled" test -f "$SB/root/etc/systemd/system/.enabled"
refute "no provenance record was written" test -f "$SB/root/data/.adguard-failover-provenance"
refute "the daemon was not launched" test -s "$SB/log/nohup"
refute "no standby address was left bound" test -s "$SB/root/addrs"

# ------------------------------------------------------------------
# Scenario 9 — --preflight-only with a failing gate
# ------------------------------------------------------------------

hdr "Scenario 9 — --preflight-only refuses on a failed gate"

reset_sandbox_state
grep -vF 'command -v dig' "$SB/canned" >"$SB/canned.new"
printf '%s\t%s\t%s\n' 'command -v dig' 1 '' >>"$SB/canned.new"
mv "$SB/canned.new" "$SB/canned"

run_installer "$REPO/install/install.sh" --preflight-only
check_no_fatal "scenario 9"

if [ "$(rc_of)" = "0" ]; then
    _fail "--preflight-only must not exit 0 when a gate fails"
else
    _pass "--preflight-only exits non-zero on a failed gate"
fi
assert "it names the failing gate" out_has "dig is not installed"
refute "it still deployed nothing" test -s "$SB/log/scp"

# ------------------------------------------------------------------
# Scenario 10 — unrecognised arguments are refused, not ignored
# ------------------------------------------------------------------
#
# A typo'd flag that is silently dropped runs a full install when the operator
# asked for a dry run. That is the single worst outcome the flag exists to
# prevent, so it must fail before SSH is even attempted.

hdr "Scenario 10 — argument handling"

reset_sandbox_state
run_installer "$REPO/install/install.sh" --preflight
check_no_fatal "scenario 10"
if [ "$(rc_of)" = "0" ]; then
    _fail "a misspelled --preflight must not be ignored"
else
    _pass "a misspelled flag is refused"
fi
assert "the refusal names the offending argument" out_has "Unrecognised argument: --preflight"
refute "nothing was deployed after a bad argument" test -s "$SB/log/scp"

reset_sandbox_state
run_installer "$REPO/install/install.sh" --help
check_no_fatal "scenario 10 help"
assert_eq "--help exits 0" 0 "$(rc_of)"
assert "--help documents the flag" out_has "--preflight-only"
refute "--help never contacts the UDM" test -s "$SB/log/ssh"

# ------------------------------------------------------------------
# Scenario 11 — the hard gate cleans up after itself
# ------------------------------------------------------------------
#
# Every other scenario answers the hard gate from the canned table, which is
# fast but proves nothing about its cleanup. Here it is actually executed, so
# the trap runs against the ip stub's real address table.
#
# The NOT_BOUND path matters most: it is the outcome that voids the design, and
# it is exactly when an operator is least likely to notice a stranded address
# because they are busy reading a failure message.

hdr "Scenario 11 — hard gate removes its address on both paths"

run_hard_gate() {
    # Drop the canned hard-gate row so the sandboxed pattern takes it instead.
    grep -vF 'NOT_BOUND' "$SB/canned" >"$SB/canned.new"
    mv "$SB/canned.new" "$SB/canned"
    printf 'TOKEN=/run/adguard-failover.hardgate\n' >>"$SB/sandboxed"
    run_installer "$REPO/install/install.sh" --preflight-only
}

reset_sandbox_state
export SCN_DIG_BOUND=1
run_hard_gate
unset SCN_DIG_BOUND
check_no_fatal "scenario 11 bound"

assert_eq "hard gate passes when dnsmasq answers" 0 "$(rc_of)"
assert "it reports the gate passed" out_has "HARD GATE PASSED"
refute "the address is removed after a PASS" test -s "$SB/root/addrs"

reset_sandbox_state
export SCN_DIG_BOUND=0
run_hard_gate
unset SCN_DIG_BOUND
check_no_fatal "scenario 11 not bound"

if [ "$(rc_of)" = "0" ]; then
    _fail "hard gate must fail when dnsmasq does not answer"
else
    _pass "hard gate fails when dnsmasq does not answer"
fi
assert "it says the design must be reworked" out_has "did not answer on it"
refute "the address is removed after a FAILURE too" test -s "$SB/root/addrs"

# The remediation must be on screen BEFORE the bind, so it is already visible
# if the session dies mid-gate rather than being printed by a handler that a
# dropped connection would never reach.
assert "the manual remediation is printed up front" \
    out_has "ssh root@udm.test.invalid \"ip addr del 192.168.1.2/32 dev br0\""

# ------------------------------------------------------------------
# Scenario 12 — provenance: the unit did NOT predate us
# ------------------------------------------------------------------
#
# Install on a UDM with no udm-boot.service, then uninstall, and check the
# operator is told the unit is ours and safe to remove. Before the provenance
# record existed this question was unanswerable at uninstall time.

hdr "Scenario 12 — provenance, unit created by us"

reset_sandbox_state
run_installer "$REPO/install/install.sh"
check_no_fatal "scenario 12 install"

assert_eq "install exits 0" 0 "$(rc_of)"
assert "a provenance record is written" \
    test -f "$SB/root/data/.adguard-failover-provenance"
assert "it records that the unit was absent" \
    grep -q 'udm_boot_service_before_install=absent' \
        "$SB/root/data/.adguard-failover-provenance"

# Re-install must NOT downgrade the record: the unit is now enabled by our own
# first run, and re-recording would strand it forever.
run_installer "$REPO/install/install.sh"
check_no_fatal "scenario 12 reinstall"
assert "re-install preserves the original record" \
    grep -q 'udm_boot_service_before_install=absent' \
        "$SB/root/data/.adguard-failover-provenance"
assert "re-install says it is preserving it" out_has "preserving the original"

run_installer "$REPO/uninstall/uninstall.sh"
check_no_fatal "scenario 12 uninstall"

assert_eq "uninstall exits 0" 0 "$(rc_of)"
assert "uninstall reads the record" out_has "before install: absent"
assert "it says the unit did not exist beforehand" out_has "did NOT exist before"
assert "it offers the removal command" out_has "systemctl disable --now udm-boot.service"
refute "the provenance record is removed too" \
    test -f "$SB/root/data/.adguard-failover-provenance"

# ------------------------------------------------------------------
# Scenario 13 — provenance: the unit DID predate us
# ------------------------------------------------------------------

hdr "Scenario 13 — provenance, unit pre-existing"

reset_sandbox_state
touch "$SB/root/etc/systemd/system/.enabled"
run_installer "$REPO/install/install.sh"
check_no_fatal "scenario 13 install"

assert "it records that the unit was present" \
    grep -q 'udm_boot_service_before_install=present' \
        "$SB/root/data/.adguard-failover-provenance"

run_installer "$REPO/uninstall/uninstall.sh"
check_no_fatal "scenario 13 uninstall"

assert "uninstall says the unit predates the project" out_has "predates this project"
refute "it does NOT offer to disable a pre-existing unit" \
    out_has "did NOT exist before"

# ------------------------------------------------------------------
# Scenario 14 — uninstall with no provenance record
# ------------------------------------------------------------------
#
# An install that predates provenance recording. The honest answer is "unknown",
# and it must not be silently reported as either "ours" or "yours".

hdr "Scenario 14 — uninstall without a provenance record"

reset_sandbox_state
touch "$SB/root/etc/systemd/system/.enabled"
mkdir -p "$SB/root/data/adguard-failover"
: >"$SB/root/data/adguard-failover/dns-failover.sh"
run_installer "$REPO/uninstall/uninstall.sh"
check_no_fatal "scenario 14"

assert_eq "uninstall still exits 0" 0 "$(rc_of)"
assert "it warns the record is missing" out_has "No provenance record"
assert "it refuses to guess" out_has "Cannot tell whether"
refute "it does not claim the unit is ours" out_has "did NOT exist before"
# NOTE: the "unknown" diagnostic itself contains the words "predates this
# project", so this must target the pre-existing branch's distinctive wording
# rather than that phrase, or it matches the very message it is checking for.
refute "it does not claim the unit predates us" out_has "leaving it alone is correct"

# ------------------------------------------------------------------
# Scenario 15 — the DHCP-reservation gate matches whole addresses
# ------------------------------------------------------------------
#
# REGRESSION. The gate shipped as `grep -rqs -- '192.168.1.2'`, an unanchored
# substring match. On a /24 whose dhcp-range ceiling is 192.168.1.254 — which
# is to say very nearly every /24 — that string is present in the config
# unconditionally, so the gate failed on a network with no reservation for the
# address at all. Measured against the real UDM: three matches, .20, .254 and
# .255, none of them .2.
#
# The old harness could not have caught this, because the gate was answered by
# a canned "exit 1" row that asserted nothing about the expression. It is now
# executed for real against config copied from the live device.

hdr "Scenario 15 — DHCP claim gate is address-anchored"

# 15a — realistic config containing .20, .254 and .255 but not .2. The gate
# must pass, and the run must reach the gates that follow it.
reset_sandbox_state
run_installer "$REPO/install/install.sh" --preflight-only
check_no_fatal "scenario 15a"

assert_eq "preflight exits 0 despite .20/.254/.255 in the DHCP config" 0 "$(rc_of)"
assert "the claim gate passes" out_has "no host claims"
refute "it does not report a phantom reservation" out_has "is assigned to a host"

# Prove the fixture really does contain the substrings that broke the old form,
# so this scenario cannot quietly become vacuous if the fixture is edited.
assert "fixture contains 192.168.1.254"     grep -q '192\.168\.1\.254' "$SB/root/run/dnsmasq.dhcp.conf.d/default.conf"
assert "fixture contains 192.168.1.20"     grep -q '192\.168\.1\.20,\|192\.168\.1\.20$' "$SB/root/run/dnsmasq.dhcp.conf.d/default.conf"
refute "fixture does NOT contain a real .2 reservation"     grep -qE '(^|[^0-9.])192\.168\.1\.2([^0-9.]|$)' "$SB/root/run/dnsmasq.dhcp.conf.d/default.conf"

# 15b — a genuine static reservation for .2. The gate must fail, non-zero, and
# nothing may be deployed.
# Full install, NOT --preflight-only: a preflight run deploys nothing whatever
# the gates say, so asserting "nothing deployed" against it would be vacuous.
reset_sandbox_state
write_dhcp_conf_claimed
run_installer "$REPO/install/install.sh"
check_no_fatal "scenario 15b"

refute "a real .2 reservation fails the gate" test "$(rc_of)" = 0
assert "it names the reservation" out_has "is assigned to a host"
assert "it shows the matching line" out_has "aa:bb:cc:dd:ee:ff"
refute "nothing is deployed" test -s "$SB/log/scp"

# 15c — the INTENDED deployed state: .2 advertised to clients as DNS 2.
#
# The gate must pass. Treating the advertisement as a claim made the installer
# work only until the design was finished and then refuse to reinstall forever
# after — a gate that fails closed on its own success. Caught on the live UDM
# the first time a reinstall was attempted after the DHCP change.
reset_sandbox_state
write_dhcp_conf_advertised
run_installer "$REPO/install/install.sh" --preflight-only
check_no_fatal "scenario 15c"

assert_eq "preflight exits 0 when .2 is advertised as DNS 2" 0 "$(rc_of)"
assert "the gate recognises the advertised state" out_has "advertised to clients as a DNS server"
refute "it does not call the advertisement a claim" out_has "is assigned to a host"
# Guard against the fixture drifting into vacuity: it must really contain .2.
assert "fixture really advertises .2" \
    grep -qE 'option:dns-server,192\.168\.1\.99,192\.168\.1\.2$' \
    "$SB/root/run/dnsmasq.dhcp.conf.d/default.conf"

# 15d — advertised AND reserved at the same time.
#
# The exclusion in 15c must not become a blind spot. A reservation on a network
# that also advertises the standby is still a hard conflict, and skipping whole
# files (rather than just the dns-server lines) would hide it.
reset_sandbox_state
write_dhcp_conf_advertised
echo 'dhcp-host=set:net_Default_br0_192-168-1-0-24,aa:bb:cc:dd:ee:ff,192.168.1.2' \
    >>"$SB/root/run/dnsmasq.dhcp.conf.d/default.conf"
run_installer "$REPO/install/install.sh"
check_no_fatal "scenario 15d"

refute "a reservation still fails even when .2 is advertised" test "$(rc_of)" = 0
assert "it names the reservation, not the advertisement" out_has "aa:bb:cc:dd:ee:ff"
refute "nothing is deployed" test -s "$SB/log/scp"

hdr "Guard — S1/S2/S3 fire when they should"

# Run one crafted remote command through the ssh stub directly.
probe_stub() {
    rm -f "$SB/fatal"
    ( PATH="$SB/bin:$PATH" SB="$SB" "$SB/bin/ssh" -o X=1 root@udm "$1" ) \
        >"$SB/log/probe" 2>&1
    echo $?
}

# S1 — a signal at a PID the harness never spawned. 
# Sourcing the guard directly is the honest test of layer 1.
reset_sandbox_state
spawn_fixtures
printf '%s\n' 'HOOK_PATH=/data/on_boot.d/x' >"$SB/sandboxed"
rc=$(probe_stub 'HOOK_PATH=/data/on_boot.d/x; kill -TERM 999999')
assert_eq "S1 aborts on a signal to a non-fixture PID" 99 "$rc"
assert "S1 records a diagnostic" grep -q 'S1 VIOLATION' "$SB/fatal"
assert "the decoy fixture is untouched by the probe" kill -0 "$DECOY_PID"

# S1 layer 1 must beat the builtin, which a PATH stub alone does not.
rm -f "$SB/fatal"
guarded_rc=$( BASH_ENV="$SB/guard.sh" PATH="$SB/bin:$PATH" SB="$SB" \
    bash -c 'kill -TERM 999999' >/dev/null 2>&1; echo $? )
assert_eq "the BASH_ENV guard intercepts plain kill (builtin would not)" 99 "$guarded_rc"

# ...and must survive a nested bash -c, which a plain function definition
# would not. This is layer 4's inheritance backstop, tested with the
# rejection rule bypassed.
rm -f "$SB/fatal"
nested_rc=$( BASH_ENV="$SB/guard.sh" PATH="$SB/bin:$PATH" SB="$SB" \
    bash -c 'bash -c "kill -TERM 999999"' >/dev/null 2>&1; echo $? )
assert_eq "the guard survives a nested bash -c" 99 "$nested_rc"

# Layer 4's primary defence: reject nested shells before they run at all.
reset_sandbox_state
printf '%s\n' 'HOOK_PATH=/data/on_boot.d/x' >"$SB/sandboxed"
rc=$(probe_stub 'HOOK_PATH=/data/on_boot.d/x; bash -c "true"')
assert_eq "layer 4 rejects nested shell execution" 99 "$rc"
assert "layer 4 records a diagnostic" grep -q 'LAYER 4 VIOLATION' "$SB/fatal"

# Layer 3 — unguardable kill forms.
reset_sandbox_state
printf '%s\n' 'HOOK_PATH=/data/on_boot.d/x' >"$SB/sandboxed"
rc=$(probe_stub 'HOOK_PATH=/data/on_boot.d/x; /bin/kill -TERM 1')
assert_eq "layer 3 rejects absolute-path kill" 99 "$rc"
assert "layer 3 records a diagnostic" grep -q 'LAYER 3 VIOLATION' "$SB/fatal"

# S2 — the invariant is tested directly, not through the stub.
#
# Smuggling an unrewritten path through probe_stub is impossible by
# construction: the rewriter runs first and is global, so it would rewrite the
# very path the test is trying to sneak past. What S2 actually defends against
# is a future edit that DROPS one of the three rewrite rules, leaving a partial
# rewrite that touches real paths and still passes. So the test calls the
# invariant with what a broken rewriter would produce.
# shellcheck source=/dev/null
. "$SB/scan.sh"

reset_sandbox_state
rm -f "$SB/fatal"
refute "S2 rejects a command with an unrewritten /data" \
    scan_command "mkdir -p /data/adguard-failover"
assert "S2 records a diagnostic for /data" grep -q 'S2 VIOLATION' "$SB/fatal"

rm -f "$SB/fatal"
refute "S2 rejects a command with an unrewritten /run" \
    scan_command "cat $SB/root/data/x /run/adguard-failover.pid"
assert "S2 records a diagnostic for /run" grep -q 'S2 VIOLATION' "$SB/fatal"

rm -f "$SB/fatal"
refute "S2 rejects a command with an unrewritten /etc/systemd/system" \
    scan_command "chmod 0644 /etc/systemd/system/udm-boot.service"
assert "S2 records a diagnostic for /etc/systemd/system" grep -q 'S2 VIOLATION' "$SB/fatal"

rm -f "$SB/fatal"
assert "S2 passes a fully rewritten command" \
    scan_command "mkdir -p $SB/root/data/on_boot.d && chmod 0644 $SB/root/etc/systemd/system/udm-boot.service && rm -f $SB/root/run/adguard-failover.pid"

rm -f "$SB/fatal"
assert "S2 leaves /proc alone — the one documented exception" \
    scan_command "tr '\\0' '\\n' < /proc/123/cmdline"

# And the rewriter must actually cover all three, or S2 would be firing
# constantly in normal operation instead of never. The rewrite is written as a
# bash pattern substitution with backslash-escaped slashes, so match that form.
for p in '/etc/systemd/system' '/data' '/run'; do
    assert "the ssh stub rewrites $p" \
        grep -qF -- "//${p//\//\\/}/" "$SB/bin/ssh"
done

# S3 — an unrecognised command shape.
reset_sandbox_state
rc=$(probe_stub 'some-brand-new-command --that-nobody-classified')
assert_eq "S3 aborts on an unrecognised remote command" 99 "$rc"
assert "S3 records a diagnostic" grep -q 'S3 VIOLATION' "$SB/fatal"
assert "S3 prints the offending command" grep -q 'brand-new-command' "$SB/fatal"

rm -f "$SB/fatal"

summary
