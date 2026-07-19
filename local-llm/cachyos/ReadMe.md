# Local LLM Stack — CachyOS Server

Multi-user AI inference server on CachyOS (Arch-based Linux) with vLLM, Crush, and MCP.

**Hardware:** RTX 4090 (24GB dedicated VRAM)
**Inference engine:** vLLM (multi-user, continuous batching, PagedAttention)

## Why vLLM (not Ollama)

This server hosts multiple users simultaneously. vLLM provides:

| Feature | Benefit |
|---------|---------|
| **Continuous batching** | 2-4 concurrent users at near-single-user speed |
| **PagedAttention** | Efficient KV-cache sharing — more users per GB of VRAM |
| **Prefix caching** | Shared system prompts stored once (e.g., Crush's coding prompt) |
| **OpenAI-compatible API** | Crush/Copilot clients connect identically to Ollama |
| **HuggingFace models** | Direct safetensors/GPTQ/AWQ — no GGUF conversion |

Clients connect via `http://server-ip:8000/v1` — same OpenAI API as Ollama.

## What Gets Installed

| Component | Purpose | Install Method |
|-----------|---------|---------------|
| **NVIDIA drivers + CUDA** | GPU acceleration | pacman |
| **vLLM** | Multi-user inference server | pip (Python package) |
| **Image Gen API** | OpenAI-compatible image generation | pip (SGLang-Diffusion) |
| **Crush** | Terminal AI agent with MCP | pacman or user-local |
| **uv** | Python toolchain (MCP venvs) | Official installer |
| **copilot-local** | Task picker launcher | `~/.local/bin/` |
| **MCP servers** | Office document editing | Isolated Python venvs |

### Models (HuggingFace 4-bit AWQ/GPTQ, ~50 GB disk + ~35 GB image gen)

> **vLLM serves ONE model at a time** on the 24 GB card. **Mistral-Small-3.2-24B is the standing
> default** (basic chat / general, 64K); the specialist coding and image roles are on-demand
> **switch modes** loaded via `cachyos-switch-model` (see below). All roster models run on stable
> vLLM (≥ 0.24.0) — no nightly/git build needed.

| Model | HuggingFace ID | Served name | Size | Mode / role |
|-------|---------------|-------------|------|-------------|
| Mistral-Small-3.2 24B AWQ | `gghfez/Mistral-Small-3.2-24B-Instruct-hf-AWQ` | `mistral-small` | ~14 GB | **`mistral` (default)** — basic chat / general (64K) |
| Qwen3-Coder 30B-A3B GPTQ | `btbtyler09/Qwen3-Coder-30B-A3B-Instruct-gptq-4bit` | `qwen3-coder` | ~19 GB | `coder` — coding + office docs (56K) |
| Devstral-2 24B AWQ | `cyankiwi/Devstral-Small-2-24B-Instruct-2512-AWQ-4bit` | `devstral` | ~14 GB | `coder-alt` — agentic coding / review (56K) |
| Qwen3 1.7B AWQ | `Orion-zhen/Qwen3-1.7B-AWQ` | `qwen3-4b` | ~2 GB | `image` companion (co-resides with HiDream) |
| HiDream-O1-Image-Dev | `HiDream-ai/HiDream-O1-Image-Dev` | — | ~35 GB | `image` generation (SGLang-Diffusion) |

## Install

```bash
cd ~/dotFiles/local-llm/cachyos
chmod +x install-cachyos.sh

# Server install — vLLM engine (default role for the CachyOS box)
./install-cachyos.sh --install server

# Skip model downloads (install software first)
./install-cachyos.sh --install server --skip-models

# Custom model storage path
./install-cachyos.sh --install server --model-path /srv/models
```

### Install Options

The `--install` value makes the **inference engine explicit**:
`local` = Ollama · `server` = vLLM · `client` = tools only (no local engine).

| Flag | Effect |
|------|--------|
| `--install server` | vLLM server (Ollama-free) — the standing role for this box |
| `--install local` | Local Ollama server + client tools |
| `--install client` | Client only (Crush + MCP, no local inference) |
| `--ollama-models 4090\|5090` | Ollama roster GPU tier: 4090 (24GB) or 5090 (32GB). Applies to `--install local`, and to `--install client` when `--providers` includes `local` |
| `--test-profiles` | Also install the experimental/bench models (North Mini Code, Nemotron 3 Nano, Ornith-1.0-35B, Devstral Small 2); default is the 6 production models only |
| `--no-client-tools` | With `--install local`: install the Ollama server + models only (no Crush/MCP) |
| `--providers local,server` | Crush providers to enable (`server` = the vLLM provider) |
| `--skip-models` | Install software only |
| `--models-only` | Download models only |
| `--force` | Overwrite existing `crush.json` + Copilot `mcp-config.json` (backs up each to a timestamped `.bak` first) |
| `--model-path /path` | Custom HuggingFace cache location |
| `--ollama-host URL` | Remote endpoint (client mode) |

> Legacy `--mode` and the `squire-server` provider name remain accepted as deprecated
> aliases (e.g. `--mode server` → `--install server`; `--providers squire-server` → `--providers server`).

## Configure

### vLLM Server

The installer creates a systemd service. Configuration via environment in the override file:

```bash
# /etc/systemd/system/vllm.service.d/override.conf
[Service]
Environment="VLLM_MODEL=gghfez/Mistral-Small-3.2-24B-Instruct-hf-AWQ"
Environment="VLLM_TOKENIZER=jeffcookio/Mistral-Small-3.2-24B-Instruct-2506-awq-sym"
Environment="VLLM_TOKENIZER_MODE=mistral"
Environment="VLLM_HOST=0.0.0.0"
Environment="VLLM_PORT=8000"
Environment="VLLM_MAX_MODEL_LEN=65536"
Environment="VLLM_GPU_MEMORY_UTILIZATION=0.92"
```

Switch the active model (see **Switching Models** below for the recommended `cachyos-switch-model` CLI):
```bash
# For the Mistral default only — edit the override
sudo systemctl edit vllm
# Change VLLM_MODEL to the desired model
# Then restart
sudo systemctl restart vllm
```

### Crush (agent on this server)

Config: `~/.config/crush/crush.json`
```json
{
  "providers": {
    "local": {
      "kind": "openai",
      "baseURL": "http://localhost:8000/v1",
      "apiKey": "unused"
    }
  }
}
```

### Firewall

The installer configures ufw to allow LAN access only:
- Allow `192.168.0.0/16` → TCP 8000 (vLLM)
- Allow `192.168.0.0/16` → TCP 8001 (Image Gen)
- Deny external access to both ports

### Image Generation Service

The installer creates an `imagegen.service` running SGLang-Diffusion — a production-grade inference server with a native OpenAI Images API.

```bash
# Service management
sudo systemctl start imagegen    # Start
sudo systemctl stop imagegen     # Stop (frees VRAM)
sudo systemctl status imagegen   # Check status
journalctl -u imagegen -f        # Live logs
```

Configuration: the imagegen service uses a Python server with HiDream-O1-Image-Dev.
```bash
sudo systemctl edit imagegen
```

**GPU sharing:** vLLM is configured with `gpu_memory_utilization=0.50`, reserving ~16GB for HiDream-O1 image generation. Both services share the RTX 4090 but cannot run simultaneously at full capacity. Image gen latency is ~15-25 seconds per image.

## Test the Installation

```bash
# 1. vLLM service is running
sudo systemctl status vllm

# 2. vLLM API responds
curl http://localhost:8000/v1/models
# Expected: JSON listing the loaded model

# 3. LLM inference works
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"mistral-small","messages":[{"role":"user","content":"Say hello"}]}'
# Expected: JSON with a greeting

# 4. Image gen service is running
sudo systemctl status imagegen

# 5. Image gen API responds
curl http://localhost:8001/health
# Expected: {"status":"ok","model":"HiDream-O1-Image-Dev","model_loaded":true}

# 6. Image generation works
curl http://localhost:8001/v1/images/generations \
  -H "Content-Type: application/json" \
  -d '{"prompt":"a red fox in a snowy forest","size":"512x512","n":1}'
# Expected: {"created":...,"data":[{"b64_json":"..."}]}

# 7. Remote access (from another machine)
curl http://server-ip:8000/v1/models
curl http://server-ip:8001/health

# 8. Crush connects
crush run "Say hello"

# 9. GPU is being used
nvidia-smi
# Expected: vLLM using ~20 GB VRAM when model loaded
```

## Usage

### Service Management

```bash
sudo systemctl start vllm       # Start the server
sudo systemctl stop vllm        # Stop (frees VRAM)
sudo systemctl restart vllm     # Restart (reload model)
sudo systemctl status vllm      # Check status
journalctl -u vllm -f           # Live logs

sudo systemctl start imagegen   # Start image gen
sudo systemctl stop imagegen    # Stop image gen
journalctl -u imagegen -f       # Image gen logs
```

### Switching Models

vLLM loads one model at a time (unlike Ollama's hot-swap). Mistral-Small-3.2 (`vllm.service`) is the
standing default; the specialist modes are templated `vllm@<mode>.service` instances (config in
`/etc/vllm/modes/<mode>.env`) plus `imagegen.service`. Use the switch CLI:

```bash
cachyos-switch-model mistral     # Mistral-Small-3.2 24B (default: basic chat / general)
cachyos-switch-model coder       # Qwen3-Coder 30B-A3B (coding + office docs)
cachyos-switch-model coder-alt   # Devstral-2 24B (dense agentic-SWE coder / review)
cachyos-switch-model image       # HiDream image gen + Qwen3 companion
```

The switch CLI stops the other modes first (one model owns the 24 GB card), and is passwordless via a
sudoers drop-in so the client launchers can flip modes over SSH. To change the model *within* a mode,
edit its env-file (e.g. `sudo nano /etc/vllm/modes/coder.env`) and re-run the switch, or
`sudo systemctl edit vllm` for the Mistral default.

### Client Connection

Any machine on the LAN can connect using OpenAI-compatible clients:

**Crush (on Windows desktop or laptop):**
```json
{
  "providers": {
    "server": {
      "kind": "openai",
      "baseURL": "http://server-ip:8000/v1",
      "apiKey": "unused"
    }
  }
}
```

**Copilot CLI:**
```bash
COPILOT_PROVIDER_BASE_URL=http://server-ip:8000/v1 copilot-local
```

**Python:**
```python
from openai import OpenAI
client = OpenAI(base_url="http://server-ip:8000/v1", api_key="unused")
response = client.chat.completions.create(
    model="mistral-small",
    messages=[{"role": "user", "content": "Hello"}]
)
```

**Image Generation (from any client):**
```python
from openai import OpenAI
client = OpenAI(base_url="http://server-ip:8001/v1", api_key="unused")
response = client.images.generate(
    model="hidream-o1",
    prompt="a glowing fox in a forest, detailed",
    size="1024x1024",
    n=1,
    response_format="b64_json"
)
# Decode: base64.b64decode(response.data[0].b64_json)
```

Or with curl:
```bash
curl http://server-ip:8001/v1/images/generations \
  -H "Content-Type: application/json" \
  -d '{"prompt":"a red fox in snow","size":"1024x1024","n":1}'
```

### Monitoring

```bash
nvidia-smi                       # GPU VRAM usage
nvidia-smi -l 1                  # Continuous monitoring
curl http://localhost:8000/metrics # vLLM Prometheus metrics
journalctl -u vllm -f            # Live server logs
```

### Multi-User Capacity (RTX 4090, 24GB)

| Model | Concurrent Users | Context per User |
|-------|-----------------|-----------------|
| Mistral-Small-3.2 24B (default) | 3-5 | ~12k tokens each |
| Qwen3-Coder 30B-A3B | 2-4 | ~10k tokens each |
| Devstral-2 24B (dense) | 2-3 | ~10k tokens each |

PagedAttention dynamically allocates VRAM — actual capacity depends on conversation length.

## Docker Containers (Coexistence)

Existing containers (Pi-hole, Cloudflared, Plex, Samba) have **zero impact** on AI inference:

| Resource | Containers | vLLM | Conflict? |
|----------|-----------|------|-----------|
| GPU VRAM | 0 GB | 14-22 GB | ❌ None |
| System RAM | ~4-10 GB of 64 GB | Minimal | ❌ Ample |
| CPU | Negligible | Negligible (GPU-bound) | ❌ None |

Plex hardware transcoding uses NVENC (dedicated silicon) — runs simultaneously with inference.

## Uninstall

```bash
./remove-cachyos.sh                  # Full removal
./remove-cachyos.sh --keep-models    # Keep HuggingFace model cache
./remove-cachyos.sh --install client # Client-only removal
```

## Troubleshooting

### vLLM won't start

```bash
sudo systemctl status vllm
journalctl -u vllm -n 50 --no-pager
nvidia-smi
```

Common causes:
- CUDA version mismatch (need CUDA 12.1+)
- Model not downloaded (`huggingface-cli download` first)
- Insufficient VRAM for the selected model

### Out of VRAM

```bash
# Check usage
nvidia-smi

# Switch to a lighter/faster mode (e.g. Devstral-2 24B is ~14 GB)
cachyos-switch-model coder-alt
# ...or reduce context on the Mistral default
sudo systemctl edit vllm
# VLLM_MAX_MODEL_LEN=16384
sudo systemctl restart vllm

# Or reduce context length
# VLLM_MAX_MODEL_LEN=16384
```

### Remote clients can't connect

```bash
sudo systemctl status vllm       # Is it running?
sudo ufw status                  # Is port 8000 allowed?
curl http://localhost:8000/v1/models  # Works locally?
```

Common causes:
- vLLM bound to `127.0.0.1` instead of `0.0.0.0`
- Firewall blocking port 8000 or 8001
- Wrong IP/port on client side

### Image gen slow or OOM

Image generation temporarily spikes VRAM (~16GB for HiDream-O1). If vLLM is using most VRAM:

```bash
# Option 1: Reduce vLLM memory further
sudo systemctl edit vllm
# VLLM_GPU_MEMORY_UTILIZATION=0.40
sudo systemctl restart vllm

# Option 2: Stop image gen when not needed
sudo systemctl stop imagegen
```

The image gen service uses SGLang's LayerwiseOffload — VRAM is managed efficiently but both services share the GPU. Default config (`gpu_memory_utilization=0.50`) reserves ~12GB for image gen.
