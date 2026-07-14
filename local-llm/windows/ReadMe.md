# Local LLM Stack — Windows Desktop

Single-user AI assistant on Windows with Ollama, Crush, Copilot CLI, MCP, and local image generation.

**Hardware:** RTX 5090 (32GB)
**Inference engine:** Ollama (single-user, GGUF models)

## What Gets Installed

| Component | Purpose | Install Method |
|-----------|---------|---------------|
| **Ollama** | GPU-accelerated model server | winget |
| **Crush** | Terminal AI agent with MCP support | winget |
| **GitHub Copilot CLI** | Alternative terminal agent | User-local |
| **uv** | Python toolchain (manages MCP venvs) | winget |
| **Image Gen** | HiDream-O1-Image-Dev image generation (OpenAI API) | Python venv |
| **copilot-local** | Task picker launcher for Copilot CLI | `~/Documents/CLI/` + PATH |
| **MCP servers** | Office document editing (Word, PowerPoint) | Isolated Python venvs |

### Models — RTX 5090 (~46 GB disk)

| Model | Tag | Size | Task |
|-------|-----|------|------|
| GLM-4.7-Flash 30B MoE | `glm-4.7-flash` | 17 GB | Heavy coding, tech docs, creative, Office (202k ctx) |
| Qwen3 14B | `qwen3:14b` | 9 GB | Light coding |
| DeepSeek-R1 32B | `deepseek-r1:32b` | 19 GB | Code review, reasoning |

## Install

```powershell
cd local-llm\windows

# Default (RTX 5090) — models in user profile
.\install-windows.ps1

# RTX 5090 with secondary storage (recommended)
.\install-windows.ps1 -ModelPath D:\OllamaModels

# Show all options
.\install-windows.ps1 -Help
```

> **Note:** The default 5090 profile downloads ~46GB of models. Use `-ModelPath` to store them on a fast secondary drive (SSD/NVMe) instead of filling your OS drive. The script sets `OLLAMA_MODELS` environment variable and restarts Ollama automatically.

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

### Crush (primary agent)

Config: `~/.config/crush/crush.json` (created by installer)
- **Models** — `large` and `small` for Crush's internal routing
- **MCP** — Word and PowerPoint servers (auto-configured)
- **Providers** — Local Ollama is default; add API keys for cloud fallback

Cloud fallback (set environment variables):
```
OPENROUTER_API_KEY=sk-or-...
GOOGLE_AI_API_KEY=AIza...
```

### Copilot CLI

The `copilot-local` launcher reads `COPILOT_LOCAL_PROFILE` env var (set by installer). No manual config needed.

### Custom Model List

Override defaults by editing `config/ollama-models.txt`:
```text
# One tag per line
glm-4.7-flash
qwen3:14b
deepseek-r1:32b
```

### Image Generation

The image gen service uses a Python venv at `%LOCALAPPDATA%\ai-tools\imagegen`. The HiDream-O1-Image-Dev model (~35GB) is downloaded during install.

## Test the Installation

```powershell
# 1. Ollama is running
ollama list

# 2. Inference works
ollama run qwen3:14b "Say hello in one sentence"

# 3. Crush connects
crush run "Say hello"

# 4. Copilot CLI launcher
copilot-local

# 5. MCP servers configured
crush --debug run "list your tools" 2>&1 | findstr mcp_

# 6. Image generation API
curl http://localhost:8001/health
```

## Usage

### copilot-local (daily driver)

```
copilot-local                    # Interactive task picker
copilot-local glm-4.7-flash     # Skip picker, use specific model
```

**Task picker (RTX 5090):**
```
  [1] Heavy coding        (glm-4.7-flash)
  [2] Light coding        (qwen3:14b)
  [3] Code review         (deepseek-r1:32b)
  [4] Technical docs      (glm-4.7-flash)
  [5] Creative writing    (glm-4.7-flash)
  [6] Office documents    (glm-4.7-flash)
  [7] Image generation    (HiDream-O1 — local API)
```

### Crush (MCP/Office tasks)

```powershell
crush                            # Interactive session
crush run "create a slide deck"  # One-shot with MCP tools
```

### Image Generation

**HiDream-O1-Image-Dev** (8B params, MIT) — OpenAI-compatible API on `localhost:8001`:

1. Select option 7 from copilot-local (starts the server)
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
ollama rm qwen2.5-coder:14b     # Remove a model
nvidia-smi                       # GPU VRAM usage
```

### Connecting to the CachyOS Server

If you also run the CachyOS server (vLLM), you can point Crush at it:
```json
// In ~/.config/crush/crush.json, add a provider:
{
  "providers": {
    "vllm-server": {
      "kind": "openai",
      "baseURL": "http://server-ip:8000/v1",
      "apiKey": "unused"
    }
  }
}
```

## Uninstall

```powershell
.\remove-windows.ps1              # Full removal
.\remove-windows.ps1 -KeepModels  # Keep downloaded models
```
