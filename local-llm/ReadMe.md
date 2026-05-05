# Local LLM — Self-Hosted AI Coding Assistant

A self-hosted AI coding assistant stack comparable to Claude Code / Copilot CLI, built on open-source tooling.  Optimized for multi-language coding, sysadmin (Windows + Linux), document creation via MCP, and general knowledge tasks.

## Architecture

```
┌────────────────────────────────────────────────────────────┐
│  Layer 4: Configuration                                    │
│  ~/.crush/crush.json    Provider/model config (no secrets) │
│  ~/.crush/mcp-servers   MCP server definitions             │
│  ~/.ollama/models/      Model storage (~50-225 GB)         │
├────────────────────────────────────────────────────────────┤
│  Layer 3: Isolated Environments                            │
│  Python 3.12 via uv  ·  Each MCP server in its own venv    │
├────────────────────────────────────────────────────────────┤
│  Layer 2: User-Local Binaries (no admin, no registry)      │
│  Crush (CLI agent)  ·  uv (Python toolchain)               │
├────────────────────────────────────────────────────────────┤
│  Layer 1: System Install (one item, requires admin)        │
│  Ollama — GPU-accelerated model server                     │
└────────────────────────────────────────────────────────────┘
```

## Installation Modes

| Mode | What It Installs | Use Case |
|------|-----------------|----------|
| **Full** | Ollama + models + Crush + uv + MCP dirs | Machine with a GPU running inference locally (localhost only) |
| **Server** _(CachyOS only)_ | Full + LAN firewall + client access info | Dedicated always-on LAN inference endpoint |
| **Client** | Crush + uv + MCP dirs (no Ollama) | Machine that connects to a remote Ollama server on the LAN |

## Model Profiles (Full Mode)

| Profile | Primary 27B Tag | Quant | VRAM Budget | Target GPU |
|---------|----------------|-------|-------------|------------|
| **Standard** | `qwen3:30b` | Q4_K_M ~18 GB | 24 GB | RTX 4090 |
| **High** | `qwen3:30b-q5_K_M` | Q5_K_M ~21 GB | 32 GB (IDEs open) | RTX 5090 |
| **Ultra** | `qwen3:30b-q6_K` | Q6_K ~24 GB | 32 GB (IDEs closed) | RTX 5090 |

All profiles also pull: `qwen3:8b`, `deepseek-r1:14b`, `llama3.1:8b`

## Platforms

| Directory | Platform |
|-----------|----------|
| `windows/` | Windows 10/11 desktop |
| `cachyos/` | CachyOS server (Arch-based) |

## Directory Structure

```
local-llm/
├── ReadMe.md                  # This file — cross-platform overview
├── windows/
│   ├── install-windows.ps1    # Full or Client install
│   ├── remove-windows.ps1     # Full or Client removal
│   └── ReadMe.md              # Windows-specific guide
├── cachyos/
│   ├── install-cachyos.sh     # Full, Server, or Client install
│   ├── remove-cachyos.sh      # Full/Server or Client removal
│   └── ReadMe.md              # CachyOS-specific guide
├── config/
│   ├── ollama-models.txt      # Custom model pull list (overrides profiles)
│   ├── crush.json             # Crush config template
│   └── mcp-servers.json       # MCP server definitions template
├── mcp/
│   ├── setup-mcp-venvs.ps1    # Windows MCP venv setup
│   ├── setup-mcp-venvs.sh     # Linux MCP venv setup
│   ├── office-mcp-setup.md    # OfficeMCP installation guide
│   └── templates/             # Branded .docx/.pptx templates
└── benchmarks/
    ├── ReadMe.md              # Methodology and scoring
    ├── tasks/                 # Bake-off task definitions
    │   ├── coding-tasks.md
    │   ├── sysadmin-tasks.md
    │   ├── document-tasks.md
    │   └── reasoning-tasks.md
    └── results/               # Tracked results (committed for history)
```

## Cloud Fallback

Local models handle the majority of tasks.  For frontier-quality needs:

| Provider | Role | Cost |
|----------|------|------|
| **OpenRouter** | Primary cloud fallback (all models, one API key) | Pay-per-token |
| **Google AI Studio** | Secondary zero-cost option (Gemini) | Free tier |

API keys are stored in the OS credential store — never in config files:

| Platform | Credential Store | CLI to Set |
|----------|-----------------|------------|
| Windows | Windows Credential Manager | `cmdkey /generic:OPENROUTER_API_KEY /user:api /pass:<key>` |
| CachyOS / Linux | `secret-tool` (libsecret / GNOME Keyring) | `secret-tool store --label='OpenRouter' service openrouter key api_key` |

## Quick Start

### Windows — Full Install (local GPU)

```powershell
cd local-llm\windows
.\install-windows.ps1                          # Standard profile (RTX 4090)
.\install-windows.ps1 -ModelProfile High       # High profile (RTX 5090)
```

### CachyOS — Server Install (LAN endpoint)

```bash
cd local-llm/cachyos
./install-cachyos.sh --mode server             # Full + LAN firewall + client instructions
./install-cachyos.sh --mode server --model-profile high
```

### Client Install (remote Ollama — either platform)

```powershell
# Windows
.\install-windows.ps1 -Mode Client -OllamaHost http://server:11434
```

```bash
# CachyOS
./install-cachyos.sh --mode client --ollama-host http://server:11434
```

### Removal

```powershell
# Windows
.\remove-windows.ps1                           # Full removal
.\remove-windows.ps1 -Mode Client              # Client-only removal
.\remove-windows.ps1 -KeepModels               # Keep downloaded models
```

```bash
# CachyOS
./remove-cachyos.sh                            # Full removal
./remove-cachyos.sh --mode server              # Same as full (includes firewall cleanup)
./remove-cachyos.sh --mode client              # Client-only removal
```

## Related

- **Benchmarks:** See `benchmarks/ReadMe.md` for the bake-off evaluation framework
- **MCP Servers:** See `mcp/office-mcp-setup.md` for Office document creation setup
- **Config Override:** Place a customized `config/ollama-models.txt` to override built-in model profiles

---

## Appendix A: Browsing and Adding Ollama Models

The install scripts ship with a curated set of models optimized for coding, reasoning, and sysadmin tasks.  You can supplement or replace these with any model from the Ollama library.

### Browse Available Models

The full model catalog is at **https://ollama.com/library**.  You can also search from the command line:

```bash
# Search by name (works on both platforms)
ollama list                          # Show locally installed models
ollama show qwen3:30b                # Show details of a specific model
```

On the website, each model page shows:
- Available parameter sizes (e.g., 1.5B, 8B, 14B, 27B, 70B)
- Available quantizations (e.g., Q3_K_M, Q4_K_M, Q5_K_M, Q6_K, Q8_0, FP16)
- File size for each variant
- A README with capabilities, benchmarks, and usage notes

### Understanding Model Tags

Ollama tags follow the format `name:variant`:

| Tag | What It Means |
|-----|---------------|
| `qwen3:30b` | Qwen 3.6 27B parameter model, default quantization (Q4_K_M) |
| `qwen3:30b-q5_K_M` | Same model, higher fidelity Q5_K_M quantization |
| `qwen3:30b-q6_K` | Same model, near-lossless Q6_K quantization |
| `qwen3:8b` | Qwen 3.6 8B, default quantization — smaller and faster |
| `deepseek-r1:14b` | DeepSeek R1 distilled to 14B parameters |
| `llama3.1:8b` | Meta Llama 3.1 8B |

When no quantization suffix is given (e.g., `qwen3:30b`), Ollama pulls the default — usually Q4_K_M, which balances quality and VRAM usage.

### Quantization Tiers

Higher quantization means better quality but more VRAM:

| Quant | Quality | VRAM Overhead | Best For |
|-------|---------|---------------|----------|
| Q3_K_M | Good | Lowest | Fitting large models in tight VRAM (shared GPU) |
| Q4_K_M | Very good | Moderate | **Default** — best quality-to-size ratio |
| Q5_K_M | Excellent | High | 32 GB GPUs with other apps running |
| Q6_K | Near-lossless | Very high | 32 GB GPUs with VRAM to spare |
| Q8_0 | Essentially lossless | Highest | Only for small models (8B or less) |

**Rule of thumb:** If a model fits in your VRAM at a higher quantization, use it.  The quality jump from Q3 → Q4 is significant; Q4 → Q5 is noticeable; Q5 → Q6 is subtle.

### Pull a New Model

```bash
# Pull from the Ollama library
ollama pull codellama:13b              # Code Llama 13B
ollama pull mistral:7b                 # Mistral 7B
ollama pull gemma3:27b                 # Google Gemma 3 27B
ollama pull phi4:14b                   # Microsoft Phi-4 14B

# Pull a specific quantization
ollama pull qwen3:30b-q5_K_M

# Remove a model you no longer need
ollama rm codellama:13b
```

### Use a Custom Model List

To permanently change which models are pulled by the install script, edit `config/ollama-models.txt`:

```text
# My custom model set — one tag per line
qwen3:30b-q5_K_M       # Primary coder (High profile)
qwen3:8b               # Fast tasks
deepseek-r1:14b        # Hard reasoning
codellama:13b           # Code-specific tasks
phi4:14b               # Microsoft Phi-4 for general tasks
```

When this file exists, the install script ignores the built-in model profile (`-ModelProfile` flag) and pulls exactly what is listed.

### Check VRAM Before Pulling

Before pulling a large model, verify you have enough VRAM:

```bash
# Check GPU VRAM (NVIDIA)
nvidia-smi                             # Shows total / used / free VRAM

# Check what's currently loaded in Ollama
ollama ps                              # Shows running models and their VRAM usage
```

**VRAM budget guidelines:**

| GPU | Available VRAM (with IDEs) | Largest Comfortable Model |
|-----|---------------------------|--------------------------|
| RTX 4090 (24 GB) | ~17.5-19 GB | 27B Q3_K_M or Q4_K_M |
| RTX 5090 (32 GB) | ~25.5-27 GB | 27B Q5_K_M or Q6_K |
| RTX 4090 dedicated server | 24 GB | 27B Q4_K_M (full quality) |

### Notable Models to Consider

| Model | Parameters | Strengths | Tag |
|-------|-----------|-----------|-----|
| **Qwen 3.6** | 8B, 27B | Coding, tool-use, multilingual — our primary | `qwen3:30b`, `qwen3:8b` |
| **DeepSeek R1** | 14B, 32B, 70B | Deep reasoning, math, complex debugging | `deepseek-r1:14b` |
| **Llama 3.1** | 8B, 70B | General purpose, strong instruction following | `llama3.1:8b` |
| **Code Llama** | 7B, 13B, 34B | Code-focused fine-tune of Llama | `codellama:13b` |
| **Mistral** | 7B | Compact, fast, good quality for size | `mistral:7b` |
| **Phi-4** | 14B | Microsoft's efficient small model | `phi4:14b` |
| **Gemma 3** | 9B, 27B | Google's latest, strong on reasoning | `gemma3:27b` |
| **Qwen-Coder** | 7B, 14B, 32B | Code-specialized Qwen variant | `qwen2.5-coder:14b` |

Check the [Ollama library](https://ollama.com/library) regularly — new models are added frequently and the landscape evolves fast.

---

## Appendix B: Cloud Fallback Setup

Local models handle the majority of daily tasks, but frontier-class models (Claude Opus, GPT-4o, Gemini Ultra) are sometimes needed for the hardest problems.  These two providers give you cloud access without a subscription.

### OpenRouter (Primary — Pay-Per-Token)

OpenRouter aggregates 200+ models behind a single API key.  You pay only for tokens consumed — no monthly fee, no commitment.

**Sign up:**

1. Go to **https://openrouter.ai/**
2. Click **Sign Up** (top right) — you can use GitHub, Google, or email
3. After sign-in, go to **https://openrouter.ai/keys**
4. Click **Create Key** — give it a name like "local-llm"
5. Copy the key (starts with `sk-or-...`)

**Add credits:**

1. Go to **https://openrouter.ai/credits**
2. Add $5-10 to start — this lasts a long time for occasional fallback use
3. You can set a monthly budget cap here too

**Store the key securely:**

```powershell
# Windows — Credential Manager
cmdkey /generic:OPENROUTER_API_KEY /user:api /pass:sk-or-your-key-here
```

```bash
# CachyOS / Linux — libsecret
secret-tool store --label='OpenRouter API Key' service openrouter key api_key
# Then paste your key when prompted
```

**Configure in Crush:**

Add to your `~/.crush/crush.json` or configure via Crush settings:
- Provider type: `openai-compatible`
- Endpoint: `https://openrouter.ai/api/v1`
- API key: reference from credential store (or set `OPENROUTER_API_KEY` env var)

**Recommended models via OpenRouter:**

| Model | Use Case | Approx. Cost |
|-------|----------|-------------|
| `anthropic/claude-sonnet-4` | Complex coding, architecture | ~$3/M input, $15/M output |
| `anthropic/claude-haiku-4` | Fast cloud tasks | ~$0.25/M input, $1.25/M output |
| `openai/gpt-4o` | General purpose, broad knowledge | ~$2.50/M input, $10/M output |
| `google/gemini-2.5-pro` | Long context, multimodal | ~$1.25/M input, $10/M output |

Pricing varies — check https://openrouter.ai/models for current rates.

---

### Google AI Studio (Secondary — Free Tier)

Google AI Studio provides free access to Gemini models with generous rate limits.  No credit card required.

**Sign up:**

1. Go to **https://aistudio.google.com/**
2. Sign in with your Google account
3. Accept the Terms of Service
4. Click **Get API Key** in the left sidebar (or go to https://aistudio.google.com/apikey)
5. Click **Create API key** — select or create a Google Cloud project when prompted
6. Copy the key (starts with `AIza...`)

**Free tier limits (as of 2025):**

| Model | Requests/min | Requests/day | Tokens/min |
|-------|-------------|-------------|------------|
| Gemini 2.5 Flash | 10 | 500 | 250,000 |
| Gemini 2.5 Pro | 5 | 50 | 50,000 |

These limits are sufficient for occasional fallback when local models struggle.

**Store the key securely:**

```powershell
# Windows
cmdkey /generic:GOOGLE_AI_API_KEY /user:api /pass:AIza-your-key-here
```

```bash
# CachyOS / Linux
secret-tool store --label='Google AI Studio' service google-ai key api_key
```

**Configure in Crush:**

- Provider type: `openai-compatible`
- Endpoint: `https://generativelanguage.googleapis.com/v1beta/openai`
- API key: from credential store or `GOOGLE_AI_API_KEY` env var
- Model: `gemini-2.5-flash` or `gemini-2.5-pro`

---

### When to Use Cloud Fallback

| Scenario | Recommended |
|----------|-------------|
| Daily coding, commit messages, quick questions | **Local** (qwen3:30b, qwen3:8b) |
| Complex multi-file refactors | Try local first → cloud if quality is poor |
| Architecture design, nuanced reasoning | **Cloud** (Claude Sonnet, Gemini Pro) |
| Very long context (>32K tokens) | **Cloud** (Gemini — 1M+ context window) |
| Frontier-quality creative writing | **Cloud** (Claude Opus, GPT-4o) |

The bake-off (Phase 4) will quantify exactly how often cloud fallback is needed for your workflow.
