# How it works

AdGuard Home runs on a separate host. Every LAN client uses it for DNS, which
is what gives per-client attribution and filtering. When it goes away, DNS
goes away, and on a home network that reads as "the internet is broken".

This document explains the mechanism that keeps DNS working during those
outages, why it is built the way it is, and which parts must not be "tidied
up" without breaking it.

---

## The design: an absent standby resolver

DHCP hands every client **two** DNS servers:

| | Address | What it is |
|---|---|---|
| **DNS 1** | `192.168.1.99` | AdGuard Home |
| **DNS 2** | `192.168.1.2` | The failover address |

The essential property: **`192.168.1.2` does not exist while AdGuard is
healthy.** No interface is bound to it, nothing answers ARP for it, and no
client can reach it.

When AdGuard stops answering, a daemon on the UDM binds `192.168.1.2` to the
LAN bridge:

```
ip addr add 192.168.1.2/32 dev br0
```

The UDM's dnsmasq runs with `bind-dynamic`, which watches for address changes
via netlink and starts serving DNS on the new address by itself. Clients that
already hold `192.168.1.2` as their secondary find it suddenly answering.

When AdGuard recovers, the address is removed and the standby vanishes again.

That is the entire mechanism. No iptables rules, no DNAT, no changes to any
UniFi-generated file, and nothing installed on the AdGuard host.

### Why the standby must be absent

This is the part most likely to be "simplified" into something broken, so it
is worth stating plainly.

A secondary DNS server that is **always reachable** gets used during normal
operation. Resolvers do not uniformly treat DNS 2 as a cold standby: some
round-robin across the list, some race both servers and take the first reply,
some rank servers by recent latency. RFC 2132 makes the DHCP option 6 ordering
a **preference, not a mandate**.

So an always-present secondary means some fraction of queries silently bypass
AdGuard — losing filtering and corrupting attribution, continuously, with no
symptom to notice. That is why listing a public resolver like Quad9 as DNS 2
is wrong, and it is the single most tempting change to make here.

An address that does not exist cannot be raced, ranked, or round-robined onto.
Absence is what forces every client onto AdGuard.

### This has been measured, not just reasoned

The argument above is only as good as its premise: that clients which *try* the
standby during normal operation get nowhere. That premise was tested on this
network with the standby advertised as DNS 2 and AdGuard healthy, by capturing
every packet touching `192.168.1.2` on all interfaces:

```sh
tcpdump -ni any -tttt 'arp host 192.168.1.2 or ip host 192.168.1.2'
```

Over a 26-minute steady-state window:

| Measurement | Result |
|---|---|
| Distinct clients that attempted `192.168.1.2` | **5** |
| Total ARP requests for it | **46** |
| ARP **replies** | **0** |
| Packets that ever reached it | **0** |

Both halves of this matter, and they say different things.

**Clients really do reach for the secondary while the primary is healthy.** The
comfortable assumption that an ordered DHCP list is obeyed as a strict
preference is wrong here — five separate devices, including Windows machines,
attempted the standby at a low rate with AdGuard answering normally. Had DNS 2
been a public resolver, those attempts would have **succeeded**, and that
fraction of queries would have bypassed filtering and attribution silently.
This is the single most tempting change to make to this design, and the capture
is what shows it would be a real leak rather than a theoretical one.

**Nothing bypassed AdGuard.** Every attempt died at ARP. No client received a
reply, so no client ever sent a DNS query to the standby, so no query escaped
filtering or attribution. The mechanism works exactly as designed, and the cost
of advertising an absent address is a small amount of unanswered broadcast
traffic.

The measurement is cheap and non-disruptive. Re-run it after any change to the
DHCP DNS list — a non-zero count in the "replies" row means something has
started answering for the standby while AdGuard is up, which is the failure this
whole design exists to prevent.

### What a real outage looks like (Drill 1, 2026-08-02)

The steady-state capture above was repeated during a genuine AdGuard outage —
the container was stopped for 200 seconds. The contrast is the whole design in
two columns:

| | AdGuard healthy | AdGuard down |
|---|---|---|
| ARP replies for `192.168.1.2` | 0 | **29** |
| Packets reaching it | 0 | **1,249** |
| Distinct clients using it | 0 | **11** |

Eleven client devices moved to the standby on their own. **Nothing was
configured on any client**, before or during. DHCP had already given every
device both addresses; the daemon simply made the second one exist.

Timings measured from the client side:

| Transition | Measured |
|---|---|
| Container stopped → daemon engaged | ~29s (3 probes × `INTERVAL`, plus detection) |
| `192.168.1.2` bound → Linux client resolving again | **1s** |
| **Total client-visible stall (Linux / `systemd-resolved`)** | **~30s** |
| Client-visible stall (Windows) | **none perceptible** |
| Recovery gap, either stack | **none — resolution unbroken** |

### Why Windows barely notices and Linux stalls for 30s

This is the useful surprise, and it reverses what the steady-state numbers first
appeared to say.

The 46 unanswered ARP requests measured during normal operation looked like a
*cost* of eager distribution — clients wasting effort on an address that is not
there. They are better understood as an **investment**. A resolver that already
keeps the secondary in its working set does not need to discover it during an
outage; the moment the address exists, that resolver is already using it.

That is why Windows clients — which were among those reaching for `.2` while
AdGuard was perfectly healthy — reported no perceptible interruption at all,
while `systemd-resolved`, which honours the DHCP ordering more strictly, stalled
for the full detection window before switching.

The practical consequence: **the client-visible stall is bounded by the daemon's
detection latency, not by client resolver behaviour.** Clients that pre-probe pay
close to zero; clients that strictly obey preference order pay the detection
window. Lowering `INTERVAL` shortens the worst case for the strict ones, at the
cost of more probe traffic. Nothing about this is improved by touching a client.

Recovery is nearly free for both, and that is deliberate rather than lucky: the
daemon withdraws the standby only after AdGuard is answering again, so the
replacement is serving before the standby disappears. Stray traffic to the
withdrawn address stopped within ~90 seconds and cost 12 packets across 6
clients.

### Why AdGuard's own address is never impersonated

An earlier design had the UDM take over `192.168.1.99` during an outage. It
was abandoned for reasons worth recording:

- **It severs administrative access.** If the container is down but the host
  is up, impersonating `.99` means `ssh 192.168.1.99` reaches the UDM instead
  of the machine you need to fix. The address is stolen at precisely the
  moment you need it.
- **It creates a live address conflict.** With the host still up, both the
  host and the UDM claim `.99`. Clients see the MAC flap between them.

Every Tier 2 test asserts that **no UDM interface has claimed `.99`** while
failover is engaged. That assertion is direct rather than inferential — the
older form, "SSH to `.99` still works", could be confounded by an unrelated SSH
problem and needs credentials the test may not have. It is retained as a
secondary signal when `ADGUARD_SSH_USER` is configured. Both exist specifically
to fail if anyone reintroduces impersonation.

---

## The daemon

`dns-failover.sh` runs on the UDM under a supervisor in `/data/on_boot.d/`. It
loops on a fixed interval and probes.

### Two probes, on different schedules

**Primary — "is AdGuard serving usable answers?"** Runs every iteration:

```
dig @192.168.1.99 dns.quad9.net A +tries=1 +time=2
```

`PROBE_NAME` must be a name AdGuard will **not** filter. A blocked name
returns NXDOMAIN or a sinkhole address, which classifies as *success* — so a
filtered probe name means failover never fires, silently, forever.
`tests/test-normal.sh` checks for this.

**Corroborating — "would failing over actually help?"** Runs **only** in the
`PENDING` state, never during normal operation:

```
dig @127.0.0.1 <random-label>.example.com A +tries=1 +time=2
```

During a WAN outage, AdGuard and the UDM are equally useless. Failing over
would move every client onto a second resolver that also cannot answer, while
destroying attribution for no benefit. The corroborating probe distinguishes
"AdGuard is broken" from "the internet is broken".

It targets the UDM's **own dnsmasq** rather than an upstream, because that is
the exact path `192.168.1.2` will serve during an outage. Testing any other
path tests the wrong thing.

### Cache-busting is mandatory

The random label is not decoration. The UDM's dnsmasq runs `cache-size=10000`.
A fixed corroborating name would be answered **from cache** and cheerfully
vouch for an upstream that is completely unreachable — the exact false
positive that would let failover engage during a WAN outage.

A fresh random label cannot be in cache, positive or negative, so it forces
real recursion.

**What makes the probe valid is that cache is bypassed — not which success
code comes back.** Either `NOERROR` or `NXDOMAIN` is accepted, because
producing either requires the full chain to have worked. Measured against
`example.com`, the answer is `NOERROR` with an empty answer section, *not*
`NXDOMAIN`. Narrowing this to a single expected RCODE would look more rigorous
and would suppress failover permanently.

`tests/test-suppression.sh` asserts the corroborating probe genuinely fails
before drawing any conclusion from it — a precondition gate, not an assumption.
Its validity depends on enumerating **every** upstream, from the union of
`/run/resolv.conf.d/main` and the `server=` directives in the dnsmasq config,
across both address families: dnsmasq runs with `all-servers`, so one unblocked
resolver would leave the outage un-induced and the test would pass having
tested nothing.

---

## The `dig` parsing contract

**When failover fires is decided entirely by how one line of `dig` output is
parsed.** That makes it the highest-leverage code in the project and the
easiest to unintentionally change. It is stated here verbatim, asserted in
`tests/test-parsing.sh`, and must not drift.

`dig` emits the response header as:

```
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 12345
```

The contract:

1. Select the line containing `->>HEADER<<-`.
2. Extract the token following `status: `, up to the next comma. That value is
   the RCODE and the **sole** input to classification.
3. If no such line exists, the result is `TIMEOUT`. On no reply `dig` prints
   `;; connection timed out; no servers could be reached` and emits no header,
   so absence of the field is itself the timeout signal.

**Explicitly not part of the contract, and not to be reintroduced:** `dig`'s
exit status, `+short` output, and emptiness of the answer section.

`dig` is **required**. There is no `drill` or `nslookup` fallback, because
their output formats differ and a fallback parser would silently change
classification. The daemon exits with a fatal error if `dig` is missing.

### Classification

| RCODE | Verdict | Why |
|---|---|---|
| `NOERROR` | success | Resolver processed the query and the chain worked |
| `NXDOMAIN` | success | Same — a definitive "no such name" proves the chain worked |
| `SERVFAIL` | **failure** | A valid response per RFC 1035, but the user has no working DNS |
| `REFUSED` | **failure** | Same |
| `TIMEOUT` | **failure** | Nothing answered |
| anything else | **failure** | Fail closed rather than read as healthy |

`SERVFAIL` deserves emphasis. It is a well-formed, standards-compliant
response, and treating it as "up" is a natural-looking mistake. But from the
user's perspective DNS is broken, and that is the perspective that decides
whether failover helps. A daemon that reported everything fine while clients
got nothing would be worse than no daemon.

### The anti-pattern this replaces

The retired implementation tested `[ $? -eq 0 ] && [ -n "$out" ]`. That
conflates two things in the dangerous direction:

- **`SERVFAIL` reads as success.** Exit status is 0 and output is non-empty,
  so a completely broken AdGuard looks healthy and failover never fires.
- **`NOERROR` with an empty answer section reads as failure.** A perfectly
  working resolver returning NODATA looks dead, causing failover for no reason.

Both cases are asserted in `tests/test-parsing.sh`.

---

## State machine

Three states. **Suppression is a boolean flag on `PENDING`, not a fourth
state:** it records whether corroboration has failed at least once in the
current `PENDING` episode, exists only to make logging edge-triggered, has no
transitions of its own, and never alters behaviour.

| State | Probes run | Transitions |
|---|---|---|
| `UP` | primary only | → `PENDING` after `FAIL_THRESHOLD` consecutive primary failures |
| `PENDING` | primary **and** corroboration, every iteration | → `FAILED_OVER` when corroboration succeeds and the bind succeeds<br>→ `UP` after `RECOVER_THRESHOLD` consecutive primary successes |
| `FAILED_OVER` | primary only | → `UP` after `RECOVER_THRESHOLD` consecutive primary successes, then the address is removed |

Every iteration that ends still in `FAILED_OVER` also re-asserts that the
standby is actually on the interface, and re-adds it if not. The bind used to
happen once, on the `UP` → `FAILED_OVER` edge, and was never re-checked — so
anything that rewrote the bridge took the fallback away for the rest of the
outage while the daemon went on believing it was protecting clients. On this
device that is not hypothetical: UniFi regenerates interface configuration on
settings writes and firmware updates, and firmware updates are automatic and
unattended. It was silent in both directions, because nothing logged the
disappearance and `disengage_failover()` returns early when the address is
already absent, so recovery logged `FAILED_OVER → UP` with no matching
`FAILOVER CLEARED` and the episode read as clean.

The check is guarded on the state *after* the recovery test, so the iteration
that disengages cannot re-add the address it just removed, and its logging is
edge-triggered on the disappearance rather than per iteration.

Operational consequence: the daemon cannot distinguish your `ip addr del` from
a firmware update's. To take the standby down by hand during an outage, stop
the daemon first — see `docs/rollback.md`.

Two properties that are easy to lose in a refactor:

**Corroboration runs on no `UP` iteration.** Normal operation is exactly one
query per cycle, against AdGuard. An implementation that corroborated every
iteration would still fail over correctly — so no behavioural test would catch
it — while leaking a continuous trickle of random-label lookups off the
network. `tests/test-normal.sh` watches loopback DNS traffic and asserts zero
such queries while healthy.

**`PENDING` does not re-accumulate a failure threshold.** If failover is
suppressed by a WAN outage and the WAN then recovers while AdGuard is still
down, failover engages **within one `INTERVAL`** rather than waiting for a
fresh `FAIL_THRESHOLD` cycle — because corroboration is retried on every
`PENDING` iteration, not because any counter is preserved. `fail_count` is a
`UP`-state counter and is never read in `PENDING`.
`tests/test-state-machine.sh` scenario 5 asserts this.

The primary probe result is also computed once at the top of the loop and
reused, so a fresh `UP → PENDING` transition is corroborated in the same
iteration. Deferring it to the next pass would silently add one `INTERVAL`
beyond the documented detection latency.

### Timing

```
detection latency = INTERVAL x FAIL_THRESHOLD + PROBE_TIMEOUT
                  = 10 x 3 + 2
                  = 32s worst case
```

Lowering `INTERVAL` to 5 roughly halves it, at the cost of more probe traffic.

---

## The upstream drift guard

If the UDM's own upstream resolver is ever set to `192.168.1.99`, the failover
path forwards into the same dead resolver it is supposed to be escaping. The
design becomes inert while continuing to look healthy, and nothing else in the
system would notice.

This is not hypothetical: UniFi regenerates its DNS configuration on settings
changes, controller updates, firmware upgrades, and WAN lease renewals.

The daemon re-reads `/run/resolv.conf.d/main` every iteration and logs on
**transition only** — one line when drift appears, one when it clears.

Edge-triggering is a functional requirement, not a style preference. At a 10s
interval, per-iteration logging would produce ~8,600 lines a day, burying the
transition that matters and rotating away the history.
`tests/test-drift.sh` asserts that a full drift cycle produces exactly two
lines.

The guard **warns but does not act**. Binding the standby on drift would take
clients off a perfectly healthy AdGuard.

---

## Failure handling

| Situation | Behaviour |
|---|---|
| AdGuard container stops, host stays up | Failover engages. `.99` still answers ARP, ICMP and SSH, so the host stays administrable |
| AdGuard host reboots or dies | Failover engages. Probes record `TIMEOUT` |
| WAN outage (AdGuard and UDM both dead) | Failover is **suppressed** and logged distinctly. It engages within one `INTERVAL` of the WAN returning if AdGuard is still down |
| Daemon exits on a signal | Trap removes the standby address before exiting. The loop uses `sleep & wait` so the handler runs immediately rather than up to one `INTERVAL` later |
| Daemon crashes or is `SIGKILL`ed | The supervisor restarts it, and the daemon reconciles on startup by removing any stranded standby address |
| UDM reboots | `/data` survives; the boot hook restarts the supervisor. `/run` is tmpfs and is regenerated by UniFi |
| `ip addr add` fails persistently | Logged once (edge-triggered), retried every `INTERVAL` |
| `dig` missing | Fatal. The daemon refuses to start rather than guess at parsing |
| DHCP list still contains a public resolver as DNS 2 | **Not detectable from the UDM.** Check the UniFi UI — this silently bypasses AdGuard |

### The restart backoff

The supervisor escalates its restart delay from 5s to 60s when the daemon
fails within 60s of starting, and resets once it stays up. Without this, an
unrecoverable startup failure (missing `dig`, unreadable config) would flood
the log at 12 lines a minute indefinitely.

---

## Rejected alternatives

Recorded so this ground is not re-trodden.

**iptables DNAT interception** — the retired design. A rule in
`nat/PREROUTING` redirected traffic destined for `.99:53` to a public
resolver. It never worked: on a flat `/24`, clients ARP for `.99` and reach it
**directly at layer 2**. The packets never traverse the UDM's routing path, so
`PREROUTING` never saw them and the rule was inert. Its test suite passed
because it verified the rule had been *inserted*, not that failover
*functioned*, and probed from a workstation on the same L2 segment.

**UDM impersonates `.99`** — severs SSH to the AdGuard host during an outage,
and creates a live address conflict when the host is up.

**UDM as the sole DNS server, forwarding to AdGuard** — preserves attribution
only via EDNS Client Subnet, and costs cache correctness plus a dependency on
a UniFi-generated tmpfs file that is regenerated without warning. The
absent-standby design has no attribution problem to solve in the first place.

**A permanently-present standby** — silently bypassed during normal operation.
See "Why the standby must be absent".

**Lazy distribution** (adding DNS 2 only when needed) — DHCP cannot push
changes. Clients renew at T1, ~12h into a 24h lease (RFC 2131), so the
information would arrive long after it was needed.

**Anything installed on the AdGuard host** — a failover mechanism that depends
on the failing component is not a failover mechanism.

---

## Standing operational checks

Ongoing, not one-time:

- **After any UniFi settings change, controller update, or firmware upgrade:**
  confirm the UDM's upstream in `/run/resolv.conf.d/main` has not reverted to
  `192.168.1.99`, and that the DHCP DNS list still carries both entries. The
  daemon logs drift, but a log is only useful if someone reads it.
  `tests/test-normal.sh` re-asserts all of this.
- Confirm the boot hook still runs and the daemon is alive after a firmware
  upgrade. `/data` survives upgrades; the surrounding platform may not behave
  identically.
- Watch for `.2` appearing in the DHCP pool after network reconfiguration. It
  sits below the default pool floor of `.6`, but the floor is a setting.
