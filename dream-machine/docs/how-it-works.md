# How it works

A deep-dive into the DNS failover setup for the UDM SE.

## The problem

I want two things at once:

1. **All LAN DNS goes through AdGuard Home** for ad and tracker blocking,
   per-client visibility, and DoH upstreams.
2. **If AdGuard is down, DNS still works** — falling back to Quad9 (a safe,
   no-log, malware-blocking resolver with a DoH endpoint at
   `dns.quad9.net`).

UniFi's built-in DHCP DNS field lets you hand out a list of DNS servers, but
clients don't strictly use them in order — most OSes round-robin, race them,
or pick the fastest. Listing "AdGuard, then Quad9" leaks queries to Quad9
even when AdGuard is up, and losing per-client visibility along the way.

Real primary-with-failover behavior needs an active health check.

## The chosen approach: transparent DNAT on the UDM

DHCP hands out only AdGuard's IP as the DNS server. A small bash daemon on
the UDM continuously probes AdGuard. When AdGuard fails:

```
iptables -t nat -A PREROUTING \
    -d 192.168.1.99 -p udp --dport 53 \
    -j DNAT --to-destination 9.9.9.9:53
```

(and the same for TCP). Traffic destined for AdGuard's IP:53 gets silently
rewritten to Quad9's IP:53 in the kernel's netfilter NAT engine.

The reply packet from Quad9 comes back and passes through **conntrack**,
which remembers the original destination the client was talking to and
rewrites the source of the reply back to `192.168.1.99` before delivering
it. The client sees a perfectly normal response from `192.168.1.99` and has
no idea Quad9 was involved.

When AdGuard comes back, the daemon deletes the rule. Traffic flows to
AdGuard directly, and per-client dashboards / rules resume immediately.

## Why this specifically

Options considered:

### A) DHCP option swap — rejected

Modify the DHCP config to hand out Quad9 when AdGuard is down. Simple, but
clients cache the DHCP DNS setting for the entire lease (usually hours). A
client whose lease was issued while AdGuard was up will keep pointing at
AdGuard until it renews — which means several hours of broken DNS.
Unacceptable for a residential network where user experience matters.

### B) DNAT interception — chosen

- Zero client-side impact.
- Instant failover (bounded by the health-check interval).
- AdGuard sees real client IPs when it's up, so per-client stats and rules
  work fully.
- Uses only stock UniFi OS components (iptables, bash) plus the
  well-established `unifi-common` boot-script framework for persistence.
- One rule per protocol; easy to reason about; easy to uninstall.

### C) UDM as forwarding resolver — rejected

Run a local dnsmasq/Unbound on the UDM that forwards to AdGuard normally
and Quad9 on failure. Instant failover, but AdGuard would see **all queries
as coming from the UDM's IP**. That destroys the per-client statistics,
per-client filtering rules, and per-client blocklist features that are the
main reason to run AdGuard in the first place.

### D) HA AdGuard pair — rejected

Standing up a second AdGuard instance would give me real redundancy without
scripts. It also doubles the operational surface, and I don't want to
maintain two AdGuards.

## Why the debounce

DNS packets get lost occasionally, especially over Wi-Fi. Without a
debounce, a single dropped probe would trigger failover. With
`FAIL_THRESHOLD=3` at `INTERVAL=10`, we require ~30 seconds of continuous
failure before flipping — a fair tradeoff between avoiding flap and
recovering reasonably quickly. Recovery uses a lower threshold (`2`) so
service restoration is a bit snappier than outage detection.

## Persistence across firmware upgrades

UniFi OS 4.x wipes the root filesystem on firmware update, but preserves
`/data`. The community `unifi-common` package
(`github.com/unifi-utilities/unifi-common`) exploits this by installing:

- `/etc/systemd/system/udm-boot.service` — a systemd unit that runs on
  every boot and executes every executable file in `/data/on_boot.d/`.
- The service itself is copied from `/data/` on install, so it survives the
  firmware wipe too.

Our boot hook (`/data/on_boot.d/15-adguard-failover.sh`) launches the
supervisor loop, which launches the daemon. Everything lives in `/data`, so
nothing to reinstall after a firmware upgrade.

**Exception:** major UniFi OS version bumps (e.g. 3.x → 4.x) have
historically broken `unifi-common` a small number of times, requiring a
rerun of the upstream installer. This is well-documented in the project's
issues and typically fixed within days.

## What about DoH clients that bypass DHCP?

Firefox, Chrome, Windows 11, iOS 14+, and other modern clients can do their
own **DNS-over-HTTPS**, bypassing DHCP DNS entirely. Those queries never
touch AdGuard (unless you've explicitly configured the client to use
AdGuard's DoH endpoint like `https://192.168.1.99/dns-query`), and they
will never be affected by this failover either. Handling them requires
either:

- Blocking their DoH endpoints at the firewall (breaks features), or
- Explicitly pointing them at AdGuard's DoH endpoint (per-client
  configuration).

Both are out of scope for this project.

## What about the health check probe itself?

The daemon uses `dig` to query `dns.quad9.net` against AdGuard. Choosing a
real, popular name that AdGuard is unlikely to block gives us a check that
exercises the full recursion path (AdGuard → its upstream). If AdGuard's
upstream is broken but AdGuard itself is fine, we treat that as "AdGuard is
down" — which is correct from the client's perspective: DNS wouldn't work
anyway, so failover is the right response.

If you'd rather probe only local reachability of AdGuard (not its upstream
health), point `PROBE_NAME` at a locally-answered zone or a rewrite AdGuard
serves directly.

## Failure modes and mitigations

| Failure | Mitigation |
| --- | --- |
| Daemon crashes | Boot-hook supervisor loop restarts it within `RESTART_DELAY` (5s) |
| Daemon exits cleanly (e.g. SIGTERM during upgrade) | Signal handler removes DNAT rules before exit so no stale redirection |
| Duplicate rules from a botched restart | Startup reconciliation removes any pre-existing rules before entering the loop |
| Log file grows unbounded | Size check every iteration; truncated to half-size at 5 MB |
| UDM reboot | udm-boot.service re-runs the boot hook, which starts the supervisor |
| UDM itself is down | No DNS anywhere; same as with any single-router setup — failover cannot help |
| AdGuard's upstream is broken but AdGuard is reachable | Probe against a real internet name will fail → we correctly fail over |
| DHCP DNS list accidentally still contains Quad9 as secondary | Clients might use it directly, bypassing AdGuard. `verify/test-normal.sh` doesn't catch this — check the UniFi UI |

## Uninstall

`uninstall/uninstall.sh` reverses everything: stops the supervisor, deletes
the boot hook and daemon files, and flushes any lingering DNAT rule. The
`unifi-common` package is left in place (it's a general-purpose framework
you might use for other things); the ReadMe documents how to remove it if
desired.
