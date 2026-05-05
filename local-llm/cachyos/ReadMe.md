# Self-Hosted AI Coding Assistant — CachyOS Server Setup

A dedicated CachyOS (Arch-based Linux) host for running **Ollama** as an always-on LAN inference endpoint, with **Crush** as the terminal agent, **uv** for Python tooling, and isolated MCP server environments under `~/.local/share/ai-tools`.

This is the Linux counterpart to the Windows setup in `windows\`. Use it when you want one GPU-heavy machine to serve models for the rest of your workstation fleet.

---

## Overview

The CachyOS server fills the **Scenario B** role:

- **Always-on Ollama** for desktop and laptop clients
- **Dedicated NVIDIA GPU VRAM** with no IDE / desktop contention
- **Systemd-managed service** that comes up automatically on boot
- **User-local tooling** for Crush, uv, and MCP environments
- **Clean layering** so system packages, user tools, isolated venvs, and config stay separable

### Installation Modes

| Mode | Command | What it does |
|------|---------|--------------|
| **Full** _(default)_ | `./install-cachyos.sh` | Installs the complete stack locally: NVIDIA drivers + CUDA, Ollama (localhost only), systemd override, uv, Python 3.12, Crush, MCP directories, and model pulls. |
| **Server** | `./install-cachyos.sh --mode server` | Everything in Full, plus binds Ollama to `0.0.0.0`, configures ufw firewall rules for LAN access, and prints client connection instructions. |
| **Client** | `./install-cachyos.sh --mode client --ollama-host http://server:11434` | Installs only the client-side tooling: uv, Python 3.12, Crush, and MCP directories. No GPU requirement, no Ollama install, no model storage. |

> Use **Server** on the dedicated LAN inference machine.  Use **Full** if you want local-only Ollama with no LAN exposure.  Use **Client** on machines that talk to a remote Ollama endpoint.

---

## Prerequisites

### Full Mode

- **CachyOS minimal/server install** (systemd + pacman expected)
- **NVIDIA GPU** visible in `lspci`
- **Internet access** for package downloads and model pulls
- **~40-50 GB free disk space** for model storage
- **sudo or root access**

### Server Mode

All Full mode prerequisites, plus:
- **LAN connectivity** so remote clients can reach port 11434
- **ufw installed** (recommended — the script configures LAN-only rules)

### Client Mode

- CachyOS / Arch-based system
- Reachable Ollama server such as `http://192.168.1.50:11434`
- Internet access for installing uv and Crush
- No GPU required
- No model storage required

---

## Quick Start

### Full Install (local only)

```bash
cd ~/dotFiles/local-llm/cachyos
chmod +x install-cachyos.sh remove-cachyos.sh

# Default full install (Standard profile, localhost only)
./install-cachyos.sh

# Higher-quality primary model for 32 GB GPUs
./install-cachyos.sh --model-profile high

# Store models on another filesystem
./install-cachyos.sh --model-path /srv/ollama-models

# Install software now, pull models later
./install-cachyos.sh --skip-models

# Resume / add model downloads later
./install-cachyos.sh --models-only
```

### Server Install (LAN-accessible)

```bash
# Full stack + LAN firewall + prints client connection info
./install-cachyos.sh --mode server

# Server with High profile models
./install-cachyos.sh --mode server --model-profile high
```

### Client Install

```bash
cd ~/dotFiles/local-llm/cachyos
chmod +x install-cachyos.sh

./install-cachyos.sh --mode client --ollama-host http://192.168.1.50:11434
```

### Removal

```bash
# Remove the full server stack
./remove-cachyos.sh

# Keep downloaded models for a future reinstall
./remove-cachyos.sh --keep-models

# Remove only client-side tooling
./remove-cachyos.sh --mode client

# Non-interactive removal
./remove-cachyos.sh --force
```

---

## What Gets Installed Where

The scripts follow the same 4-layer architecture as the Windows setup, adapted for Linux.

### Layer Diagram

```text
Layer 1 — System
  /usr/local/bin/ollama
  /etc/systemd/system/ollama.service.d/override.conf
  pacman packages: nvidia-dkms, nvidia-utils, cuda

Layer 2 — User-local
  ~/.local/bin/uv
  ~/.local/bin/uvx
  ~/.local/bin/crush

Layer 3 — Isolated
  ~/.local/share/uv/
  ~/.local/share/ai-tools/mcp-office/
  ~/.local/share/ai-tools/mcp-word/
  ~/.local/share/ai-tools/mcp-pptx/
  uv-managed Python 3.12 environments

Layer 4 — Config
  ~/.ollama/
  ~/.crush/
  ~/.config/crush/
```

### Installed Components

| Component | Install Method | Scope | Purpose |
|-----------|----------------|-------|---------|
| **NVIDIA drivers + CUDA** | `pacman` | System | GPU acceleration for Ollama |
| **Ollama** | Official install script | System | Model server |
| **Ollama service override** | systemd drop-in | System | Sets `OLLAMA_HOST`, `OLLAMA_KEEP_ALIVE`, optional `OLLAMA_MODELS` |
| **uv** | Official install script | User-local | Python toolchain manager |
| **Python 3.12** | `uv python install 3.12` | uv-managed | Python runtime for MCP servers |
| **Crush** | pacman or user-local installer | User-local | CLI agent |
| **MCP directories** | `mkdir -p` | User-local / isolated | Future MCP venv locations |

---

## Model Profiles

The `--model-profile` switch controls the primary 30B Qwen quantization in **Full** mode.

| Profile | Primary Model | Quant | Approx. Download | Best for |
|---------|---------------|-------|------------------|----------|
| **Standard** _(default)_ | `qwen3:30b` | Q4_K_M ~18 GB | ~38 GB total | 24 GB GPU, best balance |
| **High** | `qwen3:30b-q5_K_M` | Q5_K_M ~21 GB | ~41 GB total | 32 GB GPU, slightly better quality |
| **Ultra** | `qwen3:30b-q6_K` | Q6_K ~24 GB | ~44 GB total | 32 GB GPU, max local quality |

All built-in profiles also pull:

- `qwen3:8b` — fast tasks
- `deepseek-r1:14b` — hard reasoning
- `llama3.1:8b` — general/sysadmin

### Custom Model List Override

If `config/ollama-models.txt` exists relative to the repo root, the installer uses that file **instead of** the built-in profile list.

Path resolved by the script:

```text
$SCRIPT_DIR/../config/ollama-models.txt
```

Format:

```text
# One model per line
qwen3:30b
qwen3:8b
# comments and blank lines are ignored
```

Inline comments are allowed, so this also works:

```text
qwen3:30b           # Primary coder
qwen3:8b            # Fast tasks
```

---

## Full Mode Walkthrough

The installer performs these steps:

1. **Pre-flight checks**
   - verifies `pacman`
   - checks for sudo/root access
   - verifies an NVIDIA GPU via `lspci | grep -i nvidia`
2. **Install NVIDIA drivers**
   - `sudo pacman -S --needed nvidia-dkms nvidia-utils cuda`
3. **Install Ollama**
   - `curl -fsSL https://ollama.com/install.sh | sh`
4. **Configure systemd override**
   - writes `/etc/systemd/system/ollama.service.d/override.conf`
   - sets `OLLAMA_HOST`
   - sets `OLLAMA_KEEP_ALIVE=5m`
   - optionally sets `OLLAMA_MODELS`
5. **Firewall** _(server mode only)_
   - if `ufw` is installed, allows `192.168.0.0/16` to port `11434` and denies other access
   - in full mode, Ollama binds to `127.0.0.1` — no firewall changes needed
6. **Install uv**
   - `curl -LsSf https://astral.sh/uv/install.sh | sh`
7. **Install Python 3.12**
   - `uv python install 3.12`
8. **Install Crush**
   - pacman if available, otherwise user-local installer / release fallback
9. **Create MCP directories**
   - `~/.local/share/ai-tools/mcp-{office,word,pptx}`
10. **Pull models**
    - waits for the Ollama API, then runs `ollama pull` for each selected tag

### Server Mode Walkthrough

Server mode runs the same steps as full mode, with two additions:

1. **Ollama binds to `0.0.0.0`** instead of `127.0.0.1` — accessible from the LAN
2. **Firewall rules** — if `ufw` is installed, allows `192.168.0.0/16` → `11434/tcp` and denies external access
3. **Client connection instructions** — at the end, prints the server's LAN IP and exact commands to run on Windows and CachyOS clients

### Client Mode Walkthrough

Client mode skips:

- NVIDIA drivers
- Ollama install
- systemd service changes
- firewall rules
- model pulls

It installs only:

- uv
- Python 3.12
- Crush
- MCP directories

You must supply:

```bash
./install-cachyos.sh --mode client --ollama-host http://server:11434
```

---

## Systemd Service Management

The server install configures Ollama as a systemd service and adds a drop-in override.

### Common Commands

```bash
sudo systemctl start ollama
sudo systemctl stop ollama
sudo systemctl restart ollama
sudo systemctl status ollama
```

### View Logs

```bash
journalctl -u ollama -n 100 --no-pager
journalctl -u ollama -f
```

### Override Location

```text
/etc/systemd/system/ollama.service.d/override.conf
```

Typical contents:

```ini
[Service]
Environment="OLLAMA_HOST=127.0.0.1"
Environment="OLLAMA_KEEP_ALIVE=5m"
# Optional:
# Environment="OLLAMA_MODELS=/srv/ollama-models"
```

If you used `--mode server`, the host becomes `0.0.0.0` instead.

---

## Firewall Notes

In **server** mode, if `ufw` is installed, the script configures Ollama to be LAN-accessible:

- allow `192.168.0.0/16` to TCP `11434`
- deny other access to TCP `11434`

In **full** mode, the service binds to `127.0.0.1`, so remote clients cannot connect even if the firewall is permissive. No firewall rules are added.

Check rules with:

```bash
sudo ufw status numbered
```

> **Important:** Ollama's API is unauthenticated by default. Server mode restricts access to the LAN subnet. Do not expose port `11434` to the public internet.

---

## How to Test

Open a new shell after install, then verify each layer.

### Full Mode Verification

#### 1. Check the service

```bash
sudo systemctl status ollama
```

#### 2. Check the API

```bash
curl http://127.0.0.1:11434/api/tags
```

If server mode was used, also test from another machine:

```bash
curl http://server-ip:11434/api/tags
```

#### 3. List models

```bash
ollama list
```

#### 4. Run a quick inference test

```bash
ollama run qwen3:8b "What is the capital of France? Reply in one sentence."
```

#### 5. Verify GPU usage

```bash
nvidia-smi
```

You should see Ollama using VRAM after a model loads.

### Client Mode Verification

#### 1. Verify remote Ollama reachability

```bash
curl http://your-server:11434/api/tags
```

#### 2. Verify uv and Python

```bash
uv --version
uv python list
```

#### 3. Launch Crush

```bash
crush
```

On first launch, point Crush to the remote Ollama endpoint.

---

## Model Switching

Switch models inside Crush with `/model <tag>`, or test directly via Ollama.

### Suggested Usage

| Task Type | Model | Command |
|-----------|-------|---------|
| Complex coding | `qwen3:30b`, `qwen3:30b-q5_K_M`, or `qwen3:30b-q6_K` | `/model <tag>` |
| Quick tasks | `qwen3:8b` | `/model qwen3:8b` |
| Hard reasoning | `deepseek-r1:14b` | `/model deepseek-r1:14b` |
| Sysadmin / general | `llama3.1:8b` | `/model llama3.1:8b` |

### Pull Another Model Later

```bash
ollama pull qwen3:30b-q5_K_M
ollama pull llama3.1:8b
```

### Re-run the Script for Models Only

```bash
./install-cachyos.sh --models-only --model-profile high
```

If `config/ollama-models.txt` exists, it overrides the profile again.

---

## Client Mode Details

Client mode is for non-server CachyOS systems that should reuse the dedicated Ollama box.

### What Client Mode Installs

- `~/.local/bin/uv`
- `~/.local/bin/uvx`
- uv-managed Python 3.12
- `~/.local/bin/crush`
- `~/.local/share/ai-tools/mcp-*`
- `~/.crush`
- `~/.config/crush`

### What Client Mode Does **Not** Install

- NVIDIA drivers
- CUDA
- Ollama
- local models
- systemd service changes
- firewall rules

### Typical Flow

1. Install the full stack on the server with `--mode server`
2. Note the client connection URL printed at the end
3. On the client machine, run:
   ```bash
   ./install-cachyos.sh --mode client --ollama-host http://server-ip:11434
   ```
4. Configure Crush to use the remote Ollama endpoint

---

## Removal Options

### Full / Server Removal

```bash
./remove-cachyos.sh                    # or --mode server (same behavior)
./remove-cachyos.sh --keep-models
./remove-cachyos.sh --keep-config
./remove-cachyos.sh --force
```

Full and server removal are identical — both remove the complete stack including firewall rules.

### Client Removal

```bash
./remove-cachyos.sh --mode client
./remove-cachyos.sh --mode client --keep-config
./remove-cachyos.sh --mode client --force
```

### What Gets Removed — Full Mode

| Component | Location |
|-----------|----------|
| Ollama binary | `/usr/local/bin/ollama` |
| Ollama service + override | `/etc/systemd/system/ollama.service*` |
| Ollama data | `~/.ollama/` |
| Firewall rules | ufw rules for port 11434 |
| Crush | `~/.local/bin/crush` or pacman package |
| uv / uvx | `~/.local/bin/uv`, `~/.local/bin/uvx` |
| uv data | `~/.local/share/uv/` |
| MCP dirs | `~/.local/share/ai-tools/` |
| Crush config | `~/.crush/`, `~/.config/crush/` |

### What Gets Removed — Client Mode

| Component | Location |
|-----------|----------|
| Crush | `~/.local/bin/crush` |
| uv / uvx | `~/.local/bin/uv`, `~/.local/bin/uvx` |
| uv data | `~/.local/share/uv/` |
| MCP dirs | `~/.local/share/ai-tools/` |
| Crush config | `~/.crush/`, `~/.config/crush/` |

Client mode removal preserves all Ollama-related system configuration and model storage.

---

## Troubleshooting

### Ollama service will not start

```bash
sudo systemctl status ollama
journalctl -u ollama -n 100 --no-pager
nvidia-smi
```

Things to check:

- NVIDIA driver installed correctly
- `cuda` package present
- service override syntax in `/etc/systemd/system/ollama.service.d/override.conf`
- custom `OLLAMA_MODELS` path exists and is writable

### `curl http://127.0.0.1:11434/api/tags` fails

```bash
sudo systemctl restart ollama
journalctl -u ollama -f
```

If you are only resuming downloads, re-run:

```bash
./install-cachyos.sh --models-only
```

### Remote clients cannot connect

Check all of the following:

```bash
sudo systemctl status ollama
sudo ufw status numbered
curl http://127.0.0.1:11434/api/tags
```

Common causes:

- server was installed with `--mode full` instead of `--mode server`
- firewall rule missing for `11434/tcp`
- wrong server IP or hostname on the client
- client and server are not on the same routed network

### `uv` or `crush` not found after install

The installers place binaries in `~/.local/bin`. Ensure that directory is on `PATH`:

```bash
echo "$PATH"
```

If needed, add this to your shell profile:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Then start a new shell.

### Out of VRAM or slow model loads

```bash
nvidia-smi
ollama list
```

Mitigations:

- use `standard` profile instead of `high` / `ultra`
- switch to `qwen3:8b` for lighter tasks
- move to a custom `config/ollama-models.txt`
- stop unused sessions so `OLLAMA_KEEP_ALIVE=5m` can unload models

---

## Suggested Operating Pattern

- Run **Server mode** on the CachyOS inference box
- Run **Client mode** on desktop / laptop endpoints
- Run **Full mode** if you want local Ollama with no LAN exposure
- Use `qwen3:30b` or its higher quants for main coding
- Switch to `qwen3:8b` for fast tasks
- Keep `deepseek-r1:14b` available for architecture/debugging spikes

That gives you a dedicated, always-on local inference endpoint with the same architecture as the Windows setup, but optimized for a Linux server role.
