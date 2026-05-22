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

### Models (HuggingFace GPTQ-Int4, ~58 GB disk + ~12 GB image gen)

> **Note:** This vLLM profile temporarily uses Qwen3-Coder + Mistral Small because stable vLLM doesn't yet support GLM-4.7-Flash's architecture (`Glm4MoeLiteForCausalLM`). The Ollama-based Desktop/Server profiles already use GLM-4.7-Flash for coding + docs roles. When stable vLLM adds GLM support, this profile will align.

| Model | HuggingFace ID | Size | Task |
|-------|---------------|------|------|
| Qwen3-Coder 30B MoE | `btbtyler09/Qwen3-Coder-30B-A3B-Instruct-gptq-4bit` | ~19 GB | Heavy coding (agentic) |
| Qwen2.5-Coder 14B | `Qwen/Qwen2.5-Coder-14B-Instruct-GPTQ-Int4` | ~8 GB | Light coding |
| DeepSeek-R1 32B | `deepseek-ai/DeepSeek-R1-Distill-Qwen-32B-GPTQ-Int4` | ~18 GB | Code review, reasoning |
| Mistral Small 3.2 | `mistralai/Mistral-Small-3.2-24B-Instruct-2503-GPTQ-Int4` | ~13 GB | Tech docs, creative, Office |
| HiDream-O1-Image-Dev | `HiDream-ai/HiDream-O1-Image-Dev` | ~35 GB | Image generation (custom pipeline) |

## Install

```bash
cd ~/dotFiles/local-llm/cachyos
chmod +x install-cachyos.sh

# Server install (default for CachyOS)
./install-cachyos.sh --mode server

# Skip model downloads (install software first)
./install-cachyos.sh --mode server --skip-models

# Custom model storage path
./install-cachyos.sh --mode server --model-path /srv/models
```

### Install Options

| Flag | Effect |
|------|--------|
| `--mode server` | Full vLLM server (default on CachyOS) |
| `--mode client` | Client-only (Crush + MCP, no inference) |
| `--skip-models` | Install software only |
| `--models-only` | Download models only |
| `--model-path /path` | Custom HuggingFace cache location |
| `--ollama-host URL` | Remote endpoint (client mode) |

## Configure

### vLLM Server

The installer creates a systemd service. Configuration via environment in the override file:

```bash
# /etc/systemd/system/vllm.service.d/override.conf
[Service]
Environment="VLLM_MODEL=Qwen/Qwen2.5-Coder-32B-Instruct-GPTQ-Int4"
Environment="VLLM_HOST=0.0.0.0"
Environment="VLLM_PORT=8000"
Environment="VLLM_MAX_MODEL_LEN=32768"
Environment="VLLM_GPU_MEMORY_UTILIZATION=0.90"
```

Switch the active model:
```bash
# Edit the override
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
  -d '{"model":"btbtyler09/Qwen3-Coder-30B-A3B-Instruct-gptq-4bit","messages":[{"role":"user","content":"Say hello"}]}'
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

vLLM loads one model at a time (unlike Ollama's hot-swap). To switch:

```bash
# Edit the service to use a different model
sudo systemctl edit vllm
# Change: Environment="VLLM_MODEL=Qwen/Qwen2.5-Coder-14B-Instruct-GPTQ-Int4"
sudo systemctl restart vllm
```

For faster switching, you can run multiple vLLM instances on different ports (if VRAM allows):
```bash
# Small model on port 8001 (uses ~10 GB VRAM)
vllm serve Qwen/Qwen2.5-Coder-14B-Instruct-GPTQ-Int4 \
  --host 0.0.0.0 --port 8001 --gpu-memory-utilization 0.4
```

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
    model="Qwen/Qwen2.5-Coder-32B-Instruct-GPTQ-Int4",
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
| Qwen2.5-Coder 32B | 2-3 | ~8k tokens each |
| Qwen2.5-Coder 14B | 4-6 | ~16k tokens each |
| Mistral Small 3.2 | 3-4 | ~12k tokens each |

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
./remove-cachyos.sh               # Full removal
./remove-cachyos.sh --keep-models # Keep HuggingFace model cache
./remove-cachyos.sh --mode client # Client-only removal
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

# Switch to smaller model
sudo systemctl edit vllm
# VLLM_MODEL=Qwen/Qwen2.5-Coder-14B-Instruct-GPTQ-Int4
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
