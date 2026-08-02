# Dream Machine — AdGuard DNS failover

Keeps DNS working for LAN clients when AdGuard Home goes down, without
weakening AdGuard's filtering or attribution while it is healthy.

Everything runs on the UDM SE using stock components (`bash`, `dnsmasq`,
`iproute2`, `systemd`). **Nothing is installed on the AdGuard host** — a
failover mechanism that depends on the failing component is not a failover
mechanism.

Boot persistence uses the `/data/on_boot.d` convention established by
[`unifi-common`](https://github.com/unifi-utilities/unifi-common), but the
package is not installed. Its `remote_install.sh` is a `curl | bash` of an
unpinned HEAD into a root shell on the router, and the only thing it does that
matters is write one systemd unit. That unit is vendored at
[`install/udm-boot.service`](install/udm-boot.service) and installed directly.
If `udm-boot.service` is already enabled — because `unifi-common` is installed,
or a previous run put it there — the installer leaves it alone.

For the mechanism, the design rationale, and the contracts that must not
drift, see [`docs/how-it-works.md`](docs/how-it-works.md).

---

## The short version

DHCP hands every client two DNS servers:

| | Address | What it is |
|---|---|---|
| **DNS 1** | `192.168.1.99` | AdGuard Home |
| **DNS 2** | `192.168.1.2` | Failover — **does not exist** while AdGuard is healthy |

A daemon on the UDM probes AdGuard. When it stops answering, the daemon binds
`192.168.1.2` to `br0`; dnsmasq is running `bind-dynamic`, so it picks the
address up and starts answering. When AdGuard recovers, the address is
removed and the standby vanishes again.

Two things follow that are easy to get wrong later:

- **DNS 2 must not be a public resolver.** An always-reachable secondary gets
  used opportunistically by resolvers that race or round-robin, silently
  bypassing AdGuard during normal operation. `192.168.1.2` is safe *because*
  it does not exist until it is needed.
- **AdGuard's own address is never impersonated.** `ssh 192.168.1.99` keeps
  working throughout an outage, which is exactly when you need it.

---

## Repository layout

| Path | What it is |
|---|---|
| `scripts/dns-failover.sh` | The daemon. Probes AdGuard, manages the standby address |
| `scripts/boot-hook.sh` | Supervisor; deployed to `/data/on_boot.d/15-adguard-failover.sh` |
| `scripts/config.env.example` | Configuration template — copy to `config.env` |
| `install/install.sh` | Deploys to the UDM. Runs preflight gates and refuses to install if any fail |
| `install/udm-boot.service` | Vendored systemd unit that runs `/data/on_boot.d` at boot |
| `uninstall/uninstall.sh` | Removes everything and verifies nothing is orphaned |
| `tests/` | Test suite — see below |
| `docs/how-it-works.md` | Mechanism, rationale, contracts, rejected alternatives |
| `docs/failure-drills.md` | Tier 3 manual drills and client-stall measurement |
| `docs/rollback.md` | Emergency rollback card |

---

## Prerequisites

1. **AdGuard Home** reachable at a fixed LAN address.
2. **SSH enabled on the UDM.** UniFi Network app → Settings → Control Plane →
   Console. Verify: `ssh root@192.168.1.1`.
3. **`dig` available on the UDM.** The daemon classifies probe results by
   RCODE and has no fallback parser. The installer refuses to proceed without
   it.
4. **A failover address outside the DHCP pool.** UniFi's default LAN pool
   starts at `.6`, so `.2`–`.5` are structurally excluded with no
   configuration to maintain. A client leasing this address would collide with
   failover at the worst possible moment.

### The UDM must not use AdGuard as its own upstream

If the UDM's own resolver points at AdGuard, the failover path forwards into
the same dead resolver and the whole design is inert. Set the UDM's WAN DNS to
a real upstream (Quad9, Cloudflare, your ISP) in UniFi.

The installer gates on this, `tests/test-normal.sh` re-asserts it, and the
daemon re-checks it every iteration — because UniFi regenerates its DNS
configuration on settings changes, controller updates, firmware upgrades and
WAN lease renewals.

---

## Install

```bash
cp scripts/config.env.example scripts/config.env
${EDITOR:-vi} scripts/config.env

./install/install.sh --preflight-only   # check first, change nothing
./install/install.sh                    # then install
```

`--preflight-only` runs SSH verification and every preflight gate, then exits
**without writing anything to the UDM**. Run it first. One of those gates —
whether dnsmasq auto-binds the standby address — can invalidate the entire
design, and a gate you cannot consult without committing to its outcome is not
a gate.

It is a flag on the installer rather than a separate script on purpose: a
standalone preflight would need its own copy of the gates, and the two copies
would drift.

At minimum set `UDM_HOST`, `UDM_SSH_USER`, `ADGUARD_IP`, `FAILOVER_IP` and
`LAN_IF`. The defaults for probe timing suit most setups.

`STANDBY_IN_DHCP` ships as `"yes"`, which is the cautious reading: it makes the
Tier 2 suite assume binding the standby is client-visible and demand a
maintenance window. Set it to `"no"` **only once you have confirmed
`FAILOVER_IP` is not yet in the DHCP DNS list** — which is the case on a fresh
install, and which is why the documented sequence runs Tier 2 before the DHCP
step. While it is `"no"`, Tier 2 carries no client exposure at all.

`config.env` is gitignored — it is per-environment, not part of the repo.

### What the installer does

It runs eight preflight gates **first** and refuses to install if any fail.
Run them on their own with `./install/install.sh --preflight-only`:

| Gate | Why it blocks the install |
|---|---|
| `dig` present on the UDM | No fallback parser exists |
| dnsmasq is `bind-dynamic` | Otherwise it never notices the standby address |
| dnsmasq listens on `LAN_IF` | Otherwise it will not serve on an address bound there |
| UDM upstream is not AdGuard | Otherwise failover forwards into the dead resolver |
| No DHCP reservation claims the failover IP | Static reservations are not bounded by the pool |
| The failover IP is silent right now | Binding a used address causes a conflict |
| dnsmasq answers on `CORROBORATE_SERVER` | The corroborating probe depends on it entirely |
| **dnsmasq actually auto-binds the address** | **Hard gate — no fallback exists** |

The last one binds the address, queries it, and removes it. If dnsmasq does
not answer, the install stops. `SIGHUP` cannot rescue this: it clears the
cache and reloads `hosts`/`ethers`/`resolv`, but does not re-read the config
or re-enumerate interfaces.

It is the only gate that changes anything, so its cleanup is defended three
ways: a trap covering every ordinary exit including a hung-up SSH session, a
token-scoped watchdog for the SIGKILL case where no trap runs, and the manual
remediation printed *before* the bind rather than after a failure — so it is
already on screen if the connection dies mid-gate. The token scoping matters:
an unscoped watchdog could later remove an address the daemon had bound for
real reasons.

There is also one advisory that does not block: whether the UDM advertises
IPv6 DNS, in which case clients preferring it are already bypassing AdGuard
today, independent of this project.

### Then, in UniFi (manual — GUI only)

Settings → Networks → your LAN → DHCP Service Management → DNS Server →
Manual:

```
DNS 1:  192.168.1.99     (AdGuard Home)
DNS 2:  192.168.1.2      (failover)
```

Both entries are required. DNS 1 alone gives no failover; DNS 2 alone bypasses
AdGuard entirely. **Do not add a public resolver to this list.**

Clients pick up the new list on their next lease renewal — roughly 12h into a
24h lease (RFC 2131 T1), or immediately on release/renew.

---

## Verify

The suite is tiered by blast radius. Nothing in Tier 1 or Tier 2 stops the
AdGuard container, reboots anything, or changes any host other than the UDM.

### Tier 1 — offline

```bash
./tests/test-parsing.sh        # the dig contract and the RCODE table
./tests/test-state-machine.sh  # the full state machine, against stubs
./tests/test-lib.sh            # the Tier 2 plumbing, against a fake UDM
./tests/test-hardening.sh      # kill-target identity, SSH policy, supply chain
./tests/test-install.sh        # install/uninstall control flow + preflight, against a fake UDM
```

No UDM, no network, no risk, sub-second. The state-machine harness runs the
real daemon against stubbed `dig`, `ip`, `arping` and `sleep`, so it can
exercise timing boundaries, bind failures and RCODEs like `SERVFAIL` and
`REFUSED` that cannot be produced on demand against a live resolver.

`test-lib.sh` covers the Tier 2 machinery itself against a fake UDM: upstream
enumeration, on which the suppression test's whole validity rests, and the
cleanup path that verifies rule removal rather than assuming it — a path that
never executes during a healthy run and so would otherwise never be tested.

`test-hardening.sh` covers install and uninstall rather than the daemon. It
builds real processes shaped exactly like the supervisor and the daemon and
asserts that the identity check used before sending a signal recognises both,
rejects an unrelated process holding a recycled PID, and rejects a `tail` or an
editor open on the daemon file — which `pgrep -f` alone matches. It then
asserts statically that the removed patterns have not come back. It also pins
the vendored `udm-boot.service` by digest — offline, against a literal, never a
runtime fetch — and asserts that every helper (`say`, `ok`, `warn`, `die`,
`info`, `note`, `hdr`) used in `install.sh` or `uninstall.sh` is defined in that
same file.

`test-install.sh` closes the last gap in the tree: `install.sh` and
`uninstall.sh` were the only executables no test ever *ran*. `bash -n` parses
but does not resolve command names, so an undefined helper on an unreached
branch stayed invisible until the branch was taken — which is exactly what
happened. It runs the real installers with stubbed `ssh` and `scp`, so the real
`udm()` and its real quoting are exercised, and covers all eight preflight
gates, the fresh-install branch, the stale-PID branches on both the install and
uninstall sides, and the standby-removal failure path.

It also covers the parts that exist to make the system reversible: that
`--preflight-only` writes nothing, that a misspelled flag is refused rather
than silently running a full install, that the hard gate removes its temporary
address on the failure path as well as the success path, and that the
provenance record survives a re-install instead of being downgraded — which
would strand `udm-boot.service` permanently.

Nothing leaves the machine. Three invariants enforce that structurally and all
three fail closed: no signal may reach a PID the harness did not spawn, no
unrewritten production path may reach execution, and any remote command the
stubs do not recognise aborts the run rather than defaulting to success. All
three are themselves tested, because an unexercised safety mechanism is an
assumption.

### Tier 2 — live, UDM-local

```bash
./tests/test-normal.sh         # steady state, standing gates, stranded rules
./tests/test-failover.sh       # AdGuard's DNS service down, host still up
./tests/test-host-down.sh      # AdGuard's address gone from the UDM entirely
./tests/test-suppression.sh    # AdGuard down during a WAN outage
./tests/test-drift.sh          # upstream drift detection
```

Failure is induced by severing the **UDM's own view** of AdGuard with tagged,
reversible `iptables` rules. AdGuard itself is healthy the whole time and
clients reach it L2-direct without traversing the UDM's `OUTPUT` chain, so they
are unaffected by the induction.

This is also the only tier that can prove the part that matters most: that the
daemon really binds the address, that dnsmasq's `bind-dynamic` really picks it
up via netlink without a restart, and that a real client really gets an answer
from it.

`test-normal.sh` is the one to run periodically. Beyond checking that things
work, it re-asserts every preflight gate, confirms the daemon is *not* doing
things it should only do during an outage, and scans both `iptables` and
`ip6tables` for stranded induction rules from an aborted test run.

**Run the full Tier 2 suite before adding the standby to DHCP.** Until it is
advertised, binding it during a test is invisible to every client. Afterwards
it is not: clients may use it and resolve unfiltered and unattributed for as
long as it is bound. Once you set `STANDBY_IN_DHCP="yes"`, the tests require a
maintenance window, cap engaged time, and report exactly how long the standby
was up.

### Tier 3 — manual drills

See [`docs/failure-drills.md`](docs/failure-drills.md). One question cannot be
answered from the UDM — whether real clients fail over, and how long each one
stalls — because clients never traverse the UDM to reach AdGuard. That needs a
genuine outage, performed deliberately, with read-only observers.

If anything goes wrong at any tier, [`docs/rollback.md`](docs/rollback.md) is
three commands and no prose.

### A note on the retired test suite

The previous suite passed for months against a design that never worked. It
verified that an iptables rule had been *inserted* rather than that failover
*functioned*, and it probed from a workstation on the same L2 segment as
AdGuard — the one vantage point that could not detect the flaw.

This suite asserts client-visible behaviour from a client, and
`tests/lib.sh` deliberately restates the `dig` parsing contract rather than
importing it from the daemon, so a change in parsing cannot quietly change the
tests' expectations along with it.

---

## Operating it

**Log:** `/data/adguard-failover/failover.log` on the UDM.

```bash
ssh root@192.168.1.1 'tail -f /data/adguard-failover/failover.log'
```

Logging is edge-triggered, so a healthy daemon is nearly silent. Continuous
output is itself a symptom.

| Log line | Meaning |
|---|---|
| `FAILOVER ENGAGED` | AdGuard failed; standby bound |
| `FAILOVER CLEARED` | AdGuard recovered; standby removed |
| `SUPPRESSED` | AdGuard is down but so is the WAN — failing over would not help |
| `SUPPRESSION CLEARED` | Either AdGuard recovered, or the WAN did and failover proceeded |
| `DRIFT` | The UDM's own upstream now points at AdGuard. **Fix this in UniFi** |
| `ERROR` | The standby address could not be bound or removed |

**Detection latency** is `INTERVAL × FAIL_THRESHOLD + PROBE_TIMEOUT` — 32s at
the defaults. Lowering `INTERVAL` to 5 roughly halves it.

**Changing configuration:** edit `scripts/config.env` and re-run
`./install/install.sh`. It is idempotent.

### Standing checks

After any UniFi settings change, controller update, or firmware upgrade, run
`./tests/test-normal.sh`. It re-checks every gate, including the two that
UniFi can silently undo: the UDM's upstream reverting to AdGuard, and the DHCP
DNS list losing an entry.

The daemon logs drift, but a log is only useful if someone reads it.

---

## Uninstall

```bash
./uninstall/uninstall.sh
```

It stops the daemon, **verifies it is actually dead** before removing the
standby address (removing it first would let a live daemon re-add it and
strand it permanently), removes all files including the log, and reports
anything left behind.

Removal of the standby address is **verified, not assumed** — `ip addr del`
returning success is not the same fact as the address being gone, and that is
the one piece of state whose survival is silently harmful. If it survives,
uninstall fails loudly and prints the manual command rather than continuing on
to delete the daemon that would otherwise have cleaned it up.

### What comes back, and what does not

Everything this project writes is removed: the daemon, boot hook, config, log,
PID file and the standby address.

`udm-boot.service` is the exception, and it is reported rather than decided.
The installer records whether the unit existed **before** it ran, in
`/data/.adguard-failover-provenance`, and uninstall reads that record before
deleting anything. So it can tell you either "this predated the project, leave
it alone" or "this is ours, and here is how to remove it" — including whether
`/data/on_boot.d` still holds other hooks that would stop running if you did.

Without that record the question is unanswerable after the fact, and both wrong
answers are damaging: disabling a pre-existing unit breaks whatever else uses
`/data/on_boot.d`, while leaving one the project created means the router is
not actually back to its prior state.

Then remove `192.168.1.2` from the UniFi DHCP DNS list. Nothing will bind it
again, so leaving it configured gives every client a permanently dead
secondary resolver.

`udm-boot.service` is left enabled, because `/data/on_boot.d` is a shared
convention and other hooks may rely on it. The script prints instructions for
removing it if nothing else does.

---

## Risk

| Concern | Assessment |
|---|---|
| Bricking the UDM | ~Zero. No firmware modification; everything lives in `/data` and `/run` |
| Breaking WAN or routing | ~Zero. The daemon only adds and removes one `/32` address on the LAN bridge |
| Breaking DNS | Bounded. Worst case is `ip addr del 192.168.1.2/32 dev br0` — see [`docs/rollback.md`](docs/rollback.md) |
| Surviving firmware upgrades | `/data` survives; the boot hook re-runs. Verify with `test-normal.sh` afterwards |
| Address conflict | Gated at install, and `.2` sits below the default DHCP pool floor |
| Silent bypass of AdGuard | The real risk, and why DNS 2 must never be a public resolver |
| Install-time supply chain | No network fetch. The one third-party artefact needed is vendored at `install/udm-boot.service` |
| Killing the wrong process | Every PID is verified against `/proc/<pid>/cmdline` before it is signalled — asserted in `test-hardening.sh` |
| Trusting an unknown SSH host key | `StrictHostKeyChecking=ask`, not `accept-new` |
| An installer bug reaching the UDM | `install.sh` and `uninstall.sh` are executed end to end by `test-install.sh` against a fake UDM before they are ever pointed at a real one. Previously they were only parsed, which is how an undefined helper shipped on the fresh-install branch |
| Committing to an install just to consult a gate | `--preflight-only` runs every gate and writes nothing. Asserted against the filesystem and the `scp` log, not against the installer's own claim |
| The hard gate stranding its temporary address | Removed by a trap on any exit path, plus a token-scoped watchdog for the SIGKILL case where no trap runs. The manual remediation is printed *before* the bind, so it is on screen if the session dies |
| Not knowing what an uninstall may safely remove | The installer records pre-install state in `/data/.adguard-failover-provenance`; uninstall reads it before deleting anything and reports rather than guesses |
| A vendored artefact drifting from upstream | Pinned by digest in `test-hardening.sh`, offline against a literal. Refreshing it is a deliberate manual act with a recorded commit |
| Running as root on the UDM | Accepted and unavoidable — binding an address and reading `/run` both require it. Mitigated by keeping the daemon's write surface to one `ip addr` call and one log file |
