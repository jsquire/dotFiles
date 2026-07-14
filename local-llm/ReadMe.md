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
./install-cachyos.sh --install server
```

> **Engine is explicit in the install/provider vocabulary:** `local` = Ollama · `server` = vLLM ·
> `client` = client tools only. On the CachyOS box the standing role is `--install server` (vLLM);
> Windows desktops run `local` (Ollama). Legacy `--mode`/`squire-server` remain accepted aliases.

## Documentation

| Guide | For |
|-------|-----|
| **[windows/ReadMe.md](windows/ReadMe.md)** | Desktop setup — Ollama, 5090 profile, single-user |
| **[cachyos/ReadMe.md](cachyos/ReadMe.md)** | Server setup — vLLM, multi-user, always-on LAN endpoint |

## Components

| Component | Purpose |
|-----------|---------|
| **Ollama** / **vLLM** | Model serving (platform-dependent) |
| **Crush** | Terminal AI agent with MCP support |
| **GitHub Copilot CLI** | Alternative terminal agent |
| **ComfyUI Desktop** | Image generation (HiDream-O1, SD3.5) — Windows only |
| **MCP servers** | Office document editing (Word, PowerPoint) |
| **copilot-local** | Task picker launcher |

## Directory Structure

```
local-llm/
├── ReadMe.md                        # This file (index)
├── windows/
│   ├── ReadMe.md                    # Desktop documentation
│   ├── install-windows.ps1          # Windows installer
│   ├── remove-windows.ps1           # Windows uninstaller
│   ├── Modelfile.qwen3coder-65k     # Ollama custom model definition
│   ├── imagegen-server.py           # ComfyUI API bridge
│   ├── imagegen-start.cmd           # ComfyUI launcher
│   └── icons/                       # Shortcut icons (copilot/crush, dark/light)
├── cachyos/
│   ├── ReadMe.md                    # Server documentation
│   ├── install-cachyos.sh           # CachyOS installer
│   └── remove-cachyos.sh           # CachyOS uninstaller
├── scripts/
│   ├── copilot-local.cmd            # Windows task picker
│   ├── copilot-local.sh             # Linux task picker
│   ├── crush-task.ps1               # Crush launcher (Windows)
│   ├── crush-task.sh                # Crush launcher (Linux)
│   ├── crush-task.cmd               # Crush launcher (cmd wrapper)
│   └── imagegen-launch.ps1          # Image gen session launcher
├── config/
│   ├── crush.json                   # Crush config template (all providers)
│   ├── copilot-mcp-config.json      # Copilot CLI MCP server config
│   ├── ollama-models.txt            # Custom model list (optional)
│   ├── mcp/                         # MCP server configs (placeholder)
│   └── skills/
│       ├── git-safety/SKILL.md      # Git safety skill definition
│       └── office/SKILL.md          # Office authoring skill (docx/pptx/xlsx via Python)
├── mcp/
│   ├── ReadMe.md                    # MCP setup documentation
│   ├── imagegen-mcp-server.py       # Image generation MCP server
│   ├── setup-mcp-venvs.ps1         # Windows MCP venv setup
│   ├── setup-mcp-venvs.sh          # Linux MCP venv setup
│   └── templates/                   # MCP template assets
└── benchmarks/
    ├── ReadMe.md                    # Benchmark methodology
    ├── tasks/                       # Evaluation task sets
    │   ├── coding-tasks.md
    │   ├── document-tasks.md
    │   ├── reasoning-tasks.md
    │   └── sysadmin-tasks.md
    └── results/                     # Benchmark output (gitkeep)
```
