# RTX 5090 Model Evaluation Plan

## Purpose

This is a standalone prompt/plan for evaluating model options after upgrading the
Windows workstation GPU from RTX 4090 (24 GB) to RTX 5090 (32 GB). The additional
8 GB VRAM unlocks models and context lengths that don't fit on the 4090.

Any model change validated here applies to **both** the local Windows workstation
and the CachyOS server profile (which also runs an RTX 4090 today and may be
upgraded in the future).

---

## Current State (Pre-Upgrade Baseline)

### Hardware
| Host | GPU | VRAM | Role |
|------|-----|------|------|
| Windows workstation | RTX 4090 → **RTX 5090** | 24 GB → **32 GB** | Desktop, primary dev |
| CachyOS server (squire) | RTX 4090 | 24 GB | Headless inference server |

### Software Stack
- **Backend**: Ollama (with vendored llama.cpp)
- **Frontend**: Crush CLI (task profiles), Copilot CLI (legacy scripts)
- **MCP servers**: docx-mcp-server (Word), ppt-mcp (PowerPoint), HiDream-O1 (image gen)
- **Env vars**: `OLLAMA_FLASH_ATTENTION=1`, `OLLAMA_KV_CACHE_TYPE=q8_0`

### Current Model Set
| Model | Role | Ollama Tag | Custom Model | num_ctx | Measured VRAM | GPU % |
|-------|------|-----------|-------------|---------|---------------|-------|
| Gemma 4 26B (MoE, 3.8B active) | Primary (all tasks) | gemma4:26b | gemma4-65k | 65536 | ~21 GB | 100% |
| Qwen3 14B | Image gen only | qwen3:14b | — | 8192 | ~9 GB | 100% |

### Task Profiles (from crush-task.ps1 / crush-task.sh)
| Profile | MCP Tools | Tool Token Overhead | Typical Session | Key Capability |
|---------|-----------|--------------------|--------------------|----------------|
| Coding | None | 0 | 30-60K tokens (long refactors) | Reasoning, code gen |
| Word | 54 tools | ~5K | 10-30K tokens | Tool calling accuracy |
| PowerPoint | 37 tools (short desc) | ~3K | 10-20K tokens | Tool calling accuracy |
| Image gen | HiDream MCP | ~1K | 4-8K tokens | N/A (uses qwen3:14b) |
| All tools | 93 tools | ~10-15K | Up to 50K tokens | Tool calling + reasoning |

### Config Files That Change on Model Switch
- `config/crush.json` — template (models.large, provider model lists)
- `~/.config/crush/crush.json` — live config
- `scripts/crush-task.ps1` — `$DefaultModel` variable (line 26)
- `scripts/crush-task.sh` — `DEFAULT_MODEL` variable (line 55)
- `scripts/copilot-local.cmd` — ~22 model references
- `scripts/copilot-local.sh` — ~20 model references
- `scripts/imagegen-launch.ps1` — default model (line 3)
- `windows/install-windows.ps1` — model descriptions, profiles, num_ctx mapping
- `cachyos/install-cachyos.sh` — SELECTED_MODELS, num_ctx mapping, descriptions

---

## RTX 5090 VRAM Budget

| Host | VRAM Total | Baseline Overhead | Available for Model |
|------|-----------|-------------------|---------------------|
| Windows workstation (5090) | 32,768 MiB (~32 GB) | ~2 GB (compositor + Ollama) | **~30 GB** |
| CachyOS server (4090, unchanged) | 24,564 MiB (~24 GB) | ~0.5-1 GB | **~23.5 GB** |

**Critical constraint**: Any model chosen must also work on the CachyOS 4090 server.
If a model only fits on 5090, it can only be the Windows-local model, and the server
must keep Gemma 4 26B or another 4090-compatible model. This creates a split
configuration that should be avoided unless the quality gain is substantial.

---

## Candidate Models to Evaluate

Models are sorted by priority. All sizes are Ollama Q4_K_M unless noted.

### Tier 1: Models Unlocked by 5090 (didn't fit on 4090)

| Model | Arch | Total/Active | Ollama Size | Published Benchmarks | Why Test |
|-------|------|-------------|-------------|---------------------|----------|
| **Qwen3.5-35B-A3B** | MoE | 35B/3B | 24 GB | BFCL 67.3%, LiveCode 74.6%, GPQA 84.2%, **TAU2 81.2%** | Highest agentic score; didn't fit on 4090 |
| **Gemma 4 31B** | Dense | 31B/31B | 20 GB | LiveCode 80.0%, GPQA 84.3%, TAU2 76.9% | Dense reasoning powerhouse |
| **Qwen3.5-27B** | Hybrid | 27B/27B | 17 GB | **BFCL 68.5%**, **LiveCode 80.7%**, **GPQA 85.5%**, TAU2 79.0% | Best benchmarks, now fits 100% GPU |
| **Qwen3.5-27B at 128K ctx** | Hybrid | 27B/27B | 17 GB | Same | Same model, double context for long sessions |

### Tier 2: Revalidate with Headroom

| Model | Arch | Total/Active | Ollama Size | Why Test |
|-------|------|-------------|-------------|----------|
| **GPT-OSS 20B** | MoE | 21B/3.6B | 14 GB | Most VRAM-efficient; could run 256K context |
| **Gemma 4 26B at 128K** | MoE | 25B/3.8B | 18 GB | Current model with doubled context window |

### Tier 3: If New Models Have Appeared
At the time of this evaluation, check:
- `ollama.com/library` for any new 30-50B models
- HuggingFace trending models in the 30-50B range
- r/LocalLLaMA top posts from the last 2 months
- Any new Qwen, Gemma, GPT-OSS, or Mistral releases

---

## VRAM Fit Projections (5090, 30 GB available)

| Model | Weights | KV@65K q8_0 | Total@65K | Fits 5090? | KV@128K q8_0 | Total@128K | Fits? | KV@256K | Total@256K | Fits? |
|-------|---------|-------------|-----------|-----------|-------------|-----------|-------|---------|-----------|-------|
| Qwen3.5-35B-A3B | 24 GB | ~1-2 GB | ~25-26 GB | ✅ +4 GB | ~3-4 GB | ~27-28 GB | ✅ +2 GB | ~6-8 GB | ~30-32 GB | ⚠️ |
| Gemma 4 31B | 20 GB | ~6-8 GB* | ~26-28 GB | ✅ ~2 GB | ~12-16 GB | ~32-36 GB | ❌ | — | — | ❌ |
| Qwen3.5-27B | 17 GB | ~2.3 GB | ~19 GB | ✅✅ +11 GB | ~4.3 GB | ~21 GB | ✅✅ | ~8 GB | ~25 GB | ✅ +5 GB |
| GPT-OSS 20B | 14 GB | ~1 GB | ~15 GB | ✅✅ +15 GB | ~2 GB | ~16 GB | ✅✅ | ~4 GB | ~18 GB | ✅✅ |
| Gemma 4 26B | 18 GB | ~2 GB | ~20 GB | ✅✅ +10 GB | ~4 GB | ~22 GB | ✅✅ | ~8 GB | ~26 GB | ✅ +4 GB |

\* Gemma 4 31B is dense with ~31B params, so full KV cache per layer.
Note: Qwen3.5-27B has hybrid attention (16/64 full attention layers), so KV cache is
~25% of a traditional dense model. Qwen3.5-35B-A3B is MoE with small active params.

### Cross-Host Compatibility Check

| Model | Fits 5090 (30 GB) @65K | Fits 4090 (23.5 GB) @65K | Both Hosts? |
|-------|----------------------|------------------------|-------------|
| Qwen3.5-35B-A3B | ✅ | ❌ (24 GB weights alone) | ❌ Windows-only |
| Gemma 4 31B | ✅ | ❌ (26-28 GB total) | ❌ Windows-only |
| Qwen3.5-27B | ✅✅ | ⚠️ 28 GB measured, 16% CPU spill | ❌ Windows-only* |
| GPT-OSS 20B | ✅✅ | ✅✅ | ✅ Both |
| Gemma 4 26B | ✅✅ | ✅ (verified 100% GPU) | ✅ Both |

\* Qwen3.5-27B was measured at 28 GB loaded / 16% CPU on RTX 4090 (May 2026). Ollama
may not optimize the hybrid attention KV cache, allocating more than theoretically needed.
**Re-measure on the 5090** — it should fit 100% GPU with 32 GB VRAM.

---

## Evaluation Procedure

### Prerequisites
1. RTX 5090 installed and verified (`nvidia-smi` shows 32 GB)
2. Ollama updated to latest version
3. Env vars confirmed: `OLLAMA_FLASH_ATTENTION=1`, `OLLAMA_KV_CACHE_TYPE=q8_0`
4. Benchmark fixtures available in `D:\scratch\copilot-localllm\`:
   - `bench-test2-buggy.py` (bug fix test)
   - `bench-test3-complex.py` (code explanation test)
   - `bench-run.py` (automated benchmark runner)

### Step 1: Baseline Measurement
```powershell
# Confirm 5090 VRAM and baseline load
nvidia-smi --query-gpu=name,memory.total,memory.used,memory.free --format=csv,noheader
# Confirm Gemma 4 26B still works (regression check)
ollama run gemma4-65k "Say hello"
ollama ps
nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits
```

### Step 2: Pull Candidate Models
```powershell
ollama pull qwen3.5:27b    # 17 GB — Tier 1 priority
ollama pull qwen3.5:35b    # 24 GB — Tier 1, 5090-only
ollama pull gemma4:31b     # 20 GB — Tier 1, 5090-only
ollama pull gpt-oss:20b    # 14 GB — Tier 2
```

### Step 3: Create Custom Models with Context Windows
For each candidate, create custom models at multiple context levels:
```powershell
# Example for qwen3.5:27b
echo "FROM qwen3.5:27b`nPARAMETER num_ctx 65536" | Set-Content Modelfile-tmp
ollama create qwen35-65k -f Modelfile-tmp

echo "FROM qwen3.5:27b`nPARAMETER num_ctx 131072" | Set-Content Modelfile-tmp
ollama create qwen35-128k -f Modelfile-tmp

# Repeat for each candidate at 65K and 128K (and 256K where viable)
```

### Step 4: VRAM and GPU Fit Measurement
For each custom model:
```powershell
ollama stop <previous-model>
Start-Sleep 5
# Get baseline
nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits

# Load model
ollama run <model-name> "What is 2+2?"

# Measure
ollama ps    # Shows SIZE, PROCESSOR (CPU/GPU split), CONTEXT
nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader,nounits
```

**Record this data for every model:**
| Model | num_ctx | Ollama SIZE | CPU/GPU Split | nvidia-smi Used | nvidia-smi Free |
|-------|---------|-------------|---------------|-----------------|-----------------|
| (fill in) | | | | | |

**Pass/fail criteria:**
- ✅ PASS: 100% GPU (0% CPU) — no spill
- ⚠️ MARGINAL: ≤10% CPU — slight spill, may be acceptable
- ❌ FAIL: >10% CPU — too much spill, will degrade generation speed

### Step 5: Benchmark Suite
Update `bench-run.py` MODELS list to include candidates that passed Step 4:
```python
MODELS = ["gemma4-65k", "qwen35-65k", "qwen35-128k", ...]  # add passing models
```

**Important for Qwen3.5 models**: The benchmark script must set `"think": False` in
the API payload to disable chain-of-thought reasoning. This is already implemented
in bench-run.py (checks for `"qwen3" in model`).

Run benchmarks:
```powershell
cd D:\scratch\copilot-localllm
python bench-run.py
```

**Record for each model:**
| Model | Test 1 (codegen) tok/s | Test 2 (bugfix) tok/s | Test 3 (explain) tok/s | Avg tok/s | Prompt tok/s |
|-------|----------------------|---------------------|---------------------|-----------|-------------|
| (fill in) | | | | | |

### Step 6: Tool Calling Validation
For each candidate that passes speed threshold (≥20 tok/s average):
1. Create a `.crush.json` with the model name
2. Run Crush with the coding profile — verify it generates correct tool calls
3. Run Crush with the Word profile — verify it calls docx-mcp-server tools correctly
4. Run Crush with the PPTX profile — verify it calls ppt-mcp tools correctly

### Step 7: Long Session Test
For the top 1-2 candidates:
1. Start a Crush coding session
2. Have a 10+ turn conversation about a real codebase
3. Monitor for compaction events (Crush logs "compacting context" messages)
4. Note when/if context fills up

---

## Decision Framework

### Speed Threshold
Based on our experience:
- **>50 tok/s**: Excellent — feels instant (Gemma 4 26B baseline)
- **20-50 tok/s**: Good — acceptable for interactive use
- **10-20 tok/s**: Marginal — noticeable lag, tolerable for high-quality output
- **<10 tok/s**: Unacceptable — too slow for interactive coding sessions

### Scoring Matrix (weight × score)

| Criterion | Weight | How to Score |
|-----------|--------|-------------|
| Generation speed (tok/s) | 25% | >50=5, 35-50=4, 20-35=3, 10-20=2, <10=1 |
| Coding quality (response correctness) | 25% | Judge from benchmark responses |
| Tool calling accuracy | 20% | Pass/fail from Step 6 |
| VRAM fit (100% GPU) | 15% | 100%=5, 95%=4, 90%=3, <90%=1 |
| Context window achievable | 10% | 256K=5, 128K=4, 65K=3, 32K=2 |
| License | 5% | Apache 2.0=5, Gemma ToU=3, restrictive=1 |

### Decision Paths

**Path A: Single model, both hosts**
Best outcome. The chosen model must fit 100% GPU on BOTH the 5090 (Windows) and 4090
(CachyOS). Models eligible: Gemma 4 26B, GPT-OSS 20B, and any future MoE ≤19 GB.

If a cross-host model wins, update:
- `crush-task.ps1` `$DefaultModel` (line 26)
- `crush-task.sh` `DEFAULT_MODEL` (line 55)
- `config/crush.json` models.large
- `copilot-local.cmd` and `copilot-local.sh` (all model references)
- `install-windows.ps1` and `install-cachyos.sh` (model profiles, descriptions)
- Create custom Ollama model with Modelfile on both hosts
- Deploy updated scripts to `C:\Users\Jesse\Documents\CLI\` (Windows)

**Path B: Split configuration (5090 model ≠ 4090 model)**
If a 5090-only model (Qwen3.5-35B, Gemma 4 31B, Qwen3.5-27B) is substantially better:
- Windows workstation uses the 5090 model
- CachyOS server keeps Gemma 4 26B (or other 4090-compatible model)
- `crush.json` squire-server provider keeps its own model list
- `install-windows.ps1` and `install-cachyos.sh` diverge on model selection
- `crush-task.ps1` sets `$DefaultModel` to the 5090 model
- `crush-task.sh` sets `DEFAULT_MODEL` to the 4090 model
- Complexity cost: two model configs to maintain

**Path C: Keep Gemma 4 26B, just increase context**
If no candidate beats Gemma 4 on the scoring matrix, use the extra 5090 VRAM for
a larger context window (128K or 256K) instead of a different model:
- Create `gemma4-128k` custom model (FROM gemma4:26b, PARAMETER num_ctx 131072)
- Estimated VRAM at 128K: ~22 GB (fits easily in 30 GB)
- Update `crush-task.ps1` to use `gemma4-128k` for coding profile
- Keep `gemma4-65k` for tool-heavy profiles (context is sufficient at 65K)

---

## Reference Data from RTX 4090 Evaluations (May 2026)

### Gemma 4 26B (Current Primary) — Measured on RTX 4090

| Metric | Value |
|--------|-------|
| VRAM loaded (65K ctx) | ~21 GB, 100% GPU |
| Gen speed (avg) | 54-91 tok/s |
| Prompt processing | 1760-4174 tok/s |
| Coding score (bench-run.py) | 14/15 |
| Bug fix test | Completed in 70s |
| Tool calling | ✅ Correct formatting |

### Qwen3.5-27B — Measured on RTX 4090

| Metric | Value |
|--------|-------|
| VRAM loaded (65K ctx) | 28 GB total, 16% CPU / 84% GPU (spills) |
| nvidia-smi used | 23,315 MiB (737 MiB free) |
| Gen speed (avg) | 11.5-12.5 tok/s (with think=false) |
| Prompt processing | 342-880 tok/s |
| Coding output | Concise, correct, fewer tokens than Gemma 4 |
| Bug fix test | Completed in 21.5s (but only 241 tokens — very terse) |

**Key takeaway**: On RTX 4090, Qwen3.5-27B spills 16% to CPU and runs at only
~12 tok/s — below the 20 tok/s minimum threshold. On RTX 5090 with 30 GB
available, it should fit 100% GPU and run significantly faster. **Re-measuring
speed on 5090 is critical.**

### GLM-4.7-Flash — Retired, Reference Only

| Metric | Value |
|--------|-------|
| Gen speed | 17.3 tok/s (with q8_0 KV fix) |
| VRAM (65K ctx) | ~23 GB, 89% GPU (after KV cache fix) |
| Coding score | 10/15 |
| Bug fix test | Timed out at 180s |
| Retired because | Slower, lower quality, larger VRAM than Gemma 4 |

### Published Benchmark Comparison

| Model | BFCL-V4 (Tools) | LiveCode v6 (Coding) | GPQA (Reasoning) | TAU2 (Agentic) |
|-------|----------------|---------------------|-----------------|----------------|
| Qwen3.5-27B | **68.5%** | **80.7%** | **85.5%** | 79.0% |
| Qwen3.5-35B-A3B | 67.3% | 74.6% | 84.2% | **81.2%** |
| Gemma 4 26B | N/A | 77.1% | 82.3% | 68.2% |
| Gemma 4 31B | N/A | 80.0% | 84.3% | 76.9% |
| GPT-OSS 20B | N/A | N/A | N/A | N/A |

Sources: Qwen model card (HuggingFace), Google Gemma 4 tech report, OpenAI GPT-OSS
model card. Community sentiment from r/LocalLLaMA (722K members).

---

## Architecture Notes

### Qwen3.5-27B Hybrid Attention
From `Qwen/Qwen3.5-27B/config.json` (HuggingFace):
- 64 layers, `full_attention_interval: 4`
- 16 full attention layers (standard KV cache per token)
- 48 linear attention layers (fixed-size state, Mamba-like)
- Theoretical KV cache ~25% of a standard dense 27B model
- **However**: Ollama (May 2026) allocated 28 GB total on RTX 4090 — more than the
  theoretical ~19 GB. This suggests Ollama may not optimize linear attention KV
  allocation. Check if newer Ollama versions have improved this.

### GPT-OSS 20B MXFP4 Quantization
- OpenAI trained the model with MXFP4 quantization built into the training process
- Not a post-hoc quantization — quality should be higher than standard Q4_K_M
- Ollama supports MXFP4 natively via custom kernels
- MoE architecture: 21B total, 3.6B active — similar efficiency to Gemma 4 26B

### Ollama Environment
Ensure these are set before any evaluation:
```powershell
# Check
[System.Environment]::GetEnvironmentVariable("OLLAMA_FLASH_ATTENTION", "User")
[System.Environment]::GetEnvironmentVariable("OLLAMA_KV_CACHE_TYPE", "User")

# If not set:
[System.Environment]::SetEnvironmentVariable("OLLAMA_FLASH_ATTENTION", "1", "User")
[System.Environment]::SetEnvironmentVariable("OLLAMA_KV_CACHE_TYPE", "q8_0", "User")
# Then restart Ollama
```

---

## Checklist

- [ ] RTX 5090 installed, nvidia-smi confirms 32 GB
- [ ] Ollama updated to latest
- [ ] Env vars confirmed (OLLAMA_FLASH_ATTENTION=1, OLLAMA_KV_CACHE_TYPE=q8_0)
- [ ] Baseline VRAM measured (no model loaded)
- [ ] Gemma 4 26B regression check passed
- [ ] Pulled: qwen3.5:27b, qwen3.5:35b, gemma4:31b, gpt-oss:20b
- [ ] Created custom models at 65K, 128K, 256K where viable
- [ ] VRAM measurements recorded for all candidates
- [ ] bench-run.py executed with passing candidates
- [ ] Tool calling validated in Crush for top candidates
- [ ] Long session test completed for top 1-2 candidates
- [ ] Decision made (Path A, B, or C)
- [ ] Config files updated per decision path
- [ ] Scripts deployed to C:\Users\Jesse\Documents\CLI\
- [ ] CachyOS server updated if applicable (Path A only)
