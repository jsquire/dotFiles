# Failure drills

Tier 3 of the test suite. These are **manual**, deliberately: they cover the
one question no automated test can answer, and they are the only procedures in
this project that involve a real AdGuard outage.

Everything else is automated and safe:

| Tier | Where | Touches | Run it |
|------|-------|---------|--------|
| 0 | `./install/install.sh --preflight-only` | nothing — reads the UDM; the hard gate binds the standby for ~2s and removes it | any time |
| 1 | `tests/test-parsing.sh`, `tests/test-state-machine.sh`, `tests/test-lib.sh`, `tests/test-hardening.sh`, `tests/test-install.sh` | nothing — offline | any time |
| 2 | `tests/test-normal.sh`, `test-failover.sh`, `test-host-down.sh`, `test-suppression.sh`, `test-drift.sh` | the UDM only, reversibly | any time before the standby is in DHCP; in a window after |
| 3 | this document | the AdGuard host | deliberately, prepared |

---

## Why these cannot be automated

Tier 2 induces failure by severing the **UDM's view** of AdGuard. That proves
the daemon engages, that dnsmasq picks the standby address up, and that a
client gets answers from it. What it cannot do is make AdGuard unreachable
**from a client**, because clients reach `192.168.1.99` L2-direct and never
traverse the UDM's `OUTPUT` chain.

So Tier 2 cannot answer:

> When AdGuard genuinely disappears, do real clients actually fail over to the
> standby, and how long does each one stall before it does?

That is a property of every client's resolver implementation, not of this
daemon. RFC 2132 makes the DHCP option 6 ordering a **preference, not a
mandate**, and stub resolvers differ widely in how long they wait, whether they
retry the primary, and whether they remember the failure.

The numbers this drill produces are the numbers that belong in the docs. Until
it has been run, every stall figure is a guess.

---

## Drill 1 — Client failover measurement

**Purpose:** measure the client-visible stall for each device class.
**Blast radius:** real. All LAN DNS goes through the standby for the duration.
**Prepare for:** roughly 10 minutes of degraded, unfiltered DNS.

### Before you start

- [ ] Tier 1 and Tier 2 suites pass.
- [ ] `FAILOVER_IP` is in the DHCP DNS list, second.
- [ ] Clients have renewed leases and hold both servers. Check one:
      `resolvectl status` on Linux, `ipconfig /all` on Windows,
      `scutil --dns` on macOS.
- [ ] You have a terminal on the UDM that does **not** depend on DNS —
      `ssh root@192.168.1.1` by IP, not by name.
- [ ] Someone knows you are doing this.

### One behaviour that will surprise you mid-drill

While failover is engaged, the daemon **re-asserts** the standby address. It
re-checks every `INTERVAL` that `192.168.1.2` is still on `br0` and restores it
if it has gone.

So during a drill — while AdGuard is still down — `ip addr del 192.168.1.2/32
dev br0` **does not stick**. The address returns within one `INTERVAL`, and
because the repair is logged edge-triggered you will see it announced once and
then nothing, which reads like it failed to work.

This is deliberate: the daemon cannot distinguish an operator's `ip addr del`
from a firmware update flushing the interface, and the latter is the case that
matters. To take the standby down during a drill you must **stop the daemon
first**. `docs/rollback.md` is ordered that way for this reason.

### Observers — read-only, start these first

Open each in its own terminal and leave running:

```sh
# 1. Daemon log, live
ssh root@192.168.1.1 "tail -f /data/adguard-failover/failover.log"

# 2. Standby address, once a second
ssh root@192.168.1.1 "while :; do date +%T; ip -4 -o addr show dev br0 | grep -c 192.168.1.2; sleep 1; done"

# 3. Continuous resolution from each device under test
while :; do date +%T; dig +short dns.quad9.net A | head -1; sleep 1; done
```

Observer 3 is the measurement. Run it on every device class you care about
before inducing anything, so you capture the transition rather than the
aftermath.

### Induce

On the AdGuard host:

```sh
docker stop <adguard-container>
```

Record the wall-clock time. This is `T0`.

### Expect

| What | When | Where to see it |
|------|------|-----------------|
| Daemon logs `probe: ... (1/3)`, `(2/3)`, `(3/3)` | `T0` + up to 30s | observer 1 |
| Daemon logs `state: UP → PENDING` | at the 3rd failure | observer 1 |
| Daemon logs `FAILOVER ENGAGED` | same iteration | observer 1 |
| `192.168.1.2` appears on `br0` | same moment | observer 2 |
| Each client resumes resolving | device-dependent — **this is the number you are here for** | observer 3 |

Record, per device: seconds from `T0` until observer 3 produces answers again.

Devices worth measuring separately, because their resolvers differ:

- Linux with `systemd-resolved`
- macOS
- iOS
- Windows
- Android
- Nintendo Switch, smart TVs, and anything else with an embedded stub resolver

### Restore

```sh
docker start <adguard-container>
```

Record the wall-clock time. This is `T1`.

### Measure the recovery transition too — it is not symmetric

The failure transition is the one everybody expects to measure. The recovery
transition has a different shape, and needs its own numbers.

On recovery the daemon **withdraws** `192.168.1.2`. Any client that moved to the
standby is now pointed at an address that has just ceased to exist.

Measured on this network (Drill 1, 2026-08-02), recovery cost almost nothing:

| Measurement | Result |
|---|---|
| Stray packets to `.2` after withdrawal | **12, across 6 clients** |
| Last stray packet | **~90s after withdrawal** |
| ARP replies for `.2` after withdrawal | **0** |
| Linux client resolution gap at recovery | **none — unbroken** |

The reason recovery is nearly free is a **design property, not luck**: the daemon
withdraws the standby only *after* confirming AdGuard is answering again. The
replacement is already serving before the standby disappears, so there is no
interval in which a client has neither.

Keep observer 3 running through `T1` anyway and record, per device, seconds from
`T1` until it resolves normally. Also record who is still reaching for the
withdrawn standby — answered from the UDM, not the client, and it costs nothing:

```sh
# Who is still trying to reach the withdrawn standby, and when did they stop?
ssh root@192.168.1.1 "tcpdump -ni any -tttt 'arp host 192.168.1.2 or ip host 192.168.1.2'"
```

Nothing answers `192.168.1.2` once it is withdrawn, so every line is a client
paying for the recovery. A device still appearing long after `T1` is silently
degraded for that whole period.

Note when recording this: **identify each device's resolver stack from the
device, not from its DHCP hostname.** Hostnames are user-chosen labels and say
nothing reliable about the stub resolver, which is the only thing that
determines the behaviour being measured here.

### Verify restored — do not skip

- [ ] Daemon logs `FAILOVER CLEARED` within `RECOVER_THRESHOLD × INTERVAL`.
- [ ] `ip -4 -o addr show dev br0` no longer lists `192.168.1.2`.
- [ ] `dig @192.168.1.2 dns.quad9.net` times out from a client.
- [ ] `dig @192.168.1.99 dns.quad9.net` answers.
- [ ] AdGuard's query log shows **true client IPs**, not `192.168.1.1`. If it
      shows the UDM, attribution is broken and something is forwarding.
- [ ] `./tests/test-normal.sh` passes clean.

### Afterwards

Fold the measured figures into `docs/how-it-works.md`, replacing the
pre-measurement hypotheses. A hypothesis left in place after it could have been
measured is the failure mode that produced the retired design.

---

## Drill 2 — Host down

**Status: deliberately not run. Superseded by Drill 1 plus Tier 2.** See the
reasoning below before deciding to run it — it is not an oversight.

**Purpose:** confirm the whole chain behaves when the address is absent from
the network entirely, not merely unresponsive — including that the standby
clears cleanly once the host returns and the container restarts on its own.

Identical to Drill 1, with two differences:

- **Induce** by powering the host down or pulling its link, rather than
  stopping the container.
- **Additionally verify on restore** that the container came back by itself and
  that the daemon cleared failover without intervention. A host that returns
  without its container leaves the daemon correctly still engaged — that is not
  a fault, but it must be recognised rather than debugged.

### Why this was not run

Each thing it could contribute is already covered:

| Would test | Already covered by |
|---|---|
| Daemon trigger when the host is absent | Tier 2 `test-host-down.sh`, which `DROP`s all traffic to `ADGUARD_IP` — genuine silence, the real host-down wire behaviour |
| Container restarting unattended | Independently exercised on the AdGuard host |
| Client-visible stall | Drill 1, which measured the **worse** case |

That last row is the substantive one. In Drill 1 the host stayed up with the
container stopped, and the daemon logged `TIMEOUT`, not `REFUSED` — queries to
`192.168.1.99` vanished into silence with **no error signal returned to
clients**. That is the slowest way for a client to discover the failure.

With the host truly down, `192.168.1.99` stops answering ARP, and clients get a
fast, definitive `EHOSTUNREACH` instead of waiting out a silent timeout. Since
the measured client stall is bounded by the daemon's detection latency — which
is identical either way — a host-down drill should reproduce Drill 1's numbers
at best and cannot plausibly be worse.

**Residual gap, stated honestly:** no one has measured whether some embedded
stub resolver reacts pathologically to `EHOSTUNREACH` where it tolerates a
timeout. Judged low risk, and not worth a whole-host outage to rule out. If the
AdGuard host ever goes down on its own, treat it as a free drill and record what
the clients did.

Do not run this drill to test the daemon's trigger. Tier 2's
`test-host-down.sh` already covers that, without taking anything down.

---

## What to do if a drill goes wrong

Use `docs/rollback.md`. It is three commands and no prose, for exactly this
moment.
