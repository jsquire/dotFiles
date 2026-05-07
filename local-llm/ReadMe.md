# Local LLM Stack

Self-hosted AI assistant with NVIDIA GPUs. Two platforms, two inference engines, one API.

## Architecture

| | **Windows Desktop** | **CachyOS Server** |
|---|---|---|
| **GPU** | RTX 5090 (32GB) | RTX 4090 (24GB) |
| **Engine** | Ollama (single-user) | vLLM (multi-user) |
| **API** | `http://localhost:11434/v1` | `http://server-ip:8000/v1` |
| **Users** | 1 (you, locally) | 2-4 concurrent (LAN) |
| **Models** | GGUF (Ollama ecosystem) | GPTQ-Int4 (HuggingFace) |

Both expose OpenAI-compatible APIs. Crush and Copilot CLI connect identically — only the base URL changes.

## Quick Start

**Windows Desktop:**
```powershell
cd local-llm\windows
.\install-windows.ps1
```

**CachyOS Server:**
```bash
cd local-llm/cachyos
./install-cachyos.sh --mode server
```

## Documentation

| Guide | For |
|-------|-----|
| **[windows/ReadMe.md](windows/ReadMe.md)** | Desktop setup — Ollama, 5090/4090 profiles, single-user |
| **[cachyos/ReadMe.md](cachyos/ReadMe.md)** | Server setup — vLLM, multi-user, always-on LAN endpoint |

## Components

| Component | Purpose |
|-----------|---------|
| **Ollama** / **vLLM** | Model serving (platform-dependent) |
| **Crush** | Terminal AI agent with MCP support |
| **GitHub Copilot CLI** | Alternative terminal agent |
| **ComfyUI Desktop** | Image generation (FLUX, SD3.5) — Windows only |
| **MCP servers** | Office document editing (Word, PowerPoint) |
| **copilot-local** | Task picker launcher |

## Directory Structure

```
local-llm/
├── ReadMe.md                  # This file (index)
├── windows/
│   ├── ReadMe.md              # Desktop documentation
│   ├── install-windows.ps1    # Windows installer
│   └── remove-windows.ps1     # Windows uninstaller
├── cachyos/
│   ├── ReadMe.md              # Server documentation
│   ├── install-cachyos.sh     # CachyOS installer
│   └── remove-cachyos.sh      # CachyOS uninstaller
├── scripts/
│   ├── copilot-local.cmd      # Windows task picker
│   └── copilot-local.sh       # Linux task picker
├── config/
│   ├── crush.json             # Crush config template
│   └── ollama-models.txt      # Custom model list (optional)
└── mcp/
    ├── setup-mcp-venvs.ps1    # Windows MCP setup
    └── setup-mcp-venvs.sh     # Linux MCP setup
```
