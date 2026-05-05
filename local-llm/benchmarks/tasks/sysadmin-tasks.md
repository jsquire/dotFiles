## Task: Windows Service Troubleshooting

**Category:** sysadmin  
**Difficulty:** medium  
**Expected time:** 60s

### Prompt

> A Windows service called "OllamaService" fails to start after a reboot.  The event log shows "The service did not respond to the start or control request in a timely fashion."  What are the most likely causes and how would you diagnose and fix each one?

### Expected Outcome

Covers: timeout value, dependency services, path/permissions, resource exhaustion.  Provides specific commands (`sc qc`, `Get-WinEvent`, registry timeout key).

### Scoring

- **Pass:** 3+ causes with specific diagnostic commands and fixes
- **Partial:** Correct causes but vague on commands
- **Fail:** Fewer than 2 causes or incorrect advice

---

## Task: Linux Firewall Configuration

**Category:** sysadmin  
**Difficulty:** medium  
**Expected time:** 90s

### Prompt

> Write a bash script for CachyOS (Arch-based) that configures `iptables` to:
> 1. Allow SSH (22), HTTP (80), HTTPS (443) from any source
> 2. Allow Ollama API (11434) only from 192.168.1.0/24
> 3. Allow Samba (137-139, 445) only from 192.168.1.0/24
> 4. Allow established/related connections
> 5. Drop everything else
> 6. Persist rules across reboots using iptables-save

### Expected Outcome

Correct rule ordering (established first, then allows, then drop), proper subnet restriction, persistence via `iptables-save > /etc/iptables/iptables.rules` and systemd enable.

### Scoring

- **Pass:** All rules correct, order is right, persistence works
- **Partial:** Rules correct but order wrong or persistence missing
- **Fail:** Incorrect rules or locks out SSH

---

## Task: Docker Compose Migration

**Category:** sysadmin  
**Difficulty:** hard  
**Expected time:** 120s

### Prompt

> Convert this docker-compose.yml from Compose v2 syntax to v3.8, add healthchecks to each service, and add an Ollama service that uses the NVIDIA runtime with a volume for model storage:
> ```yaml
> version: "2"
> services:
>   pihole:
>     image: pihole/pihole:latest
>     ports: ["53:53/tcp", "53:53/udp", "80:80"]
>     volumes: ["./pihole:/etc/pihole"]
>     restart: always
>   cloudflared:
>     image: cloudflare/cloudflared:latest
>     command: proxy-dns
>     restart: always
> ```

### Expected Outcome

Valid v3.8 syntax, healthchecks using appropriate commands for each service, Ollama service with `runtime: nvidia`, `NVIDIA_VISIBLE_DEVICES=all`, named volume for `~/.ollama`.

### Scoring

- **Pass:** Valid compose, all healthchecks work, Ollama GPU config correct
- **Partial:** Syntax valid but healthchecks weak or missing GPU config
- **Fail:** Invalid YAML or missing services

---

## Task: PowerShell Remote Automation

**Category:** sysadmin  
**Difficulty:** medium  
**Expected time:** 90s

### Prompt

> Write a PowerShell script that connects to a list of Windows machines (from a text file), checks if Windows Update service is running, checks available disk space on C:, and outputs a summary table.  Handle machines that are offline gracefully.

### Expected Outcome

Uses `Invoke-Command` or `Test-Connection` + `Get-Service` + `Get-PSDrive`, error handling for unreachable hosts, clean table output.

### Scoring

- **Pass:** Works end-to-end, handles offline hosts, clean output
- **Partial:** Logic correct but poor error handling
- **Fail:** Does not handle remote execution correctly
