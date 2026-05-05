# Self-Hosted AI Coding Assistant — Windows Setup

A local AI coding assistant comparable to Claude Code / Copilot CLI.  Uses **Ollama** for model serving and **Crush** (formerly OpenCode) as the CLI agent, with MCP integration for Office document creation.

## Installation Modes

The install script supports two modes, selected with the `-Mode` parameter:

| Mode | Command | What it does |
|------|---------|-------------|
| **Full** _(default)_ | `.\install-windows.ps1` | Installs the complete stack: Ollama (local inference) + Crush (CLI agent) + uv/Python + MCP directories + downloads models.  Requires an NVIDIA GPU. |
| **Client** | `.\install-windows.ps1 -Mode Client -OllamaHost http://server:11434` | Installs only the client: Crush + uv/Python + MCP directories.  Points to a remote Ollama server for inference.  No GPU required, no admin privileges, no model storage. |

> **When to use which:** Use **Full** when this machine has a GPU and will run inference locally (Scenario A).  Use **Client** when a dedicated server handles inference and this machine is just the terminal (Scenario B, or a laptop).

---

## What Gets Installed

### Full Mode (client + local LLM)

| Component | Install Method | Scope | Purpose |
|-----------|---------------|-------|---------|
| **Ollama** | `winget --interactive` | System (service) | Model server — serves LLMs with GPU acceleration |
| **Crush** | `winget` (portable) | User-local (winget managed) | CLI agent — terminal AI assistant with MCP support |
| **uv** | `winget` (portable) | User-local (winget managed) | Python toolchain manager (no system Python) |
| **Python 3.12** | `uv python install` | uv-managed (isolated) | Required for MCP servers |

#### Models Pulled (full mode)

The `-ModelProfile` parameter selects which quantization level to use for the primary 27B model.  Smaller models use their default quantization across all profiles.

| Profile | Primary 27B | Quant | Download | Best for |
|---------|-------------|-------|----------|----------|
| **Standard** _(default)_ | `qwen3:30b` | Q4_K_M ~18 GB | ~38 GB total | 24 GB GPU (RTX 4090) with IDEs open |
| **High** | `qwen3:30b-q5_K_M` | Q5_K_M ~21 GB | ~41 GB total | 32 GB GPU (RTX 5090) with IDEs open |
| **Ultra** | `qwen3:30b-q6_K` | Q6_K ~24 GB | ~44 GB total | 32 GB GPU (RTX 5090), IDEs closed, max quality |

All profiles also pull these smaller models:

| Model | Size | Role |
|-------|------|------|
| `qwen3:8b` | ~5 GB | Fast tasks — commit messages, quick questions |
| `deepseek-r1:14b` | ~9 GB | Hard reasoning — complex debugging, architecture |
| `llama3.1:8b` | ~5 GB | General-purpose / sysadmin tasks |

> Each pull is resumable if interrupted.  Multiple quantizations of the same model coexist — you can `ollama pull` additional variants manually at any time.

#### Custom Model List

For full control, create `config/ollama-models.txt` next to the script.  If present, this file overrides the built-in profile entirely.  Format: one Ollama tag per line, comments with `#`.

```
# config/ollama-models.txt
qwen3:30b-q5_K_M     # Primary coder — Q5 for 32 GB GPU
qwen3:30b            # Also keep Q4 as a fallback when IDEs are open
qwen3:8b             # Fast tasks
deepseek-r1:14b      # Reasoning
llama3.1:8b          # General
```

### Client Mode (remote inference)

| Component | Install Method | Scope | Purpose |
|-----------|---------------|-------|---------|
| **Crush** | `winget` (portable) | User-local (winget managed) | CLI agent — terminal AI assistant with MCP support |
| **uv** | `winget` (portable) | User-local (winget managed) | Python toolchain manager (no system Python) |
| **Python 3.12** | `uv python install` | uv-managed (isolated) | Required for MCP servers |

> No Ollama, no model downloads, no GPU required.  Crush connects to a remote Ollama server.

### Directory Layout

```
Full mode:                              Client mode:
%LOCALAPPDATA%\                         %LOCALAPPDATA%\
├── Microsoft\WinGet\                   ├── Microsoft\WinGet\
│   ├── Packages\  (crush, uv)          │   ├── Packages\  (crush, uv)
│   └── Links\     (symlinks)           │   └── Links\     (symlinks)
├── uv\            (Python + cache)     ├── uv\            (Python + cache)
└── ai-tools\      (MCP venvs)          └── ai-tools\      (MCP venvs)

%USERPROFILE%\                          %USERPROFILE%\
├── .ollama\models\  (~38+ GB)          └── .crush\
└── .crush\                                 ├── crush.json  → remote endpoint
    ├── crush.json   → localhost            └── mcp-servers.json
    └── mcp-servers.json
```

---

## Prerequisites

### Full Mode
- **Windows 10/11** with [App Installer](https://apps.microsoft.com/detail/9nblggh4nns1) (provides `winget`)
- **NVIDIA GPU** with recent drivers (RTX 4090 recommended; any CUDA 6.0+ GPU works)
- **~40-50 GB free disk space** on C: for models (Standard profile; High needs ~45 GB, Ultra needs ~50 GB)
- **Internet connection** for initial downloads

### Client Mode
- **Windows 10/11** with [App Installer](https://apps.microsoft.com/detail/9nblggh4nns1) (provides `winget`)
- **Reachable Ollama server** on your LAN (e.g., `http://192.168.1.x:11434`)
- **~1 GB free disk space** (no model storage)
- **Internet connection** for initial downloads
- No GPU required.  No admin privileges required.

---

## Installation

### Full Mode — Quick Start

```powershell
# Full install with default models (Standard profile — Q4_K_M 27B)
.\install-windows.ps1

# Higher quantization for 32 GB GPUs (Q5_K_M 27B)
.\install-windows.ps1 -ModelProfile High

# Maximum quality for 32 GB GPUs with IDEs closed (Q6_K 27B)
.\install-windows.ps1 -ModelProfile Ultra

# Install software only, pull models later
.\install-windows.ps1 -SkipModels

# Resume/add model downloads (uses the profile from initial install)
.\install-windows.ps1 -ModelsOnly

# Enable LAN access (allow laptop/other machines to use this Ollama)
.\install-windows.ps1 -EnableLAN
```

### Client Mode — Quick Start

```powershell
# Install client pointing to your Ollama server
.\install-windows.ps1 -Mode Client -OllamaHost http://192.168.1.100:11434

# If your server uses a non-standard port
.\install-windows.ps1 -Mode Client -OllamaHost http://myserver:11434
```

### What to Expect — Full Mode

The script runs 7-8 steps.  Most complete in seconds; model pulls take 10-60+ minutes depending on your connection.

| Step | What Happens | Duration | Interactive? |
|------|-------------|----------|-------------|
| 1. Install uv | Downloads uv via winget (portable zip) | ~30 seconds | No |
| 2. Install Python 3.12 | uv downloads and manages Python | ~1 minute | No |
| 3. Install Ollama | winget + installer wizard opens | ~2 minutes | **Yes** — set install location |
| 4. Configure Ollama | Sets OLLAMA_HOST and OLLAMA_KEEP_ALIVE env vars | Instant | No |
| 5. Install Crush | Downloads Crush via winget (portable zip) | ~30 seconds | No |
| 6. Create MCP dirs | Creates empty directories for future MCP venvs | Instant | No |
| 7. Pull models | Downloads ~38-44 GB of model files (varies by profile) | **10-60+ min** | No |

#### Interactive Installers

Step 3 (Ollama) opens an installer GUI because of the `--interactive` flag.  This lets you choose the install directory and review what's being installed.  The defaults are fine for most users.

Crush and uv are portable zip packages — winget extracts them automatically with no installer GUI.

#### After the Script Completes

1. **Restart your terminal** — PATH changes require a new session
2. **Restart Ollama** — right-click the Ollama icon in the system tray → Quit, then relaunch.  This picks up the new `OLLAMA_HOST` and `OLLAMA_KEEP_ALIVE` environment variables.

### What to Expect — Client Mode

The script runs 4-5 steps.  All complete in under 2 minutes.  No model downloads, no interactive installers.

| Step | What Happens | Duration | Interactive? |
|------|-------------|----------|-------------|
| 1. Install uv | Downloads uv via winget (portable zip) | ~30 seconds | No |
| 2. Install Python 3.12 | uv downloads and manages Python | ~1 minute | No |
| 3. Install Crush | Downloads Crush via winget (portable zip) | ~30 seconds | No |
| 4. Create MCP dirs | Creates empty directories for future MCP venvs | Instant | No |
| 5. Configure Crush | Points Crush at remote Ollama endpoint | Instant | No |

#### After the Script Completes

1. **Restart your terminal** — PATH changes require a new session
2. **Verify the remote server is reachable:** `curl http://your-server:11434/api/tags`

---

## How to Test

After installation, verify each component works.  Run these in a **new terminal**.

### Full Mode Verification

#### 1. Verify Ollama is running

```powershell
# Should show the list of pulled models
ollama list
```

Expected output:
```
NAME                 ID           SIZE     MODIFIED
qwen3:30b            abc123...    18 GB    2 minutes ago
qwen3:8b             def456...    4.9 GB   5 minutes ago
deepseek-r1:14b      ghi789...    9.0 GB   8 minutes ago
llama3.1:8b          jkl012...    4.9 GB   10 minutes ago
```

#### 2. Test model inference

```powershell
# Quick test with the smallest model (fastest response)
ollama run qwen3:8b "What is the capital of France? Reply in one sentence."
```

You should see a response within 2-5 seconds.  The first run loads the model into VRAM (may take 5-10 seconds extra).

#### 3. Test the primary model

```powershell
# Test the 27B model (takes longer to load, higher quality)
ollama run qwen3:30b "Write a Python function that reverses a linked list. Include type hints."
```

#### 4. Test the Ollama API

```powershell
# The API should be accessible on localhost
curl http://localhost:11434/api/tags
```

#### 5. Test VRAM usage alongside development tools

```powershell
# With your IDEs open, check GPU memory
nvidia-smi
```

Look at the "Memory-Usage" column.  With dual IDEs + browser:
- ~5-6.5 GB used → ~17.5-19 GB available for AI
- The Q3_K_M 27B model (~15-17.5 GB) should fit
- The Q4_K_M 27B model (~18-20 GB) may need an IDE closed

### Client Mode Verification

#### 1. Verify remote Ollama is reachable

```powershell
# Replace with your server's address
curl http://your-server:11434/api/tags
```

You should see a JSON response listing the models available on the server.

#### 2. Verify uv and Python

```powershell
uv --version
uv python list
```

### Both Modes

#### Verify Crush

```powershell
# Launch Crush — should open the interactive TUI
crush
```

On first launch, Crush will ask you to configure a provider.  Point it to your Ollama endpoint:
- **Provider:** Ollama (or OpenAI-compatible)
- **Endpoint:** `http://localhost:11434` _(full mode)_ or `http://your-server:11434` _(client mode)_
- **Model:** `qwen3:30b`

#### Verify uv and Python

```powershell
# Check uv is available
uv --version

# Check managed Python
uv python list
```

---

## How to Get Started

### Your First Conversation

1. **Launch Crush:**
   ```powershell
   crush
   ```

2. **Configure the provider** (first launch only):
   - Select Ollama as the provider
   - Endpoint: `http://localhost:11434` _(full mode)_ or `http://your-server:11434` _(client mode)_
   - Model: your primary 27B tag — `qwen3:30b` _(Standard)_, `qwen3:30b-q5_K_M` _(High)_, or `qwen3:30b-q6_K` _(Ultra)_

3. **Try a coding task:**
   ```
   > Write a PowerShell function that finds duplicate files in a directory by hash.
     Include error handling and progress output.
   ```

4. **Try a reasoning task** (switch models):
   ```
   > /model deepseek-r1:14b
   > I have a race condition in my async code. Here's the relevant section: [paste code]
     What's causing the issue and how do I fix it?
   ```

5. **Try a quick task** (switch to fast model):
   ```
   > /model qwen3:8b
   > Write a git commit message for these changes: [paste diff]
   ```

### Model Switching Guide

| Task Type | Standard Profile | High/Ultra Profile | Switch Command |
|-----------|-----------------|-------------------|---------------|
| Complex coding, multi-file edits | `qwen3:30b` | `qwen3:30b-q5_K_M` or `qwen3:30b-q6_K` | `/model <tag>` |
| Quick questions, commit messages | `qwen3:8b` | `qwen3:8b` | `/model qwen3:8b` |
| Hard debugging, architecture review | `deepseek-r1:14b` | `deepseek-r1:14b` | `/model deepseek-r1:14b` |
| Sysadmin, general knowledge | `llama3.1:8b` | `llama3.1:8b` | `/model llama3.1:8b` |

> **Note:** Only one model loads into VRAM at a time.  Switching takes ~5-15 seconds while the new model loads and the old one unloads (after the 5-minute `OLLAMA_KEEP_ALIVE` timeout, or immediately if VRAM is needed).
>
> **Client mode:** Model switching works the same way — the commands are identical.  Models load/unload on the remote server.
>
> **Multiple quantizations:** If you pulled both Q4 and Q5 variants (e.g., via custom models file), you can switch between them mid-session with `/model qwen3:30b` or `/model qwen3:30b-q5_K_M`.

### VRAM Management Tips (Full Mode Only)

These tips apply when Ollama is running locally and sharing GPU memory with other applications.

- **Check VRAM:** `nvidia-smi` shows current GPU memory usage
- **Unload model immediately:** `curl -X DELETE http://localhost:11434/api/generate -d '{"model":"qwen3:30b"}'` (frees VRAM without waiting for timeout)
- **Profile-aware VRAM budgets:**
  - Standard (Q4_K_M ~18 GB): fits alongside dual IDEs on 24 GB GPUs
  - High (Q5_K_M ~21 GB): fits alongside dual IDEs on 32 GB GPUs, ~5% quality improvement
  - Ultra (Q6_K ~24 GB): needs IDEs closed on 32 GB GPUs, best local quality
- **Keep conversations short:** KV cache grows with context length.  At 27B: 8K tokens → ~1.5 GB, 16K → ~3 GB.  Start new conversations rather than letting them grow past ~12K tokens.

> **Client mode users:** VRAM management happens on the server.  You don't need to worry about local GPU memory.

### Configuration Files

After first launch, Crush creates its config at `%USERPROFILE%\.crush\`:

- **`crush.json`** — Provider settings, model aliases, keybindings
- **`mcp-servers.json`** — MCP server definitions (populated in Phase 2)

Edit these directly or use Crush's built-in configuration commands.

---

## Removal

### Full Mode — Quick Removal

```powershell
# Interactive removal with confirmations
.\remove-windows.ps1

# Keep models (reinstall faster later)
.\remove-windows.ps1 -KeepModels

# Keep Crush config files (preserve settings)
.\remove-windows.ps1 -KeepConfig

# Non-interactive full removal
.\remove-windows.ps1 -Force
```

### Client Mode — Quick Removal

```powershell
# Remove client components (no Ollama/models to remove)
.\remove-windows.ps1 -Mode Client

# Keep Crush config files (preserve settings)
.\remove-windows.ps1 -Mode Client -KeepConfig

# Non-interactive client removal
.\remove-windows.ps1 -Mode Client -Force
```

### What Gets Removed — Full Mode

| Component | Location | Size |
|-----------|----------|------|
| Ollama (service) | System (via winget) | ~200 MB |
| Ollama models + config | `%USERPROFILE%\.ollama\` | **38+ GB** |
| Crush (portable) | winget managed | ~30 MB |
| Crush config | `%USERPROFILE%\.crush\` | ~1 MB |
| MCP server venvs | `%LOCALAPPDATA%\ai-tools\` | ~100-500 MB |
| uv (portable) + managed Python | winget managed + `%LOCALAPPDATA%\uv\` | ~200-500 MB |
| Environment vars | `OLLAMA_HOST`, `OLLAMA_KEEP_ALIVE` | — |

### What Gets Removed — Client Mode

| Component | Location | Size |
|-----------|----------|------|
| Crush (portable) | winget managed | ~30 MB |
| Crush config | `%USERPROFILE%\.crush\` | ~1 MB |
| MCP server venvs | `%LOCALAPPDATA%\ai-tools\` | ~100-500 MB |
| uv (portable) + managed Python | winget managed + `%LOCALAPPDATA%\uv\` | ~200-500 MB |

> No Ollama, no models, no environment variables to clean up.

### Transitioning: Full → Client

When moving from local inference to a remote server (e.g., Scenario A → Scenario B):

```powershell
# 1. Remove full installation (including Ollama and models)
.\remove-windows.ps1 -Force

# 2. Reinstall as client pointing to the new server
.\install-windows.ps1 -Mode Client -OllamaHost http://server-ip:11434
```

### Manual Credential Cleanup

If you stored API keys in Windows Credential Manager (e.g., for OpenRouter cloud fallback):

1. Open **Control Panel → Credential Manager → Windows Credentials**
2. Look for entries related to: `openrouter`, `ollama`, `crush`, `ai-assistant`
3. Remove any that are no longer needed

---

## Troubleshooting

### Full Mode Issues

#### Ollama won't start / models won't load

```powershell
# Check if Ollama is running
Get-Process ollama* -ErrorAction SilentlyContinue

# Check Ollama logs (Windows Event Viewer or)
ollama serve  # Run in foreground to see errors

# Verify GPU is detected
nvidia-smi
```

#### "Model not found" errors

```powershell
# List available models
ollama list

# Re-pull a model (safe to run multiple times)
ollama pull qwen3:30b
```

#### Out of VRAM

```powershell
# Check what's using VRAM
nvidia-smi

# Unload the current model
ollama stop qwen3:30b

# Use a smaller model
ollama run qwen3:8b "your prompt here"
```

### Client Mode Issues

#### Crush can't connect to remote Ollama

```powershell
# Verify the server is reachable
curl http://your-server:11434/api/tags

# Common issues:
#   - Server firewall blocking port 11434
#   - Ollama on server not configured with OLLAMA_HOST=0.0.0.0
#   - Wrong IP address or port in Crush config
```

#### Slow responses in client mode

Network latency adds ~1-5ms per token (negligible).  If responses are slow, the bottleneck is the server's GPU, not the network.  Check `nvidia-smi` on the server to see if it's under load.

### Both Modes

#### Crush can't connect to Ollama

- Verify Ollama is running: `curl http://localhost:11434/api/tags` _(full)_ or `curl http://your-server:11434/api/tags` _(client)_
- Check the endpoint in Crush config: `%USERPROFILE%\.crush\crush.json`
- Ensure the port matches (default: 11434)

#### PATH issues after install

```powershell
# Check if winget Links directory is on PATH (where crush and uv symlinks live)
$env:PATH -split ";" | Where-Object { $_ -like "*WinGet*Links*" }

# If missing, restart your terminal — winget manages this automatically
# If still missing after restart, add manually:
$links = "$env:LOCALAPPDATA\Microsoft\WinGet\Links"
$p = [Environment]::GetEnvironmentVariable("Path","User")
[Environment]::SetEnvironmentVariable("Path","$p;$links","User")
```

---

## What's Next

This install covers **Phase 1** (Foundation).  Upcoming phases:

| Phase | What | Applies To |
|-------|------|-----------|
| **Phase 1: Foundation** | Ollama + Crush + models (full) or Crush only (client) | ✅ This script |
| **Phase 2: MCP Integration** | OfficeMCP for Word/PowerPoint creation | Both modes |
| **Phase 3: Cloud Fallback** | OpenRouter pay-per-token for frontier models | Both modes |
| **Phase 4: Bake-Off** | Test models on real tasks, establish baselines | Full mode (or via server) |
| **Phase 5: Dotfiles** | Package everything for repeatable installs | Both modes |

See `plan.md` for the full implementation roadmap including the future CachyOS server scenario.
