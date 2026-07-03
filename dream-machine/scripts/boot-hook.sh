#!/bin/bash
#
# boot-hook.sh — supervisor that keeps health-check.sh alive.
#
# Deployed to /data/on_boot.d/15-adguard-failover.sh on the UDM SE.
# The unifi-common package's udm-boot.service executes every executable in
# /data/on_boot.d/ on boot; the leading "15-" simply orders it relative to
# any other hooks.
#
# We launch health-check.sh in the background under a supervisor loop so a
# crash or unexpected exit auto-restarts within a few seconds. The PID of
# the supervisor is written for observability and uninstall.

set -u

DAEMON="/data/adguard-failover/health-check.sh"
PIDFILE="/run/adguard-failover.pid"
LOG_FILE="/data/adguard-failover.log"
RESTART_DELAY=5

# If a previous supervisor is still running, don't start another.
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
    printf '%s  boot-hook: supervisor already running (pid %s), skipping\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$(cat "$PIDFILE")" >>"$LOG_FILE"
    exit 0
fi

# Supervisor: relaunch the daemon whenever it exits.
# stdin/stdout/stderr are explicitly detached from any inherited fds
# (particularly important when boot-hook.sh is invoked over SSH, so the
# SSH session can close promptly instead of hanging on the backgrounded
# subshell's dangling stdio).
(
    while true; do
        printf '%s  boot-hook: launching health-check.sh\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" >>"$LOG_FILE"
        "$DAEMON" >>"$LOG_FILE" 2>&1
        printf '%s  boot-hook: health-check.sh exited; restarting in %ss\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$RESTART_DELAY" >>"$LOG_FILE"
        sleep "$RESTART_DELAY"
    done
) </dev/null >>"$LOG_FILE" 2>&1 &

pid=$!
echo "$pid" >"$PIDFILE"
disown "$pid" 2>/dev/null || true
