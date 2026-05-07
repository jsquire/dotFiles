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
| **Crush** | Terminal AI agent with MCP | pacman or user-local |
| **uv** | Python toolchain (MCP venvs) | Official installer |
| **copilot-local** | Task picker launcher | `~/.local/bin/` |
| **MCP servers** | Office document editing | Isolated Python venvs |

### Models (HuggingFace GPTQ-Int4, ~57 GB disk)

| Model | HuggingFace ID | Size | Task |
|-------|---------------|------|------|
| Qwen2.5-Coder 32B | `Qwen/Qwen2.5-Coder-32B-Instruct-GPTQ-Int4` | ~18 GB | Heavy coding |
| Qwen2.5-Coder 14B | `Qwen/Qwen2.5-Coder-14B-Instruct-GPTQ-Int4` | ~8 GB | Light coding |
| DeepSeek-R1 32B | `deepseek-ai/DeepSeek-R1-Distill-Qwen-32B-GPTQ-Int4` | ~18 GB | Code review, reasoning |
| Mistral Small 3.2 | `mistralai/Mistral-Small-3.2-24B-Instruct-2503-GPTQ-Int4` | ~13 GB | Tech docs, creative, Office |

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
- Allow `192.168.0.0/16` → TCP 8000
- Deny external access to TCP 8000

## Test the Installation

```bash
# 1. vLLM service is running
sudo systemctl status vllm

# 2. API responds
curl http://localhost:8000/v1/models
# Expected: JSON listing the loaded model

# 3. Inference works
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen2.5-Coder-32B-Instruct-GPTQ-Int4","messages":[{"role":"user","content":"Say hello"}]}'
# Expected: JSON with a greeting

# 4. Remote access (from another machine)
curl http://server-ip:8000/v1/models
# Expected: same model list

# 5. Crush connects
crush run "Say hello"

# 6. GPU is being used
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
- Firewall blocking port 8000
- Wrong IP/port on client side
