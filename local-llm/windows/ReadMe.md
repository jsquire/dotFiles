# Local LLM Stack — Windows Desktop

Single-user AI assistant on Windows with Ollama, Crush, Copilot CLI, MCP, and ComfyUI.

**Hardware:** RTX 5090 (32GB, default) or RTX 4090 (24GB)
**Inference engine:** Ollama (single-user, GGUF models)

## What Gets Installed

| Component | Purpose | Install Method |
|-----------|---------|---------------|
| **Ollama** | GPU-accelerated model server | winget |
| **Crush** | Terminal AI agent with MCP support | winget |
| **GitHub Copilot CLI** | Alternative terminal agent | User-local |
| **uv** | Python toolchain (manages MCP venvs) | winget |
| **ComfyUI Desktop** | Image generation (FLUX, SD3.5) | winget |
| **copilot-local** | Task picker launcher for Copilot CLI | `~/Documents/CLI/` + PATH |
| **MCP servers** | Office document editing (Word, PowerPoint) | Isolated Python venvs |

### Models — RTX 5090 Profile (default, ~90 GB disk)

| Model | Tag | Size | Task |
|-------|-----|------|------|
| Gemma 4 31B | `gemma4:31b` | 20 GB | Heavy coding (256k context) |
| Qwen3 14B | `qwen3:14b` | 9 GB | Light coding |
| DeepSeek-R1 32B | `deepseek-r1:32b` | 19 GB | Code review, reasoning |
| Gemma 3 27B | `gemma3:27b` | 16 GB | Technical documentation |
| Llama 3.3 70B Q2 | `llama3.3:70b-instruct-q2_K` | 26 GB | Creative writing |
| Qwen3-Coder 30B MoE | `qwen3-coder:30b` | 19 GB | Office documents (256k context) |

### Models — RTX 4090 Profile (~62 GB disk)

| Model | Tag | Size | Task |
|-------|-----|------|------|
| Qwen2.5-Coder 32B | `qwen2.5-coder:32b` | 19 GB | Heavy coding |
| Qwen2.5-Coder 14B | `qwen2.5-coder:14b` | 9 GB | Light coding |
| DeepSeek-R1 32B | `deepseek-r1:32b` | 19 GB | Code review, reasoning |
| Mistral Small 3.2 | `mistral-small3.2:24b` | 15 GB | Tech docs, creative, Office docs |

## Install

```powershell
cd local-llm\windows

# Default (RTX 5090)
.\install-windows.ps1

# RTX 4090 profile
.\install-windows.ps1 -ModelProfile Server

# Show all options
.\install-windows.ps1 -Help
```

### Install Options

| Flag | Effect |
|------|--------|
| `-ModelProfile Desktop` | RTX 5090 models (default) |
| `-ModelProfile Server` | RTX 4090 models |
| `-SkipModels` | Install software only; pull models later |
| `-ModelsOnly` | Skip software; just pull/update models |
| `-ModelPath D:\models` | Custom model storage location |
| `-EnableLAN` | Expose Ollama to LAN (for laptop access) |
| `-Help` | Show detailed usage information |

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
gemma4:31b
qwen3:14b
deepseek-r1:32b
```

### ComfyUI

Auto-configures on first launch — downloads a default image model (~12 GB) and detects your GPU.

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

# 6. ComfyUI launches
start "" "%LOCALAPPDATA%\Programs\ComfyUI\ComfyUI.exe"
```

## Usage

### copilot-local (daily driver)

```
copilot-local                    # Interactive task picker
copilot-local gemma4:31b         # Skip picker, use specific model
```

**Task picker (RTX 5090):**
```
  [1] Heavy coding        (gemma4:31b)
  [2] Light coding        (qwen3:14b)
  [3] Code review         (deepseek-r1:32b)
  [4] Technical docs      (gemma3:27b)
  [5] Creative writing    (llama3.3:70b-instruct-q2_K)
  [6] Office documents    (qwen3-coder:30b)
  [7] Image generation    (ComfyUI - launches separately)
```

### Crush (MCP/Office tasks)

```powershell
crush                            # Interactive session
crush run "create a slide deck"  # One-shot with MCP tools
```

### Image Generation (ComfyUI)

1. Launch from Start Menu or `%LOCALAPPDATA%\Programs\ComfyUI\ComfyUI.exe`
2. Browser opens to `localhost:8188`
3. Load a workflow → type prompt → Generate

### Model Management

```powershell
ollama list                      # Installed models
ollama ps                        # Loaded models + VRAM
ollama pull gemma4:31b           # Add a model
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
