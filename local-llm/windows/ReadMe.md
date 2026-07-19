# Local LLM Stack — Windows Desktop

Single-user AI assistant on Windows with Ollama, Crush, Copilot CLI, MCP, and local image generation.

**Hardware:** RTX 5090 (32GB)
**Inference engine:** Ollama (single-user, GGUF models)

## What Gets Installed

| Component | Purpose | Install Method |
|-----------|---------|---------------|
| **Ollama** | GPU-accelerated model server | winget |
| **ollama-host** | Tray supervisor: owns Ollama + content:null compat proxy on `:11435` | Prebuilt from `dist/` |
| **Crush** | Terminal AI agent with MCP support | winget |
| **GitHub Copilot CLI** | Alternative terminal agent | User-local |
| **uv** | Python toolchain (manages MCP venvs) | winget |
| **Image Gen** | HiDream-O1-Image-Dev image generation (OpenAI API) | Python venv |
| **copilot-local** | Task picker launcher for Copilot CLI | `~/Documents/CLI/` + PATH |
| **imagegen MCP** | Image-generation tool for Crush/Copilot (Office authoring is a skill, not MCP) | Isolated Python venv |

### Models — RTX 5090 (~100 GB disk)

| Model | Launcher alias | Base tag | Task |
|-------|----------------|----------|------|
| Qwen3.6 27B (+MTP) | `qwen36-27b-212k` | `hf.co/unsloth/Qwen3.6-27B-MTP-GGUF:Q4_K_M` | Heavy coding (default), tech docs, creative |
| Qwen3.6 35B-A3B MoE | `qwen36-35b-256k` | `qwen3.6:35b` | Heavy coding / multimodal |
| Gemma 4 31B dense | `gemma4-31b-128k` | `gemma4:31b` | Heavy coding / general |
| Qwen3-Coder 30B-A3B | `qwen3coder-144k` | `qwen3-coder:30b` | Light coding / code review |
| GLM-4.7-Flash 30B MoE | `glm47-flash-198k` | `glm-4.7-flash` | Agentic / all MCP+tools / Office authoring |
| Qwen3 8B | `qwen3:8b` | `qwen3:8b` | Image-gen companion |

## Install

```powershell
cd local-llm\windows

# Default (RTX 5090) — models in user profile
.\install-windows.ps1

# RTX 5090 with secondary storage (recommended)
.\install-windows.ps1 -ModelPath v:\ollama

# Show all options
.\install-windows.ps1 -Help
```

> **Note:** The default 5090 roster downloads ~100GB of models. Use `-ModelPath` to store them on a fast secondary drive (SSD/NVMe) instead of filling your OS drive. The script sets `OLLAMA_MODELS` environment variable and restarts Ollama automatically.

### Install Options

The Windows box runs the **local Ollama** engine (or acts as a **client**); the CachyOS box
provides the **vLLM** engine, reached here as the `server` Crush provider.
Provider tokens: `local` = local Ollama · `server` = CachyOS vLLM server.

| Flag | Effect |
|------|--------|
| `-Install Full` | Local Ollama server + models + client tools (default) |
| `-Install OllamaOnly` | Local Ollama server + models only (no client tools) |
| `-Install Client` | Client tools only — no local Ollama; targets the vLLM `server` |
| `-Providers local,server` | Crush providers to enable (`server` = the CachyOS vLLM provider) |
| `-DefaultProvider local\|server` | Default Crush provider |
| `-OllamaModels 5090` | RTX 5090 roster (default; the only Windows tier) |
| `-SkipModels` | Install software only; pull models later |
| `-ModelsOnly` | Skip software; just pull/update models |
| `-ModelPath D:\models` | Custom model storage location |
| `-EnableLAN` | Expose Ollama to LAN (for laptop access) |
| `-Help` | Show detailed usage information |

> Legacy `-Mode Full\|Client` and the `squire-server` provider name remain accepted as deprecated aliases.

## Configure

### Ollama Host (compat supervisor)

`ollama-host` is the default local supervisor on Windows. It owns Ollama's lifecycle and runs a small
in-process proxy on `:11435` that coerces `content: null` chat messages to `""`, working around
Ollama's stricter-than-OpenAI `400 "invalid message content type: <nil>"`. Point local clients at
`http://localhost:11435/v1` rather than Ollama's own `:11434`.

The installer deploys the prebuilt binary to `%LOCALAPPDATA%\ollama-host\` and adds an **Ollama Host**
Start Menu shortcut (under `AI\`); launch it to bring the local stack up. The binary ships prebuilt in
`windows/ollama-host/dist/` — the installer copies that copy verbatim (verifying its `.sha256`) and
never builds from source, so **updating `dist/` is the responsibility of whoever changes the
ollama-host code.** See [`ollama-host/README.md`](ollama-host/README.md) for build, configuration, and
design details.

### Crush (primary agent)

Config: `~/.config/crush/crush.json` (created by installer)
- **Models** — `large` and `small` for Crush's internal routing
- **MCP** — imagegen server (auto-configured); Office authoring uses the `office` skill (python-docx/python-pptx/openpyxl via `uv run`)
- **Providers** — Local Ollama is default; add API keys for cloud fallback

Cloud fallback (set environment variables):
```
OPENROUTER_API_KEY=sk-or-...
GOOGLE_AI_API_KEY=AIza...
```

### Copilot CLI

`copilot-local` wires everything at launch — no manual config. It points Copilot at the local compat
proxy (`http://localhost:11435/v1`) for Ollama models, or at the CachyOS vLLM server (`:8000`) for the
`server` environment, and sets the model from whatever you pick.

### Model Roster

Two separate lists, by design:

- **What gets pulled** — the base tags the installer downloads, defined in `install-windows.ps1`
  (`$ProductionModels`). Change the installed set there, or use `-SkipModels` and pull by hand.

- **What the picker shows** — `scripts/local-models.json`, shipped verbatim to `~/.config/local-llm/`.
  Edit its `registry` / `task_alias` / launcher menus to re-map aliases and menu entries without
  touching the installer.

### Image Generation

The image gen service uses a Python venv at `%LOCALAPPDATA%\ai-tools\imagegen`. The HiDream-O1-Image-Dev model (~35GB) is downloaded during install.

## Test the Installation

```powershell
# 1. Ollama is running
ollama list

# 2. Inference works
ollama run qwen3:8b "Say hello in one sentence"

# 3. Crush connects
crush run "Say hello"

# 4. Copilot CLI launcher
copilot-local

# 5. MCP server (imagegen) configured
crush --debug run "list your tools" 2>&1 | findstr mcp_

# 6. Image generation API
curl http://localhost:8001/health
```

## Usage

### copilot-local (daily driver)

`copilot-local` opens a two-level picker: first an environment, then a task within it. Pass a model
alias to skip the picker entirely.

```
copilot-local                    # Interactive picker
copilot-local qwen36-27b-212k    # Skip picker, use a specific model
```

**Local — task profiles (RTX 5090):**
```
  Coding
    [1] Heavy coding       qwen36-27b-212k
    [2] Light coding       qwen3coder-144k
    [3] Code review        qwen3coder-144k
    
  Writing & Documents
    [4] Technical docs     qwen36-27b-212k
    [5] Creative writing   qwen36-27b-212k
    [6] Office documents   glm47-flash-198k   (office skill)
    
  Visual
    [7] Image generation   qwen3:8b + HiDream (MCP)
```

**Local — Experimental** swaps in the heavy-coding bench (Qwen3.6 35B-A3B, Gemma 4 31B, North Mini
Code, Nemotron 3 Nano, Ornith-1.0-35B, Devstral Small 2, …) with MCP off. **Squire-Server** appears
when the `server` provider is enabled and targets the CachyOS vLLM box.

### Crush (agentic tasks)

```powershell
crush                            # Interactive session
crush run "create a slide deck"  # One-shot; Office docs via the office skill
```

### Image Generation

**HiDream-O1-Image-Dev** (8B params, MIT) — OpenAI-compatible API on `localhost:8001`:

1. Pick **Image generation** (`[7]`, under Local) in copilot-local — it starts the server on demand
2. Server loads HiDream-O1 in bf16 (~16GB VRAM, ~15-25s/image)

```powershell
# Generate an image
curl http://localhost:8001/v1/images/generations `
  -H "Content-Type: application/json" `
  -d '{"prompt": "a cat sitting on a desk", "size": "1024x1024"}'
```

Or use the OpenAI Python client:
```python
from openai import OpenAI
client = OpenAI(base_url="http://localhost:8001/v1", api_key="unused")
result = client.images.generate(prompt="a sunset over mountains", size="1024x1024")
```

> **Note:** Images render at 2048×2048 native resolution and downscale to requested size.
> Model is ~35GB cached in HuggingFace hub. Inference repo cloned to `ai-tools/imagegen/HiDream-O1-Image/`.

### Model Management

```powershell
ollama list                      # Installed models
ollama ps                        # Loaded models + VRAM
ollama pull glm-4.7-flash        # Add a model
ollama rm qwen3-coder:30b        # Remove a model
nvidia-smi                       # GPU VRAM usage
```

### Connecting to the CachyOS Server

The CachyOS vLLM box is already wired as the `server` Crush provider — no hand-editing. Install with
`-Providers local,server` (the default for `-Install Full`) and point it at the box with
`-SquireServerIP <ip>`. In the launchers it shows up as the **Squire-Server** environment; Crush
exposes it directly as the `server` provider.

## Uninstall

```powershell
.\remove-windows.ps1              # Full removal
.\remove-windows.ps1 -KeepModels  # Keep downloaded models
```
