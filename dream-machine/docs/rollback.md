# Rollback

Emergency card. No prose, no diagnosis. Read `docs/how-it-works.md` afterwards,
not now.

---

## Stop everything and restore normal DNS

```sh
ssh root@192.168.1.1 "kill \$(cat /run/adguard-failover.pid) 2>/dev/null; ip addr del 192.168.1.2/32 dev br0 2>/dev/null; iptables-save | grep -v dns-failover-test | iptables-restore"
```

Then remove `192.168.1.2` from the DHCP DNS list in the UniFi controller.

---

## Individually, if the above is too blunt

**Order matters.** The daemon re-adds the standby within one interval whenever
it is missing while failover is engaged — that is deliberate, so a firmware
update or UniFi settings write cannot silently strip the fallback mid-outage.
It cannot tell your `ip addr del` apart from theirs. Stop the daemon first.

**1. Stop the daemon**

```sh
ssh root@192.168.1.1 "kill \$(cat /run/adguard-failover.pid)"
```

Its `TERM` handler withdraws the standby on the way out, so this alone is
usually enough.

**2. Withdraw the standby address, if it is somehow still there**

```sh
ssh root@192.168.1.1 "ip addr del 192.168.1.2/32 dev br0"
```

**3. Clear stranded test-induction rules**

```sh
ssh root@192.168.1.1 "iptables-save | grep -v dns-failover-test | iptables-restore; ip6tables-save | grep -v dns-failover-test | ip6tables-restore"
```

---

## Verify it is actually rolled back

```sh
ssh root@192.168.1.1 "ip -4 -o addr show dev br0 | grep 192.168.1.2; iptables-save | grep dns-failover-test"
```

No output means clean.

```sh
dig @192.168.1.99 dns.quad9.net +short
```

Output means AdGuard is serving.

---

## Why this card kills bluntly

Everywhere else, this project verifies a PID against `/proc/<pid>/cmdline`
before signalling it, because a PID file survives reboots while PIDs do not, so
a stale file can name an unrelated process — and this runs as root on a router.

This card deliberately does not. That is a decision, not an oversight:

- You are here because DNS is down and you are typing under pressure. A
  multi-line identity check on an emergency card is a command people get wrong,
  or skip.
- The window is small. You are reading a PID file and signalling it seconds
  later, on a router that reboots rarely.
- `kill` without `-9` sends `TERM`, which the daemon handles cleanly and most
  unrelated processes survive or exit gracefully.

If you are not under pressure, use the verified path instead — it checks
identity before signalling anything:

```sh
./uninstall/uninstall.sh
```

---

## Permanent removal

```sh
./uninstall/uninstall.sh
```

This removes everything the project wrote and **verifies** the standby address
is actually gone rather than assuming `ip addr del` worked. It then reports
whether `udm-boot.service` existed before the project was installed, so you can
decide about it with the facts rather than a guess.

What it deliberately leaves for you: the DHCP DNS entry in the UniFi
controller, and `udm-boot.service` itself.

Then remove `192.168.1.2` from the DHCP DNS list.
