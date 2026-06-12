# RTX 5090 Model Evaluation Plan

## Purpose

This is a standalone prompt/plan for evaluating model options after upgrading the
Windows workstation GPU from RTX 4090 (24 GB) to RTX 5090 (32 GB). The additional
8 GB VRAM unlocks models and context lengths that don't fit on the 4090.

Any model change validated here applies to **both** the local Windows workstation
and the CachyOS server profile (which also runs an RTX 4090 today and may be
upgraded in the future).

---

## ⚠️ STATUS / CORRECTIONS (2026-06) — READ FIRST

The "Finalized: Qwen3.6-27B on both hosts" decision below is **SUPERSEDED**. It also
contained a fabricated architecture description and some unverifiable benchmark math.
Current plan and corrections (authoritative sources flagged):

- **Deliverable for that round was a report**, not a single locked model. The 5090 has
  ~1TB of model storage, so it now runs a **side-by-side test bench** of contenders
  exposed through the launcher (`[H1]–[H5]`), not one finalized pick.
- **5090 task→model mapping (launchers):** heavy coding → `qwen36-27b-256k` (default,
  dense); light coding & review → `qwen3coder-256k`; general/office/all-tools →
  `glm47-flash-198k`; image companion → `qwen3:8b`.
- **CachyOS server default = GLM-4.7-Flash** (`QuantTrio/GLM-4.7-Flash-AWQ`, served as
  `glm-4.7-flash`), the standing all-rounder for coding + review + office MCP. vLLM
  serves one model at a time (24 GB), so a **mode switch** (`cachyos-switch-model`)
  loads coder / vision / image modes on demand. Image mode = HiDream (imagegen.service)
  + Qwen3-4B companion. **Minimize switching** — GLM covers everyday needs with no swap.
- **Client launchers mirror the server**: the `squire-server` provider / `[S][C][V][I]`
  entries derive their ids from the active `--served-model-name`, so they can't drift.
- **Qwen3.6-27B coding numbers ARE authoritative** (LiveCodeBench 83.9 / SWE-bench
  Verified 77.2 / Terminal-Bench2 59.3) — sourced from the HF model card via BenchLM's
  human-curated, provider-exact snapshot (`benchmarkProvenanceStatus: official`, 37/37
  verified). Only the *architecture* below was wrong (see next point).
- **Architecture CORRECTION (authoritative — HF config.json):** Qwen3.6-27B is **dense,
  hybrid linear + full attention, head_dim 256, hidden 5120, 262K → 1.01M context**.
  The earlier "dense GQA, 8 KV heads, head_dim 128" description was fabricated and the
  KV-cache math derived from it is unreliable. Treat all KV/VRAM figures below as
  **UNVERIFIED** until measured on the box.
- **Gemma 4 disappoints locally** in hands-on Crush + Copilot use (verified: the live
  default is a 3.8B-active MoE at temp 1, context capped at 65K/262K). It stays only as
  an optional `[H3]` bench slot (`gemma4-31b-128k`), not a default.
- **Image: keep HiDream-I1, do NOT adopt FLUX** — FLUX performed noticeably worse than
  HiDream in a prior hands-on install. Verify the deployed "HiDream-O1-Image-Dev"
  identity on the box.

Everything below this banner is retained as historical research/methodology; where it
conflicts with this banner, **this banner wins.**

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
| Architecture | Dense 27B, hybrid linear+full attn (head_dim 256) | Hybrid 27B | MoE 3.8B active | config.json |
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

Note: Qwen3.6-27B is dense with **hybrid linear + full attention** (head_dim 256,
hidden 5120, 262K → 1.01M native). The earlier "GQA, 8 KV heads, head_dim 128" claim
was fabricated; the KV figures in this table are **UNVERIFIED** until measured on the
box. Architecture from HF config.json: dense, hybrid attention, head_dim 256.

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

### Selected Path: 5090 multi-profile bench + GLM-4.7-Flash server (SUPERSEDES B+)

> The original "B+ (same model, Qwen3.6-27B on both hosts)" decision is superseded —
> see the corrections banner at the top. Current plan:

- **Windows 5090 (Ollama):** install all six contenders (~1TB storage) and expose them
  through the launcher profiles + `[H1]–[H5]` heavy-coding bench. Heavy-coding default =
  `qwen36-27b-256k` (dense, authoritative coding numbers); light/review =
  `qwen3coder-256k`; office/all-tools = `glm47-flash-198k`; image companion = `qwen3:8b`.
- **CachyOS 4090 (vLLM):** standing default = **GLM-4.7-Flash** (`glm-4.7-flash`), one
  all-rounder for coding + review + office MCP. `cachyos-switch-model {glm|coder|vision|
  image}` swaps modes on demand (24 GB holds one at a time). Image mode = HiDream +
  Qwen3-4B companion. Client `[S][C][V][I]` entries derive ids from the served name.
- **Rationale for not locking one model:** Gemma 4 disappointed in hands-on use, and the
  pre-3.6 Qwen benchmark numbers were unverifiable. The bench resolves quality by real
  use rather than picking blindly. Dense is a soft preference (offset by coding benches +
  community sentiment), which is why GLM-4.7-Flash (MoE-lite) is acceptable server-side.

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

## MoE Expert CPU Offload — run oversized MoE models (VERIFIED 2026-06)

Goal: keep attention/shared tensors + KV cache on the GPU but push a MoE model's **expert
FFN weights to system RAM**, so a model that does NOT fit in VRAM still runs at usable
speed. This raises the model-size ceiling and frees VRAM for larger context.

### Authoritative mechanism (llama.cpp)
- `--cpu-moe` / env `LLAMA_ARG_CPU_MOE=1` → all experts to CPU.
- `--n-cpu-moe N` / env `LLAMA_ARG_N_CPU_MOE=N` → first N layers' experts to CPU (partial).
- `-ot/--override-tensor <regex>=CPU` → manual control.
- Added in llama.cpp PR #15077 (maintainer slaren, merged 2025-08-04). **Ollama exposes no
  native param** (issue #11772 open since 2025-08; PR #16688 unreviewed).

### Verified on the 4090 test box (Ollama 0.30.7, RTX 4090 + DDR5-4800) — not speculation
- Ollama 0.30.7's runner **is upstream `llama-server.exe`** (serve log `source=llama_server.go`,
  `cmd="...llama-server.exe ... --no-mmap ..."`). It **inherits and honors `LLAMA_ARG_CPU_MOE`**
  from the serve environment. Ollama already injects `--no-mmap`; `GGML_CUDA_NO_PINNED=1` is
  passed through to avoid CUDA pinning the large CPU-resident experts.
- Measured, same model + same 32K ctx (`qwen3-coder:30b`, 30B-A3B MoE):

  | Mode | Model VRAM | nvidia-smi used | Eval rate |
  |------|-----------|-----------------|-----------|
  | Baseline (full GPU) | 20 GB | 23.2 GB | **190.7 tok/s** |
  | `LLAMA_ARG_CPU_MOE=1` (experts→CPU) | 2.8 GB | 6.7 GB | **25.0 tok/s** |

- **Interpretation:** offload freed ~16 GB VRAM but cost ~7.6× speed **for a model that already
  fit** — so offload HURTS models that fit; only use it for models that don't. 25 tok/s at 3B
  active params is interactive and validates the 80B-**A3B** extrapolation (active params, not
  total, drive generation speed). Risk to the box: none — process-local env, fully reversible.

### What it buys the 5090 (32 GB VRAM + 64 GB RAM)
- **Model-size ceiling** shifts from VRAM to system RAM: without offload, 32 GB caps you at
  dense ≤~27B / MoE ≤~30 GB total; with offload you can additionally run **gpt-oss-120b**
  (MXFP4 ~65 GB, Apache 2.0 — `ollama pull gpt-oss:120b`) spread across the 32 GB VRAM + 64 GB
  RAM (96 GB capacity). ~5.1B active params → community precedent ~29 tok/s on a tighter
  24 GB+64 GB box; the 5090 keeps more experts on-GPU (use `--n-cpu-moe N`) so it should match/beat.
- **Qwen3-Next-80B-A3B:** the only official Ollama tag is **159 GB (full precision)** which does
  NOT fit 96 GB — import a **Q4_K_M GGUF (~48 GB)** from HuggingFace (`ollama create
  qwen3next-80b-offload` from a sourced GGUF, `PARAMETER num_gpu 99` + `num_ctx 262144`). Verify
  the GGUF repo at install time.
- **Context:** experts vacating VRAM frees almost the whole 32 GB for KV cache (measured anchor:
  `qwen3-coder:30b` weights 20 GB on-GPU vs 2.8 GB offloaded). 30B-class contenders can run at the
  top of their context (256K); 80B/120b run at all, context bounded by leftover VRAM not weights.
- **Trade-offs:** long-context **prefill is CPU-bound** when experts are on CPU (slower first
  token); steady-state generation stays in the ~25–40 tok/s band for low-active-param MoEs.

### How to use it (launchers + installer)
- **Installer:** `install-windows.ps1 -TestProfiles` pulls `gpt-oss:120b` and creates the
  `gptoss-120b-offload` alias (`num_gpu 99`, low temp). Use `-ModelPath` to keep the ~1TB off the
  OS drive.
- **Launchers:** `crush-task` / `copilot-local` expose offload-bench entries **`[O1]` gpt-oss-120b**
  and **`[O2]` Qwen3-Next-80B-A3B**. Selecting one runs `scripts/offload-serve.{ps1,sh} -Action
  start` (stops the managed server, starts a dedicated `ollama serve` with `LLAMA_ARG_CPU_MOE=1`
  + `GGML_CUDA_NO_PINNED=1`), launches the tool, then `-Action stop` restores the managed server.
- **Why a dedicated serve:** `LLAMA_ARG_CPU_MOE` is GLOBAL to a serve process, so it must never be
  set on the everyday server (it would slow every model that fits). The offload mode is opt-in only.
- The stop path kills the `llama-server` runner child too — killing only the parent orphans it and
  leaks VRAM (verified + handled).

---


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

### GLM-4.7-Flash — NOTE: older GLM measurement; GLM-4.7-Flash is now the SERVER default

The table below was an **older GLM build** measured on the 4090 under Ollama. It is **not**
GLM-4.7-Flash, which is the current CachyOS server default (`QuantTrio/GLM-4.7-Flash-AWQ`,
served as `glm-4.7-flash`): MoE-lite (~29.9B, ~3B active), MLA → cheap KV, 198K context,
MIT-ish open license. Authoritative published numbers (HF card via BenchLM provider-exact):
SWE-bench Verified 59.2, LiveCodeBench 64.0, τ²-Bench 79.5. Re-measure local speed on the
box — the figures below do not apply to GLM-4.7-Flash.

| Metric (OLD GLM build, not GLM-4.7-Flash) | Value |
|--------|-------|
| Gen speed | 17.3 tok/s (with q8_0 KV fix) |
| VRAM (65K ctx) | ~23 GB, 89% GPU (after KV cache fix) |
| Coding score | 10/15 |
| Bug fix test | Timed out at 180s |
| Retired because | Slower, lower quality, larger VRAM than Gemma 4 (old build) |

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
