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

**Resolved constraint**: Same model on both hosts (Qwen3.6-27B), different backends
and context limits. Windows 5090 (Ollama, 128K) and CachyOS 4090 (vLLM, 32K, FP8 KV).
This avoids split-model complexity while respecting VRAM differences.

---

## Model Decision (May 2026 Research — Finalized)

### Selected Model: **Qwen3.6-27B** (both hosts)

Based on comprehensive evaluation of all candidates against published benchmarks,
community sentiment, and VRAM constraints.

#### Why Qwen3.6-27B Wins

| Metric | Qwen3.6-27B | Qwen3.5-27B | Gemma 4 26B (current) | Source |
|--------|-------------|-------------|----------------------|--------|
| LiveCodeBench v6 | **83.9%** | 80.7% | 77.1% | Alibaba blog, Google tech report |
| SWE-bench Verified | **77.2%** | 75.0% | N/A | HuggingFace model card |
| Terminal-Bench 2.0 | **59.3%** | N/A | N/A | Alibaba blog |
| C# community sentiment | "Senior developer feel" | "Surprisingly good" | "Compiles, occasional hallucination" | r/LocalLLaMA May 2026 |
| Tool calling | "Robust slot filling, context carryover" | Published BFCL 68.5% | Adequate (no published score) | Community reviews |
| Architecture | Dense 27B, GQA (8 KV heads) | Hybrid 27B | MoE 3.8B active | config.json |
| Context window | **262K native** | 128K | 256K | Model card |
| License | Apache 2.0 | Apache 2.0 | Gemma ToU | — |

#### Eliminated Candidates (Data-Based)

| Model | Reason | Data |
|-------|--------|------|
| **GPT-OSS 20B** | "So censored it's unusable" — coding refusals on innocuous prompts | r/LocalLLaMA, YouTube reviews |
| **LFM2-24B-A2B** | 32K context max — cannot hold 60K+ coding sessions | Architecture limit |
| **Gemma 4 31B** | Only fits at 65K on 5090, no 128K path, slowest (25 t/s), tight VRAM | VRAM math, benchmarks |
| **Qwen3.5-35B-A3B** | Superseded by Qwen3.6-35B-A3B; LiveCode only 74.6% (below current 77.1%) | Benchmark comparison |
| **Qwen3.6-35B-A3B** | 30-38GB VRAM at 128K — exceeds 5090's 30GB available | VRAM projections |
| **Gemma 4 26B @ 128K** | Viable fallback but +6.8% LiveCode improvement from Qwen3.6-27B justifies switch | Benchmark delta |

#### Deployment Configuration

| Host | Backend | Model | Context | GPU Util | KV Cache | VRAM Budget |
|------|---------|-------|---------|----------|----------|-------------|
| **Windows 5090 (32 GB)** | Ollama | qwen3.6:27b | **128K** | 100% | q8_0 | ~21-24 GB / 30 GB |
| **CachyOS 4090 (24 GB)** | vLLM | Qwen3.6-27B-Instruct-GPTQ-Int4 | **32K** | 0.90 | **FP8 (fp8_e5m2)** | ~19 GB / 21.6 GB |

#### CachyOS 4090 Multi-User Math (2 concurrent users)

```
Architecture: 32 layers, 8 KV heads (GQA), head_dim 128
KV per token (FP8): 2 × 32 × 8 × 128 × 1 byte = 65,536 bytes/token

Per user @ 32K context: 65,536 × 32,768 = 2.0 GB
Two users @ 32K each: 4.0 GB KV total
Model weights (GPTQ-Int4): ~15 GB
Total: ~19 GB → fits in 21.6 GB (0.90 × 24 GB) with 2.6 GB headroom
```

FP8 KV cache impact (published data):
- Quality: < 1% accuracy loss on HumanEval/MBPP (arxiv.org/abs/2411.02355)
- Speed: ~5-8% slower on Ada Lovelace (software dequant, no native FP8 tensor cores)
- Memory: 50% KV reduction — enables 2-user concurrency that FP16 cannot support

#### Speed Projections (RTX 5090)

| Context | Estimated tok/s | Per-turn time (400 tok) | 30-turn session |
|---------|----------------|------------------------|-----------------|
| 32K | 35-40 t/s | ~10-11s | ~5 min |
| 65K | 28-35 t/s | ~12-14s | ~6 min |
| 128K | 25-30 t/s | ~13-16s | ~7 min |

Compared to current Gemma 4 26B on RTX 4090: ~54-91 tok/s (MoE advantage).
The 5090 with dense 27B will be slower per-token but higher quality per-turn.
User's stated preference: "80% quality + speed > marginally better per-turn quality"
→ Qwen3.6-27B at 83.9% LiveCode exceeds the quality bar; speed at 25-40 t/s is
in the "Good" range (interactive use, no perceptible lag for coding).

---

## Candidate Models (Historical — Evaluated May 2026)

Models sorted by priority. All sizes are Q4_K_M unless noted.

### Tier 1: Models Unlocked by 5090 (didn't fit on 4090)

| Model | Arch | Total/Active | Ollama Size | Published Benchmarks | Why Test |
|-------|------|-------------|-------------|---------------------|----------|
| **Qwen3.6-27B** ★ SELECTED | Dense | 27B/27B | 15-18 GB | **LiveCode 83.9%**, SWE-bench 77.2%, Terminal-Bench 59.3% | Best coding quality, 262K context |
| **Qwen3.5-35B-A3B** | MoE | 35B/3B | 24 GB | BFCL 67.3%, LiveCode 74.6%, GPQA 84.2%, TAU2 81.2% | Highest agentic score; didn't fit on 4090 |
| **Gemma 4 31B** | Dense | 31B/31B | 20 GB | LiveCode 80.0%, GPQA 84.3%, TAU2 76.9% | Dense reasoning powerhouse |
| **Qwen3.5-27B** | Hybrid | 27B/27B | 17 GB | BFCL 68.5%, LiveCode 80.7%, GPQA 85.5%, TAU2 79.0% | Best pre-3.6 benchmarks |
| **Qwen3.6-35B-A3B** | MoE | 35B/3B | 21 GB | LiveCode 80.4%, SWE-bench 73.4%, τ2 95.3% | Fast MoE but VRAM-constrained at 128K |

### Tier 2: Revalidate with Headroom

| Model | Arch | Total/Active | Ollama Size | Why Test |
|-------|------|-------------|-------------|----------|
| **GPT-OSS 20B** | MoE | 21B/3.6B | 14 GB | Most VRAM-efficient — ELIMINATED (censorship) |
| **Gemma 4 26B at 128K** | MoE | 25B/3.8B | 18 GB | Current model with doubled context window |
| **LFM2-24B-A2B** | Hybrid MoE | 24B/2B | 13 GB | Fast — ELIMINATED (32K context limit) |

### Arena Leaderboard Context (May 22, 2026)

| Rank | Model | Score | Relevance |
|------|-------|-------|-----------|
| 9 | Gemma 4 31B | 1058.1 | Evaluated — VRAM-constrained on 5090 at 128K |
| 17 | Qwen3.6 35B A3B | 940.0 | Evaluated — VRAM-constrained at 128K |
| 21 | LFM2-24B-A2B | 857.8 | Evaluated — 32K context limit eliminates it |

Note: Qwen3.6-27B not yet listed in arena (too new, April 2026 release)

---

## VRAM Fit Projections — Updated with Qwen3.6

### RTX 5090 (30 GB available, Ollama, q8_0 KV cache)

| Model | Weights | KV@65K | Total@65K | Fits? | KV@128K | Total@128K | Fits? |
|-------|---------|--------|-----------|-------|---------|-----------|-------|
| **Qwen3.6-27B** ★ | 15-18 GB | ~4 GB | ~19-22 GB | ✅✅ +8 GB | ~8 GB | ~23-26 GB | ✅ +4 GB |
| Qwen3.5-27B | 17 GB | ~2.3 GB | ~19 GB | ✅✅ +11 GB | ~4.3 GB | ~21 GB | ✅✅ |
| Gemma 4 26B | 18 GB | ~2 GB | ~20 GB | ✅✅ +10 GB | ~4 GB | ~22 GB | ✅✅ |
| Gemma 4 31B | 20 GB | ~6-8 GB | ~26-28 GB | ✅ ~2 GB | ~12-16 GB | ❌ | ❌ |

Note: Qwen3.6-27B is dense with GQA (8 KV heads / 56 query heads). KV cache is ~14%
of what a full 56-head model would need. Architecture from config.json: 32 layers,
num_key_value_heads=8, head_dim=128.

### RTX 4090 (24 GB, vLLM, GPTQ-Int4, FP8 KV cache)

| Model | Weights | KV@32K (FP8, 1 user) | Total (1 user) | KV@32K (FP8, 2 users) | Total (2 users) | Fits 0.90? |
|-------|---------|---------------------|----------------|----------------------|-----------------|------------|
| **Qwen3.6-27B** ★ | ~15 GB | 2.0 GB | ~17 GB | 4.0 GB | ~19 GB | ✅ +2.6 GB |
| Qwen3.5-27B | ~15 GB | ~1.2 GB | ~16 GB | ~2.4 GB | ~17 GB | ✅ +4.6 GB |
| Gemma 4 26B | ~15 GB | ~1.0 GB | ~16 GB | ~2.0 GB | ~17 GB | ✅ +4.6 GB |

FP8 KV math for Qwen3.6-27B: 2×32×8×128×1 byte = 65,536 bytes/token × 32K = 2.0 GB/user

### Cross-Host Compatibility (DECIDED: same model, different backends)

| Host | Backend | Model | Context | Multi-user | Notes |
|------|---------|-------|---------|------------|-------|
| Windows 5090 | Ollama | Qwen3.6-27B (GGUF Q4_K_M) | 128K | Single user | q8_0 KV cache, flash attention |
| CachyOS 4090 | vLLM | Qwen3.6-27B-Instruct-GPTQ-Int4 | 32K | 2 concurrent | FP8 KV, gpu-memory-utilization=0.90 |

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

### Selected Path: B+ (Same Model, Different Backends)

**Decision made May 22, 2026** — Qwen3.6-27B on both hosts, with backend-appropriate
optimizations:

- Windows 5090: Ollama (GGUF, 128K context, single user, q8_0 KV)
- CachyOS 4090: vLLM (GPTQ-Int4, 32K context, 2 concurrent users, FP8 KV)

This is superior to a split-model config because:
- Same model = same prompting behavior, same tool-calling format, same quirks
- Avoids maintaining two different model configurations
- Quality parity across hosts (83.9% LiveCode everywhere)
- Context difference (128K vs 32K) is acceptable — CachyOS serves office/review (10-25K typical)

### Speed Threshold (unchanged)
- **>50 tok/s**: Excellent — feels instant
- **20-50 tok/s**: Good — acceptable for interactive use ← **5090 target range**
- **10-20 tok/s**: Marginal — noticeable lag ← **4090 range (acceptable for server role)**
- **<10 tok/s**: Unacceptable

### Implementation Checklist (Post-5090 Arrival)

**Windows 5090 (Ollama):**
1. `ollama pull qwen3.6:27b`
2. Create custom model: `FROM qwen3.6:27b\nPARAMETER num_ctx 131072`
3. Update `crush-task.ps1` → `$DefaultModel = "qwen36-128k"`
4. Update `crush-task.sh` → `DEFAULT_MODEL="qwen36-128k"`
5. Update `config/crush.json` → models.large.model = "qwen36-128k"
6. Update `copilot-local.cmd` and `copilot-local.sh` model references
7. Update `install-windows.ps1` model profiles and descriptions
8. Run benchmark suite (bench-run.py) to validate speed/quality

**CachyOS 4090 (vLLM):**
1. Find/verify HuggingFace GPTQ-Int4 quant: `Qwen/Qwen3.6-27B-Instruct-GPTQ-Int4` (or community)
2. Update `install-cachyos.sh`:
   - `VLLM_DEFAULT_MODEL` → new HuggingFace model ID
   - `VLLM_GPU_MEMORY_UTILIZATION` → 0.90
   - `VLLM_MAX_MODEL_LEN` → 32768
   - Add `--kv-cache-dtype fp8_e5m2` to ExecStart
3. Update `config/crush.json` → squire-server model list
4. Update server model descriptions in `install-cachyos.sh`
5. Test: 2 concurrent requests at 32K context (verify no OOM)

**Validation criteria:**
- 5090: ≥25 tok/s at 128K context, 100% GPU, no CPU spill
- 4090: No OOM with 2×32K concurrent, ≥10 tok/s per user
- Both: Tool calling works with Crush (Word, PPTX, coding profiles)
- Both: bench-run.py scores ≥ current Gemma 4 26B baseline (14/15)

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
