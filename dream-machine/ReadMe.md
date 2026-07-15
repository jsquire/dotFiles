# Dream Machine

### Overview

Included in this section are artifacts used to configure a UniFi Dream
Machine Special Edition (UDM SE) as the network gateway, focused on DNS
behavior. Specifically, this bundle installs a small failover daemon on the
UDM so that all LAN DNS goes through a local AdGuard Home instance under
normal conditions, and transparently falls back to Quad9
(`9.9.9.9` / `dns.quad9.net`) if — and only if — AdGuard becomes
unreachable. Clients continue using the AdGuard IP throughout; the switch is
invisible to them.

The setup uses only stock UniFi OS components (`iptables`, `bash`, systemd)
plus the community
[`unifi-common`](https://github.com/unifi-utilities/unifi-common) boot-script
framework, which persists across firmware upgrades because everything lives
in `/data`.

For the reasoning behind the design choices, tradeoffs vs. alternative
approaches, and the mechanics of DNAT/conntrack, see
[`docs/how-it-works.md`](./docs/how-it-works.md).

### Structure

* **install/**
  _Installer script run from the workstation. SCPs the daemon to the UDM,
  installs `unifi-common`, and performs the first launch without requiring
  a reboot._

* **scripts/**
  _The daemon (`health-check.sh`), the boot-hook supervisor
  (`boot-hook.sh`), and the configuration template
  (`config.env.example`)._

* **verify/**
  _End-to-end test scripts: normal-path DNS, simulated AdGuard outage /
  failover engagement, and recovery._

* **uninstall/**
  _Reverses the install: stops the daemon, removes files, and flushes any
  lingering iptables rule._

* **docs/**
  _Deep-dive documentation, including the DNAT/conntrack mechanics, the
  debounce state machine, failure modes, and the rationale for choosing
  this approach over the rejected alternatives._

### Prerequisites

* A UDM SE running UniFi OS 4.x or newer.
* An AdGuard Home instance already running on the LAN with a static IP.
* SSH access to the UDM (enable it in UniFi Network → Settings → Control
  Plane → Console). **Before enabling SSH, please read
  [Appendix A: Warranty considerations](#appendix-a-warranty-considerations).**
* A workstation with `bash`, `ssh`, `scp`, and `dig` installed.

### Required companion configuration: UDM system DNS

**Do not point the UDM's own upstream DNS at AdGuard.** This failover system
only protects clients on the LAN. The UDM itself is not protected, and
pointing its own DNS at the AdGuard host will cause a full-network outage
whenever AdGuard is down (see reasoning below).

**Set the UDM's WAN DNS to a public resolver:**

1. UniFi Network → Settings → Internet → click your **Primary (WAN)** connection.
2. In **IPv4 Configuration**, change **Advanced** from **Auto** to **Manual**.
   This unlocks per-field overrides without changing the WAN IP assignment
   from DHCP.
3. **Uncheck** the **DNS Server Auto** checkbox.
4. Set:
   * **Primary DNS:** `9.9.9.9`
   * **Secondary DNS:** `149.112.112.112`
5. Apply Changes.

Clients continue to receive the AdGuard address via DHCP (Settings → Networks
→ (LAN) → DHCP → DNS Server). Only the router itself uses the public resolver.

#### Why this matters

The failover daemon installs an iptables rule in `nat/PREROUTING`, which only
matches traffic **entering** the UDM from an interface (client traffic). The
UDM's own outbound queries traverse `nat/OUTPUT`, which the rule does not
cover. If the UDM's system DNS is set to the AdGuard IP:

* When AdGuard is up: fine.
* When AdGuard dies: the UDM cannot resolve anything for its own use. Cloud
  connectivity, speed tests, firmware checks, and remote management all fail
  even though the DNAT rule is protecting clients correctly.

Pointing the UDM at a public resolver eliminates this dependency without
affecting client filtering.

#### Verifying the change

From any host that can reach the UDM over SSH, trigger a lookup on the UDM
against an uncached name and watch AdGuard's Query Log filtered by client
`192.168.1.1`:

```bash
ssh root@192.168.1.1 "nslookup probe-$(date +%s).example.org"
```

If the query does **not** appear in AdGuard's log for client
`192.168.1.1`, the UDM is correctly using its public upstream and no longer
depends on AdGuard.

### Step-by-step: install

1. **Enable SSH on the UDM.**
   UniFi Network app → Settings → Control Plane → Console → set an SSH
   password. Verify you can log in:
   ```bash
   ssh root@192.168.1.1
   ```

2. **Copy and edit the config file.**
   From this folder:
   ```bash
   cp scripts/config.env.example scripts/config.env
   ${EDITOR:-vi} scripts/config.env
   ```
   At minimum, set `UDM_HOST`, `UDM_SSH_USER`, and `ADGUARD_IP` for your
   environment. Defaults for the probe / debounce / fallback should be
   fine for most setups.

3. **Run the installer.**
   ```bash
   ./install/install.sh
   ```
   The installer will:
   * Verify SSH reachability to the UDM.
   * Install the `unifi-common` boot-script framework on the UDM if not
     already present.
   * Copy `health-check.sh`, `boot-hook.sh`, and `config.env` into `/data/`
     on the UDM.
   * Set executable bits.
   * Launch the boot hook once to start the supervisor and daemon
     immediately (no reboot required).
   * Tail the log to confirm a healthy start.

4. **Configure UniFi DHCP.**
   Open the UniFi Network app:
   * Settings → Networks → your LAN network.
   * Scroll to **DHCP Service Management** → **DNS Server**.
   * Set the DNS server to **your AdGuard IP only** (e.g. `192.168.1.99`).
   * Remove any additional DNS entries (do NOT list Quad9 as a fallback in
     the DHCP list — the DNAT rule handles failover, and having a fallback
     in the DHCP list would let clients bypass AdGuard when it's up).
   * Save. Clients will pick up the new DNS on their next DHCP lease
     renewal, or immediately if you release/renew.

5. **Verify.**
   ```bash
   ./verify/test-normal.sh       # baseline: AdGuard resolves, no failover engaged
   ./verify/test-failover.sh     # simulate outage; DNAT engages; DNS still works
   ./verify/test-recovery.sh     # AdGuard back; DNAT removed
   ```
   Each script prints a PASS/FAIL summary with the evidence it checked.

### Step-by-step: uninstall

```bash
./uninstall/uninstall.sh
```

Stops the supervisor, removes the boot hook and daemon files from the UDM,
and flushes any lingering DNAT rule. The `unifi-common` package is left in
place; the uninstaller prints follow-up instructions if you'd like to
remove it as well.

Don't forget to also revisit UniFi Network → Settings → Networks → LAN →
DHCP → DNS Server and change it back to whatever you want clients to use
directly.

### How it works (summary)

* DHCP hands out only AdGuard's IP as the DNS server.
* A bash daemon on the UDM (`/data/adguard-failover/health-check.sh`) runs
  a `dig` probe against AdGuard every `INTERVAL` seconds.
* After `FAIL_THRESHOLD` consecutive failed probes, the daemon inserts a
  `nat/PREROUTING` DNAT rule redirecting traffic destined for the AdGuard
  IP on port 53 (UDP+TCP) to `9.9.9.9:53`.
* After `RECOVER_THRESHOLD` consecutive successful probes, the rule is
  removed and traffic flows to AdGuard directly again.
* Conntrack un-NATs reply packets, so clients see all responses as coming
  from the AdGuard IP — the switch is invisible to them.
* **Scope:** only client (LAN-originated) DNS traffic is protected. The UDM's
  own outbound DNS goes through `nat/OUTPUT`, which the rule does not cover
  by design. See [Required companion configuration: UDM system DNS](#required-companion-configuration-udm-system-dns).
* A supervisor loop in `/data/on_boot.d/15-adguard-failover.sh` keeps the
  daemon alive across crashes, and `unifi-common`'s `udm-boot.service`
  ensures the boot hook runs after every reboot (including after firmware
  upgrades, because `/data` survives them).

For the full reasoning, rejected alternatives, and failure-mode analysis,
see [`docs/how-it-works.md`](./docs/how-it-works.md).

### Ongoing maintenance

* **Clients:** nothing, ever.
* **Firmware upgrades:** nothing to do; `/data` and the systemd unit
  persist. Rare exception: a major UniFi OS version bump may require
  rerunning the `unifi-common` upstream installer (documented occurrence in
  the project's history).
* **Changing AdGuard IP, fallback resolver, thresholds, etc.:** edit
  `scripts/config.env`, re-run `./install/install.sh`. The installer is
  idempotent and will overwrite the on-UDM config and restart the daemon
  cleanly.

---

### Appendix A: Warranty considerations

The UniFi OS SSH toggle displays this exact warning:

> Enabling SSH will allow command line access to the UniFi Console and is
> intended for advanced users only. **Use of SSH may void your support or
> warranty.**

Everything in this bundle depends on SSH: installing `unifi-common`,
writing scripts under `/data/on_boot.d/`, and adding an `iptables` DNAT
rule. All of these fall under Ubiquiti's "modifications made via SSH"
umbrella.

**Practical risk breakdown:**

| Category | Risk |
| --- | --- |
| Bricking the UDM / firmware corruption | Very Low — only `/data` is touched; no firmware, no `/etc`, no kernel |
| Temporary DNS misbehavior, fully recoverable | Low — worst case is `iptables -t nat -F PREROUTING` + reboot |
| Post-firmware-upgrade daemon downtime | Low — a rare major UniFi OS version bump may require rerunning the `unifi-common` upstream installer |
| Compromising WAN, LAN, or general router function | ~Zero — the iptables rule is scoped to one destination IP + port 53 only |
| Ubiquiti hardware RMA denial | Very Low — no known public case tied to `/data/on_boot.d` modifications |
| Ubiquiti software/support case denial | Medium — documented policy; you may be asked to factory-reset before support engagement for unrelated issues |

**Rejected alternatives that don't need SSH:**

* **Host-local failover on the AdGuard server** (e.g., `dnsdist` in front
  of AdGuard, forwarding to Quad9 on health-check failure). Covers ~90% of
  outage scenarios (container/service crashes, config errors, updates) but
  does NOT cover the AdGuard host itself being down. Zero UDM changes.
* **Above, plus Quad9 as a secondary DNS entry in the UniFi DHCP list.**
  Adds a last-resort host-down safety net, but leaks queries to Quad9
  whenever clients race their configured DNS servers — negligible for
  Windows/macOS/iOS/Linux, but ~30–50% of queries for Android and many IoT
  devices, which then bypass AdGuard's blocking and per-client visibility.
* **HA AdGuard pair.** Real redundancy without touching the UDM, but
  requires standing up and maintaining a second AdGuard instance.

If preserving the "no questions asked" support surface is more important
to you than instant, transparent, per-client-preserving failover, one of
the alternatives above is a better fit than this bundle. If you accept the
risk profile — technical risk very low, support-ticket risk medium — then
proceed.
