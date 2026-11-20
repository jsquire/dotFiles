#!/bin/sh

set -u

private_key="$HOME/.ssh/github_signing"
public_key="$HOME/.ssh/github_signing.pub"

parent_process=$(/bin/ps -p "$PPID" -o comm= 2>/dev/null)

case "$parent_process" in
    /sbin/launchd|launchd)
        ;;
    *)
        /usr/bin/logger -t github-signing \
            "Refused to load the signing key outside the macOS login job."
        exit 0
        ;;
esac

if [ -n "${SSH_CONNECTION:-}" ] || [ -n "${SSH_CLIENT:-}" ]; then
    /usr/bin/logger -t github-signing \
        "Refused to load the signing key from a remote SSH session."
    exit 0
fi

if [ ! -r "$private_key" ] || [ ! -r "$public_key" ]; then
    /usr/bin/logger -t github-signing \
        "Signing identity is unavailable; run the documented manual setup step."
    exit 0
fi

local_socket=$(/bin/launchctl getenv SSH_AUTH_SOCK 2>/dev/null)

if [ -z "$local_socket" ] || [ ! -S "$local_socket" ]; then
    /usr/bin/logger -t github-signing \
        "The local launchd SSH agent socket is unavailable."
    exit 0
fi

expected_key=$(
    /usr/bin/awk 'NF >= 2 { print $1 " " $2; exit }' "$public_key"
)

if [ -z "$expected_key" ]; then
    /usr/bin/logger -t github-signing \
        "The public signing key is not a valid SSH public key."
    exit 0
fi

if SSH_AUTH_SOCK="$local_socket" /usr/bin/ssh-add -L 2>/dev/null |
   /usr/bin/awk 'NF >= 2 { print $1 " " $2 }' |
   /usr/bin/grep -Fqx -- "$expected_key"; then
    exit 0
fi

if ! SSH_AUTH_SOCK="$local_socket" \
     SSH_ASKPASS_REQUIRE=never \
     /usr/bin/ssh-add --apple-use-keychain "$private_key" \
     </dev/null >/dev/null 2>&1; then
    /usr/bin/logger -t github-signing \
        "Could not load the signing key noninteractively; run the documented manual setup step."
fi
