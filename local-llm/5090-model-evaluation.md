# RTX 5090 Model Evaluation Plan

> ## ⇄ MACHINE CONTEXT UPDATE — now running ON the 5090 (2026-06-27)
>
> **The session has moved onto the new 5090 box. "Here" / local / current = the 5090 workstation;
> the old 4090 box is now the "server baseline" → it becomes the CachyOS/Linux vLLM server.** This
> re-frames the "pre-upgrade / 4090 = current" language throughout this doc. Inspection only — **no
> installs done** (bring-up is a separate, not-yet-executed task).
>
> **Verified "here" hardware (on-box 2026-06-27):** RTX **5090, 32 GB VRAM** (driver 610.62) · Ryzen 9
> **9950X3D2** (16C/32T) · **64 GB** DDR5-6000 (MSI X870E CARBON WIFI, **2 of 4 DIMM slots free, 128 GB
> max**) · storage C: 4 TB / **V: empty 1 TB SN850X** / D: 164 GB / Z: 14.9 TB *(backup — ineligible)* ·
> Win 11 Pro b28000 · **Ollama not installed yet**.
>
> **Role mapping going forward:** *here/local* = 5090 + Ollama (Windows); the **§B set is the live local
> daily driver**, with **Qwen3.6-27B dense** the heavy-coding default (replacing Gemma 4, which lived on
> the 4090). *server baseline* = the 4090 box (24 GB + Ryzen 9 7900X + 64 GB DDR5-4800) → **CachyOS vLLM**
> (its 24 GB already matches the server sizing below — no change). **Model storage target:
> `OLLAMA_MODELS=V:\ollama`** (1 TB SN850X, off the OS drive).
>
> **Offload envelope is now LIVE:** 32 GB VRAM + 64 GB RAM = **96 GB** real (the §G "fits 96 GB"
> findings now describe this machine). The 128 GB analysis stays hypothetical, but the board confirms
> it's physically possible (2 free slots); the ROI verdict — *skip 128 GB for our profiles* — is unchanged.
>
> Below: any "Current Primary / measured on RTX 4090 / pre-upgrade" content is **historical**, and the
> 4090 it refers to is now the **server-baseline** box, not the local daily driver.

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
- **5090 task→model mapping (launchers):** heavy coding → `qwen36-27b-212k` (default,
  dense); light coding & review → `qwen3coder-144k`; general/office/all-tools →
  `glm47-flash-198k`; image companion → `qwen3:8b`.
- **CachyOS server default = GLM-4.7-Flash** (`QuantTrio/GLM-4.7-Flash-AWQ`, served as
  `glm-4.7-flash`), the standing all-rounder for coding + review + office MCP. vLLM
  serves one model at a time (24 GB), so a **mode switch** (`cachyos-switch-model`)
  loads coder / vision / image modes on demand. Image mode = HiDream (imagegen.service)
  + Qwen3-4B companion. **Minimize switching** — GLM covers everyday needs with no swap.
- **Client launchers mirror the server**: the `server` provider / `[S][C][V][I]`
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
  default is a 3.8B-active MoE at temp 1, context capped at 65K/262K). It was kept for a
  while as an optional bench slot and was **removed entirely on 2026-08-01** (see the
  sweep section at the end of this document).
- **Image: keep HiDream-I1, do NOT adopt FLUX** — FLUX performed noticeably worse than
  HiDream in a prior hands-on install. Verify the deployed "HiDream-O1-Image-Dev"
  identity on the box.
- **Creative writing disappoints locally** (hands-on): both **GLM-4.7-Flash** and
  **Qwen3.6** (27B dense + 35B-A3B) repeatedly struggled to draft cover letters from rich
  source data. This is the launcher's weak spot by construction: the picker has **no
  dedicated creative-writing model** and borrows the coding/agentic picks (copilot key 5
  "Creative writing" routes to the `heavy` slot = `qwen36-27b-212k`; Office/docs use
  `glm47-flash-198k`), which are selected for code and tool-use, not prose. A replacement
  sweep for a VRAM-resident (≤~32 GB Q4) prose-strong model is in §BP below.

Everything below this banner is retained as historical research/methodology; where it
conflicts with this banner, **this banner wins.**

---

## Current State (Pre-Upgrade Baseline)

### Hardware
> *Updated 2026-06-27 — the upgrade is complete; arrows below resolved to the live state.*

| Host | GPU | VRAM | CPU / RAM | Role |
|------|-----|------|-----------|------|
| Windows workstation (**"here" / local**) | **RTX 5090** | **32 GB** | Ryzen 9 9950X3D2 / 64 GB DDR5-6000 | Desktop, primary dev — **LIVE** |
| **Server baseline** (squire) | RTX 4090 | 24 GB | Ryzen 9 7900X / 64 GB DDR5-4800 | → CachyOS/Linux vLLM headless inference server |

### Software Stack
- **Backend**: Ollama (with vendored llama.cpp)
- **Frontend**: Crush CLI (task profiles), Copilot CLI (legacy scripts)
- **MCP servers**: imagegen-mcp (HiDream-O1 image gen). Office authoring (Word/PowerPoint/Excel) uses the vendored `office` skill (python-docx/python-pptx/openpyxl via `uv run`), not MCP — see `mcp/ReadMe.md`.
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
3. Run Crush with the Documents (office) profile — verify it writes correct python-docx/python-pptx/openpyxl code and runs it via `uv run`

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
  `qwen36-27b-212k` (dense, authoritative coding numbers); light/review =
  `qwen3coder-144k`; office/all-tools = `glm47-flash-198k`; image companion = `qwen3:8b`.
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
3. Update `config/crush.json` → server (vLLM) model list
4. Update server model descriptions in `install-cachyos.sh`
5. Test: 2 concurrent requests at 32K context (verify no OOM)

**Validation criteria:**
- 5090: ≥25 tok/s at 128K context, 100% GPU, no CPU spill
- 4090: No OOM with 2×32K concurrent, ≥10 tok/s per user
- Both: Tool calling works with Crush (Word, PPTX, coding profiles)
- Both: bench-run.py scores ≥ current Gemma 4 26B baseline (14/15)

---

## MoE Expert CPU Offload — run oversized MoE models (VERIFIED 2026-06)

> **RETIRED 2026-07-17.** The expert-offload experiment (`[O2]` Qwen3-Next-80B-A3B) was pulled from
> the rosters, launchers, installers, and tests. Root cause: the whole approach relied on Ollama
> honoring the `LLAMA_ARG_CPU_MOE` / `LLAMA_ARG_N_CPU_MOE` serve env var, and **Ollama 0.31+ (CGO
> runner removed; llama-server is now a subprocess) no longer applies it** — verified live on 0.32.0
> (the runner loads `-ngl 99` with no `--cpu-moe`, VRAM stays maxed). The only working path is running
> `llama-server` directly with `-ot "exps=CPU"` (bypassing Ollama), which is too much bespoke plumbing
> to maintain for a single experimental candidate. The content below is kept as a historical record of
> the 2026-06 evaluation; it does NOT describe the current shipping config.

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
- **Qwen3-Next-80B-A3B-Instruct:** the official Ollama *library* tag is **159 GB (full precision)**
  which does NOT fit 96 GB, but the **official `Qwen/Qwen3-Next-80B-A3B-Instruct-GGUF` repo publishes
  a single-file `Q4_K_M` (~45 GB)** that does. The installer pulls it directly via Ollama's HF
  passthrough (`hf.co/Qwen/Qwen3-Next-80B-A3B-Instruct-GGUF:Q4_K_M`) and bakes the
  `qwen3next-80b-offload` alias (`num_gpu 99`, `num_ctx 131072`, temp 0.25). Alternate quant
  (quality-leaning): unsloth `UD-Q4_K_XL` (~43 GB). **Architecture support is upstream:** llama.cpp
  issue #15940 "Qwen3-Next support" is CLOSED/merged (2025-11-28, GitHub API) and Ollama's library
  hosts `qwen3-next`, so the bundled `llama-server` engine handles the hybrid arch.
  - **VERIFIED on-box (2026-06-12, 4090 24GB + 64GB RAM, Ollama 0.30.8):** the `Q4_K_M` GGUF loads with
    full expert offload — load log shows **CPU expert buffer 44.6 GB**, CUDA weight buffer ~1.3 GB,
    ~9.2 GB total VRAM at 131K ctx — and generates at **~24 tok/s** (`/api/chat`), matching the offload
    band. `ollama ps` cosmetically reports "100% GPU" (known quirk; experts are actually in RAM).
  - **REQUIRED FIX (verified):** the GGUF's embedded chat template renders to an **immediate-EOS empty
    reply** under Ollama 0.30.8 (`/api/generate` and `/api/chat` both return 1 token, `done=stop`). A
    raw ChatML prompt generates correctly, confirming the arch works — so the alias **must** bake an
    explicit ChatML `TEMPLATE` (`<|im_start|>{role}\n{content}<|im_end|>` … `<|im_start|>assistant`).
    The installer does this for `qwen3next-80b-offload`; without it the model appears mute.
- **Context:** experts vacating VRAM frees almost the whole 32 GB for KV cache (measured anchor:
  `qwen3-coder:30b` weights 20 GB on-GPU vs 2.8 GB offloaded). 30B-class contenders can run at the
  top of their context (256K); 80B/120b run at all, context bounded by leftover VRAM not weights.
- **Trade-offs:** long-context **prefill is CPU-bound** when experts are on CPU (slower first
  token); steady-state generation stays in the ~25–40 tok/s band for low-active-param MoEs.

### Long-session real-world impact — prefill, not generation, is the bottleneck (measured)

Offload's headline gen rate (~25–66 tok/s) hides the actual long-session cost: **prefill** (prompt
processing) is CPU-bound once experts live in RAM, and prefill — not generation — dominates multi-hour
coding sessions where every turn re-reads a large, growing context.

- **Measured on-box** (4090, Ollama 0.30.10, `qwen3-coder:30b` A3B, 29.4K-token prompt): full-GPU
  **prefill 5340 tok/s / gen 94** vs CPU-offload **prefill 835 / gen 27** — a **6.4× prefill / 3.5× gen**
  penalty. Generation slowdown is annoying; the prefill slowdown is what stalls a session.
- **Prefix-cache invalidation makes it worse:** complex edits (insertions mid-file, refactors) change
  early tokens, invalidating the KV prefix cache and forcing a **cold re-prefill** of the whole context
  every turn — so each turn pays full prefill, not just on the delta.
- **Active-param extrapolation, ~60K ctx per turn (prefill only):** VRAM-resident ~11s ·
  Qwen3-Next A3B ~70s · gpt-oss-120b ~110s · MiniMax A10B ~3.5min · Qwen3-235B A22B ~8min. Penalty
  scales ~linearly with active params, so big-active-param offload models are unusable for iterative work.
- **Conclusion:** for long, complex sessions, **128 GB RAM does not help** and worsens the big-model
  path. **VRAM-residency / low active-param count is what matters** — the 5090's 32 GB VRAM is the real
  long-session lever, not more system RAM. Reinforces dropping `[O1]` and keeping `[O2]` low-active-param.

### How to use it (launchers + installer)
> **UPDATE 2026-06-28 — `[O1]` gpt-oss-120b DROPPED.** Post-deploy calibration showed it can't run
> concurrent with a real IDE on the 64 GB box (~35 GB experts→RAM even at partial offload), so the weights
> were removed and `[O1]` was pulled from all launchers + the installer. The offload roster is now **`[O2]`
> Qwen3-Next-80B-A3B only** (partial offload `-NCpuMoe 24`, ~66 tok/s, ~5.7 GB VRAM headroom). The text
> below is historical.
- **Installer:** `install-windows.ps1 -TestProfiles` pulls the official
  Qwen3-Next-80B-A3B-Instruct `Q4_K_M` GGUF (`hf.co/Qwen/...`) and creates the
  `qwen3next-80b-offload` alias (`num_gpu 99`, low temp). Use `-ModelPath` to keep models off
  the OS drive.
- **Launchers:** `crush-task` / `copilot-local` expose offload-bench entry **`[O2]` Qwen3-Next-80B-A3B**.
  Selecting it runs `scripts/offload-serve.{ps1,sh} -Action start -NCpuMoe 24` (stops the managed server,
  starts a dedicated `ollama serve` with `LLAMA_ARG_N_CPU_MOE=24`
  + `GGML_CUDA_NO_PINNED=1`), launches the tool, then `-Action stop` restores the managed server.
- **Why a dedicated serve:** `LLAMA_ARG_CPU_MOE` is GLOBAL to a serve process, so it must never be
  set on the everyday server (it would slow every model that fits). The offload mode is opt-in only.
- The stop path kills the `llama-server` runner child too — killing only the parent orphans it and
  leaks VRAM (verified + handled).

### Evaluated and rejected — too large even for offload

- **Kimi K2.7-Code (Moonshot AI)** — evaluated 2026-06-13, **REJECTED for all local hosts.**
  - *What it is (authoritative — official `config.json` + `LICENSE`):* DeepSeek-V3-class MoE
    (`model_type kimi_k25`, arch `DeepseekV3ForCausalLM`): hidden 7168, **61 layers, 384 routed + 1
    shared experts**, 8/tok, MLA attention, 256K ctx (YaRN), multimodal vision tower, native INT4 —
    consistent with **1T total / ~32B active**. License **Modified MIT** (open/permissive).
  - *Size (authoritative GGUF file sizes, `freakyskittle/kimi-k2.7-code-GGUF`):* smallest existing quant
    **TQ1_0 = 203 GB** (1-bit ternary, severe quality loss); TQ2_0 = 248 GB; BF16 = 1912 GB.
  - *Fit verdict:* does **NOT** fit any host even with full expert CPU offload — 5090 = 96 GB
    (32 VRAM + 64 RAM), 4090/server ≈ 88 GB; the 203 GB floor is ~2.1–2.3× over, and a usable Q4
    (~500 GB+) needs ~250 GB+ RAM. For a 1T MoE the experts are ~95% of weights, so offload can't
    rescue it (64 GB RAM ceiling blown ~3×). Only viable via hosted API → out of self-hosted scope and
    would send code to a third party (against our data-handling rule). **No launcher/installer change.**
  - *Community claims (non-authoritative, AI-summarized — flagged):* secondary blogs assert it "beats
    Opus 4.8 on agentic coding" / +20–30% coding vs K2.6; NOT verified against a primary benchmark.

### Closest-to-frontier MoEs that fit the 5090 — and why we stop at native/4-bit (2026-06-13)

After rejecting Kimi K2.7-Code, we surveyed which top-tier agentic-coding MoEs *do* fit the 5090's
**96 GB** (32 GB VRAM + 64 GB RAM) with expert CPU offload. Fit rule: total weights ≤ ~90 GB (leaves
headroom for KV + on-GPU non-expert layers). **All sizes below are authoritative** — exact GGUF file
sizes from the HuggingFace API (2026-06-13), not estimates.

| Model | Total / active | Best quant that fits 96 GB | Size | Precision quality | License |
|---|---|---|---|---|---|
| **gpt-oss-120b** | 120B / ~5.1B | native MXFP4 (~58 GB) | **58–65 GB** | **native — no loss** | Apache 2.0 |
| **Qwen3-Next-80B-A3B-Instruct** | 80B / 3B | Q4_K_M / Q5_K_M | **45–53 GB** | good (4–5 bit) | Apache 2.0 |
| Qwen3-235B-A22B-Instruct-2507 | 235B / 22B | UD-Q2_K_XL 83 GB · Q3_K_S 94.5 GB | 83–94 GB | **2–3 bit — degraded** | Apache 2.0 |
| MiniMax-M2.7 | ~230B / ~10B | UD-Q2_K_XL 70 GB · UD-Q3_K_M 94 GB | 70–94 GB | **2–3 bit — degraded** | other |

**Does NOT fit at usable quality** (authoritative sizes): GLM-4.6 (355B) — only sub-2-bit fits (UD-TQ1_0
78 GB / IQ1_M 100 GB); no full **GLM-4.7** GGUF exists (only GLM-4.7-Flash, already used).
Qwen3-Coder-480B-A35B, DeepSeek-V3.x, Kimi K2.7-Code — all exceed 96 GB at every quant.

#### Decision: we do NOT add the 2–3 bit frontier models (`[O3]/[O4]` rejected)

Local coding here has already been **disappointing at full/native precision** (Gemma 4 in Crush +
Copilot). Squeezing a 235B / 230B model down to **2–3 bit** to fit 96 GB is the opposite of what that
feedback calls for — heavy quantization degrades exactly the instruction-following and code-correctness
that were already weak. Bigger raw parameter count does **not** rescue a 2-bit model; it typically lands
**below** a smaller model run at native/4-bit precision. Therefore:

- **gpt-oss-120b** is the **only 100B+ model that fits at NATIVE precision (MXFP4, no loss)** → it is
  already the realistic frontier ceiling on this hardware, wired as `[O1]`.
- A 2-bit Qwen3-235B / MiniMax-M2.7 would almost certainly perform **worse** than the native-precision
  `[O1]` gpt-oss-120b and the 4-bit `[O2]` Qwen3-Next-80B for real coding — not worth ~155 GB of storage,
  install complexity, or bench time.

**Conclusion (2026-06-13, superseded 2026-06-28):** the offload roster was chosen as **`[O1]` gpt-oss-120b
(native MXFP4)** and **`[O2]` Qwen3-Next-80B-A3B (Q4_K_M)**. **`[O1]` was later DROPPED** (2026-06-28) — it
can't run alongside a real IDE on 64 GB even with partial offload — leaving **`[O2]` Qwen3-Next-80B-A3B as
the sole offload bench**. Nothing closer to Kimi K2.7 fits the 5090 without dropping to 2-bit (rejected on
quality). **No new launcher/installer profiles.**

> *Caveat — sourcing:* the **GGUF sizes above are authoritative** (HF API). Coding/SWE-bench numbers seen
> in web search for these models (e.g. GLM-4.7 ~85.7, Qwen3-235B ~81.1, gpt-oss-120b ~80.9) are
> **AI-aggregated, non-authoritative** and were NOT relied on for this decision. The 70–94 GB models also
> can't be safely loaded on the 4090 (88 GB), so any empirical 2-bit re-test would be a 5090 task — but
> it is **not** planned.

---


### Gemma 4 26B (former 4090 primary — now SERVER-BASELINE box) — Measured on RTX 4090

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

---

## §BP: Creative-writing replacement sweep (report only, 2026-07-19)

Follow-on to the hands-on weakness note in the STATUS/CORRECTIONS banner: GLM-4.7-Flash and
Qwen3.6 (27B dense + 35B-A3B) draft cover letters poorly. The launcher has no dedicated
creative-writing model; the "Creative writing" pick borrows the coding/agentic slot. This
section researches VRAM-resident replacements and ranks them. It is **report only**: no
launcher/installer/config edits, no `ollama pull`, no bench wiring.

### Candidate envelope
VRAM-resident on the 5090: Q4_K_M GGUF ≤ ~32 GB, Ollama-pullable, no offload. All sizes and
license/arch facts below are authoritative (HuggingFace API, 2026-07-19); community
quality claims are labeled sentiment and are not treated as verified.

### Verified candidates (all fit VRAM-resident at Q4_K_M)

| Model | Base arch (Ollama loads) | License | Q4_K_M GGUF | HF signal | Class |
|---|---|---|---|---|---|
| **Mistral-Small-3.2-24B-Instruct-2506** | Mistral3 (text GGUF = mistral) | Apache-2.0 | **13.35 GB** | base dl 281K / 598 likes | official instruct |
| **Gemma 3 27B it** | Gemma3 | Gemma ToU (open) | **15.41 GB** | base dl 854K / 2002 likes | official instruct |
| **Qwen3-32B** (non-thinking) | Qwen3 | Apache-2.0 | **18.40 GB** | base dl 10.2M / 721 likes | official instruct, dense |
| TheDrummer/Cydonia-24B-v4.3 | Mistral | (Mistral-Small base) | 13.35 GB | GGUF dl 19K / 72 likes | community writing/RP tune |
| TheDrummer/Skyfall-31B-v4.2 | Mistral | (Mistral-Small base) | 17.68 GB | GGUF dl 6K / 34 likes | community writing/RP tune |

### Ranked shortlist for cover-letter / professional prose

1. **Mistral-Small-3.2-24B-Instruct-2506 (Apache-2.0, 13.35 GB), top pick.** Official Mistral
   instruct with a strong general-writing reputation, smallest footprint of the set, and a
   permissive license. It is the most conservative swap: an instruct model tuned for
   following the kind of rich, structured brief a cover letter needs.
2. **Gemma 3 27B it (Gemma ToU, 15.41 GB), strongest prose contender to bench.** Gemma 3 is
   repeatedly praised for prose specifically. The prior local disappointment was Gemma **4**
   at **coding**, which does not carry over to Gemma 3 at **writing**. Worth a
   creative-specific hands-on comparison against Mistral-Small. License is the Gemma ToU (open gate).
3. **Qwen3-32B non-thinking (Apache-2.0, 18.40 GB), dense general baseline.** Dense (soft
   preference), broadly capable, permissive. Not prose-specialized, so include it as a
   control rather than an expected winner. Run with thinking disabled for prose.
4. **Community tunes (Cydonia-24B-v4.3, Skyfall-31B-v4.2), bench only, labeled.** These are
   the popular creative-writing finetune family (TheDrummer, Mistral-Small base). They lean
   RP / uncensored, and their quality is community sentiment, not benchmarked. That lean is a
   poor fit for professional cover-letter tone, so they rank below the official instruct
   models. Include at most one (Cydonia-24B-v4.3) as an optional experimental slot only if
   the official models underwhelm on expressiveness.

### Recommendation: give "Creative writing" its own slot

The root cause is structural, not model quality: "Creative writing" shares the `heavy`
coding slot, so the picker sends prose work to a code-tuned model. The durable fix is to
**decouple it into its own `task_alias`** (for example `creative`) pointing at a dedicated
prose model, rather than swapping the shared `heavy` slot (which would degrade coding).

Concretely, when this leaves report-only status: add a `creative` alias mapped to
**Mistral-Small-3.2-24B-Instruct** as the default, repoint copilot key 5 / crush "Creative
writing" to it, and add Gemma 3 27B it as a bench entry so the two can be compared hands-on.
This is deferred; it is the natural follow-up once a winner is confirmed by real use.

### Honest gaps
- No creative-writing quality numbers are relied on. Public "creative writing" leaderboards
  and self-reported finetune claims are not authoritative; the resolution is a hands-on
  cover-letter A/B on the box (Mistral-Small vs Gemma 3 27B), not a benchmark.
- Gemma 3 27B and Mistral-Small-3.2 GGUFs are the text-only variants of multimodal bases;
  they load as text models in Ollama (`gemma3` / `mistral-small3.2` tags exist).
### Bench status: live as of 2026-07-26 (winner still pending hands-on)

The shortlist is now pulled and wired as a hands-on bench, so the A/B can happen inside the
launcher instead of on paper. This is the bench-first step; no production slot has changed and
no winner is declared yet.

- Three alias models were created on the 5090 box, each at `num_ctx 65536` with a consistent
  prose `temperature 0.7` (a fair A/B, since the base defaults differ):
  - `mistral-small32-64k` from `mistral-small3.2:24b`
  - `gemma3-27b-64k` from `gemma3:27b`
  - `qwen3-32b-64k` from `qwen3:32b`, rebuilt to force non-thinking (its template defaults to
    thinking, which returns an empty draft under a normal token budget)
- They appear as a new "Creative-writing bench" category in the experimental menu of both the
  copilot and crush launchers, keys `[10]` Mistral-Small-3.2, `[11]` Gemma 3 27B, `[12]` Qwen3 32B.
  Registry aliases `cw1/cw2/cw3` in `scripts/local-models.json` (and the deployed copy).
- A demo on a shared "match resume to a job description" brief had all three produce clean,
  on-brief professional letters, a clear step up from the GLM-4.7-Flash / Qwen3.6 drafts that
  prompted this. First read: Mistral-Small was the most complete formal letter, Gemma 3 the
  warmest with the best flow, Qwen3 the strongest at tying back to the brief but dense in one
  block. These are first impressions on one generic brief, not a verdict.

Still pending (needs real cover-letter drafting, not a benchmark): pick the winner, then promote
it into a dedicated `creative` `task_alias`, repoint copilot key 5 off `heavy`, add the winner to
the installer pull list, and trim the bench. Production is unchanged until then.

### Bench round 2: tool-calling is now a hard gate (2026-07-29)

Round 1 lost two of its three entries to hands-on use, and one of the two failures exposed a
selection criterion the round-1 research missed entirely.

- **Gemma 3 27B: rejected, structurally incompatible.** Key `[11]` appeared to hang the CLI.
  It was not slow and it was not resource-starved (the host log shows a clean `63/63` layer GPU
  offload at ~64 tok/s). `POST /api/show` reports its capabilities as `completion, vision`
  with **no `tools`**. Both Copilot CLI and Crush send a `tools` array on every chat request, so
  Ollama rejects the call with `HTTP 400 {"error":"... does not support tools"}` in about 0.2s,
  which the client surfaces as an apparent hang. Prose quality was never the issue and is
  irrelevant here: a model that cannot accept a tools array cannot be driven by this stack.
- **Mistral-Small-3.2 24B: rejected on quality.** It could not reliably carry out a basic
  file-writing task in real use, despite the flattering round-1 demo.
- Both were deleted from Ollama and removed from the registry, `task_alias`, and both launcher
  menus. `qwen3-32b-64k` survived and moved to key `[10]` / slot `cw1`.

**The gate, going forward:** every creative-writing candidate must report `tools` in
`POST /api/show` **before** it is wired into a menu. Check this first; it is cheap, it is
authoritative, and it invalidates otherwise excellent prose models. This rules out Phi-4 14B
(its chat template has no `tools` variable at all) and EXAONE 3.5 32B (no tools, plus a
proprietary LG license and an exotic architecture), both of which would otherwise have ranked
well on writing.

Two replacements were pulled on 2026-07-29, both verified `completion, tools` before wiring:

| Slot | Menu key | Alias | Source tag | Size | License | Alias ctx |
|---|---|---|---|---|---|---|
| `cw1` | `[12]` | `qwen3-32b-64k` | `qwen3:32b` | 18.8 GB | Apache-2.0 | 65536 |
| `cw2` | `[13]` | `qwen25-32b-32k` | `qwen2.5:32b` | 18.5 GB | Apache-2.0 | 32768 |
| `cw3` | `[14]` | `commandr-35b-64k` | `command-r:35b-08-2024-q4_K_M` | 18.4 GB | **CC-BY-NC-4.0** | 65536 |

> Menu keys updated 2026-08-01: these were `[10]/[11]/[12]` until the sweep below renumbered
> the experimental menu. The `cw1/cw2/cw3` slot names are unchanged, and the pending A/B is
> unaffected apart from which number you press.

Notes and traps found while wiring these:

- The working hypothesis behind both picks is that the failures share a cause: GLM-4.7-Flash,
  Qwen3.6, and Qwen3 are all reasoning-tuned, and that training mix pushes their default voice
  toward a stiff analytical register. Qwen2.5 32B predates that shift, and Command R was tuned
  for instruction-heavy synthesis over supplied source material, which is exactly the
  "resume + job description + style brief" shape of the task. Both are older models; that is a
  real risk, but recency is what has been failing.
- **Qwen2.5 32B is 32K context, not 128K.** The GGUF reports `qwen2.context_length = 32768`.
  The 128K figure requires YaRN extension, which is not configured in the Ollama build, so the
  alias is capped at `32768` rather than forcing un-configured rope extension. Ample for a
  cover letter.
- **The `command-r:08-2024` tag does not exist** and fails with `pull model manifest: file does
  not exist`. The correct tag is `command-r:35b-08-2024-q4_K_M`. Command R also gets its tools
  capability from Ollama's built-in `command-r.gotmpl` Go template rather than the GGUF's own
  embedded Jinja template, so it must be pulled from the Ollama library; a raw GGUF sideload
  may not pick up tool support.
- **Command R is CC-BY-NC-4.0, non-commercial.** Fine for personal drafting on this box. It
  must not be promoted into a production slot used for commercial work, and that constraint is
  a tiebreaker against it if the A/B is close. The `cw3` rows carry a roster `note`, so both
  pickers render "(CC-BY-NC: non-commercial only)" in the detail column: the constraint is visible
  at the point of use rather than only here.

### Token budgets are now derived from the roster, not a constant (2026-07-29)

Wiring Qwen2.5 exposed a defect affecting the whole local roster. The launchers hardcoded
`COPILOT_PROVIDER_MAX_PROMPT_TOKENS = 51200` and a 16384 reply cap for **every** local model,
and the registry's `ctx` field was documentation only, never read. Two failures fell out of that:

- **Over-commitment.** Qwen2.5 32B holds 32768 tokens but was being handed a 51200 prompt cap.
  The `image_llm` slot was already worse: `qwen3:8b` holds 40960 and had the same 51200 cap, so
  this was live in production, not a new risk. Ollama does not error on an over-long prompt.
  Per `server/prompt.go`, `chatPrompt` "truncates any messages that exceed the context window of
  the model, making sure to always include 1) the latest message and 2) system messages", so the
  system prompt and the newest turn survive while the middle of the conversation is silently
  dropped. The client never learns. It presents as a model that keeps forgetting earlier detail
  and drifting back to generic output, which is easy to misread as poor model quality. In a
  bench that is actively confounding.
- **Under-use.** The 128K-256K models the roster exists to exploit were all throttled to a
  64K-era constant.

The rule now applied to local picks in all four launchers:

| | Formula | 40960 ctx | 65536 ctx | 262144 ctx |
|---|---|---|---|---|
| copilot prompt | `floor(ctx * 0.75)` | 30720 | 49152 | 196608 |
| copilot output | `min(16384, ctx - prompt)` | 10240 | 16384 | 16384 |
| crush `max_tokens` | `min(16384, floor(ctx / 4))` | 10240 | 16384 | 16384 |

The squire-server provider is untouched: it keeps the caps advertised by `:4090/models`. An alias
with no registry `ctx` (for example a direct `-Model` tag that is not in the roster) keeps the old
global defaults. Crush receives only the reply cap locally, because its `context_window` rides on
the providers block that the launcher writes in server mode only.

Testing: this is a deliberate post-baseline behaviour change, so the frozen parity goldens can no
longer be the authority on those values. Rather than re-baselining (which would have destroyed the
"identical to pre-refactor `cf852ee^`" guarantee, and is impossible anyway since `-RebuildGolden`
regenerates from the old ref), the three affected values are **masked on both sides** of the parity
comparison and asserted explicitly by a new `tests/test_token_budgets.ps1`. Masking the value rather
than removing the key means a field vanishing entirely is still caught. Parity still proves every
other aspect of resolution against the true baseline: 45 parity + 8 imagegen + 14 budget assertions
pass.

One incidental fix: the PowerShell suites shelled out to `wsl python3` purely for JSON
normalisation, so a wedged WSL hung them indefinitely rather than failing. `tests/lib.ps1` now
prefers a native Windows `python3` and falls back to WSL only when there is none.

## Model sweep 2026-08-01: three additions, one production category, Gemma 4 removed

A scan of Hugging Face by trending score for everything created since roughly 2026-07-17,
gated on the four criteria this roster actually cares about: fits the envelope, open license,
architecture that Ollama can load, and `tools` in `POST /api/show`.

### What went in

| Slot | Menu key | Alias | Source tag | Q4 size | License | Alias ctx | Task profile |
|---|---|---|---|---|---|---|---|
| `computer` | production `[8]` / crush `[6]` | `fara15-27b-192k` | `hf.co/bartowski/Fara1.5-27B-GGUF:Q4_K_M` | 17.2 GB | MIT | 196608 | Computer use / GUI agent |
| `h9` | `[9]` | `katcoder25-35b-256k` | `hf.co/bartowski/Kwaipilot_KAT-Coder-V2.5-Dev-GGUF:Q4_K_M` | 19.9 GB | Apache-2.0 | 262144 | Agentic coding |
| `h10` | `[10]` | `aquila-mini-35b-256k` | `hf.co/bartowski/XYZAILab_XYZ-Aquila-mini-GGUF:Q4_K_M` | 20.8 GB | Apache-2.0 | 262144 | Coding, provenance unverified |
| `off1` | `[11]` | `laguna-s21-118b-128k` | `hf.co/wimmmm/poolside-Laguna-S-2.1-GGUF:IQ4_XS` | 58.4 GB | openmdw-1.1 | 131072 | Coding, offload tier |

All four report `tools` in `POST /api/show` and were verified before wiring. Fara 1.5 and
Aquila-mini additionally report `vision`; all four report `thinking`.

**Fara 1.5 27B is a new production category, not a bench entry.** It is Microsoft's
computer-use / GUI agent line, which is a capability nothing else in the roster had. Benching it
against Devstral on a bugfix would measure the wrong thing. It gets its own "Computer Use"
heading in both launchers. On the Crush side it uses the existing `coding` profile rather than a
new one: Crush profiles map to MCP enablement, no computer-use MCP is installed, so a dedicated
profile would be behaviourally identical today. Add a real profile when there is an MCP to gate.

### Context calibration (on-box, 5090, q8 KV)

| Model | 128k | 192k | 256k | Chosen |
|---|---|---|---|---|
| KAT-Coder V2.5 | 25.43 GB | 26.26 GB | 27.11 GB | **262144** (4.9 GB headroom) |
| XYZ-Aquila-mini | 26.52 GB | 27.37 GB | 28.22 GB | **262144** (3.8 GB headroom) |
| Fara 1.5 27B | 25.82 GB | 28.26 GB | 30.70 GB | **196608** (256k leaves only 1.3 GB) |

Fara is a dense `qwen35`, so its KV grows far faster than the two `qwen35moe` entries. It is
capped at 192k for the same reason `qwen36-27b-212k` is capped: 256k technically loads at 100%
GPU but leaves no room for anything else on a desktop that also drives displays.

### Laguna S 2.1: the offload tier is now real

Laguna is the first model to earn a slot despite not fitting in VRAM, and it is worth recording
why, because the intuition that "a 118B will crawl under offload" is wrong here.

- **Architecture (authoritative, `config.json` + GGUF metadata):** 117.6B total across **256
  experts with only 10 active per token** plus one shared expert, `moe_intermediate_size` 1024,
  48 layers, hidden 3072. Active parameters work out to roughly **9B**. Three of every four
  layers use `sliding_attention` with a 512 window, so only 12 layers hold full KV.
- **Measured on-box 2026-08-01** at `num_ctx` 32768, 52%/48% CPU/GPU split, on an 18,320-token
  prompt: **725 tok/s prefill, 28.8 tok/s generation.** For comparison, the offload measurement
  already in this document for a **30B** (`qwen3-coder:30b` on the 4090) was 835 prefill /
  26.9 generation. A 118B is landing in the same range as a 30B because what offload actually
  punishes is active parameters and KV traffic, not total weight count.
- Generation sits inside the 20-50 tok/s "good, acceptable for interactive use" band.
- It loads at every context tested up to 262144 (62%/38% split at 256k). It is set to **131072**,
  chosen to keep the split nearer 56%/44% rather than because larger contexts fail.

Traps found while wiring it:

- **Ollama cannot pull sharded GGUFs.** The unsloth `UD-*` quants are multi-file directories and
  fail with `400 ... The specified tag is a sharded GGUF`. A single-file quant is required, hence
  `wimmmm/poolside-Laguna-S-2.1-GGUF:IQ4_XS`. The official `poolside` single-file `Q4_K_M` is
  89.4 GB, which does not fit the 96 GB envelope.
- **The `laguna` architecture is supported by Ollama 0.32.5**, despite the official model card
  still directing users to poolside's llama.cpp fork. Upstream merged it (`ggml-org/llama.cpp`
  #25165 on 2026-07-22, #26233 on 2026-07-28) and the vendored engine carries it: `libllama.dll`
  contains `src/models/laguna.cpp` and `ollama.exe` has a native `laguna.Model` implementation.
  This is worth checking directly rather than assuming.
- **Not yet exploited:** poolside ships a `DFlash` speculative-decoding draft model (2.1 GB) with
  a recommended 15 speculative tokens. Ollama has no Modelfile path to wire it, so the measured
  numbers above leave that on the table.

### Licensing

`openmdw-1.1` (Laguna) is the Open Model Definition and Weights licence and has not been read in
full. It is fine for the bench. **Read it before Laguna is promoted to any production slot**, the
same standing caution applied to Command R's CC-BY-NC.

`XYZ-Aquila-mini` is Apache-2.0 and clean, but its Hugging Face signal is odd: 356 likes against
650 downloads, where Qwen3.6-35B runs 2,605 likes against 5.9M downloads. XYZAILab is an unknown
lab. It is wired as a bench entry only and its ratio should be treated as promotion, not signal.

### Gemma 4 31B removed

Deleted from the registry, `task_alias`, both launcher menus, `config/crush.json`, the Windows
installer, and Ollama itself (`gemma4-31b-128k` and `gemma4:31b`). Three independent reasons had
accumulated: it disappointed in hands-on use (recorded in the banner at the top of this document
since 2026-06), it was the slowest entry in its class at roughly 25 tok/s, and it was the only
bench model with no VRAM headroom (31.17 GB at 256k, effectively at the ceiling). The CachyOS
4090 tier still references it and was deliberately left alone; that is a different envelope.

### Menu renumbering

The experimental menu is now contiguous 1 to 14 in both launchers: coding `[1]`-`[10]`, offload
`[11]`, creative writing `[12]`-`[14]`. The creative-writing entries moved from `[10]/[11]/[12]`.
Slot names (`cw1/cw2/cw3`) did not change.

### Rejected in this sweep

- **On license:** `amd/Instella-MoE-16B-A3B-Think` (15.9B) is `researchrail`, not an open
  commercial licence. It would have fit trivially.
- **On size, against the 96 GB envelope:** Inkling-Small 266B (only a 2-bit quant fits),
  DeepSeek-V4-Flash-0731 304B, Solar-Open2 250B, XYZ-Aquila-pro 396B, `skt/A.X-K2` 691B (no GGUF
  exists at all), K-EXAONE-2.0 749B, Inkling 952B.
- **On tooling:** `mindlab-research/Macaron-V1-Tall` (36B, MIT, tools present) has no GGUF from a
  trusted quantiser yet. Recheck later; the architecture and licence are both acceptable.

### Still open

Nothing released in this window targets prose. Every arrival was coding, computer use, or
frontier-scale general. **The creative-writing A/B is not superseded** and the existing
`cw1/cw2/cw3` shortlist stands on its own merits.

Separately, this sweep did not resolve a contradiction it surfaced: **GLM-4.7-Flash occupies the
production `agentic` slot while failing the thresholds in this document.** It timed out at 180s
on the bugfix test, runs at 16-17 tok/s (this document classifies 10-20 as "marginal"), and is
one of the two models whose prose failures started the creative-writing work. Devstral Small 2 or
KAT-Coder may simply be better production picks. That is a larger win than any model added here.

---

## §BS: Ollama 0.32.9 upgrade, CUDA regression, and the research-slot bench (2026-08-13)

Triggered by a request to promote GLM-4.7-Flash into a production "general conversation
and research" category, plus a 4-week model sweep. Both goals were overtaken by two
findings below.

### 1. The 5090 had been running inference on Vulkan, not CUDA

While diagnosing a model load failure, the Ollama server log showed:

```
inference compute id=0 library=Vulkan name=Vulkan0
    description="NVIDIA GeForce RTX 5090" total="31.4 GiB"
WARN llama-server GPU discovery watchdog timed out ... cuda_v13 ... error="context canceled"
WARN llama-server GPU discovery watchdog timed out ... cuda_v12 ... error="context canceled"
```

Both CUDA backends were installed and functional (`ggml-cuda.dll` present, `llama-server.exe`
runs). CUDA discovery simply timed out at startup and Ollama silently fell back to Vulkan.
`OLLAMA_VULKAN` is set nowhere in the user env, machine env, or this repo, so this was an
Ollama default plus a discovery bug, not a configuration choice.

Upgrading to 0.32.9 cleared it:

```
inference compute id=0 library=CUDA compute=12.0 name=CUDA0 libdirs=ollama,cuda_v13 driver=13.3
```

Usable VRAM also rose from 30.7 to 31.8 GiB.

**Impact: every throughput number recorded in this document before 2026-08-13 was measured on
the Vulkan fallback and understates the hardware.** Re-measured on CUDA, GLM-4.7-Flash
generates at **219 to 225 tok/s**, against the **17.7 tok/s** in the §bench table. That is a
13x correction.

This invalidates the "GLM-4.7-Flash is too slow for production" conclusion recorded in the
2026-08-01 sweep, including the 180s bugfix timeout. GLM sits comfortably inside the "good"
band once it is actually using the GPU properly. Any model previously rejected on speed
grounds deserves a re-measure before that rejection stands.

### 2. Nemotron 3.5 Lightning replaces Nemotron 3 Nano at bench slot h6

The 4-week sweep surfaced exactly one viable candidate, and it is a successor to an
incumbent rather than a new entry.

| | Nemotron 3 Nano (out) | Nemotron 3.5 Lightning (in) |
|---|---|---|
| Alias | `nemotron3-nano-256k` | `nemotron35-light-256k` |
| Source | `hf.co/bartowski/nvidia_Nemotron-3-Nano-30B-A3B-GGUF:Q4_K_M` | `nemotron-3.5-lightning:30b-a3b-q4_K_M` (official Ollama library) |
| Q4_K_M | ~18 GB | ~25 GB |
| Native ctx | 256k | 1M (capped 256k) |
| Arch | `nemotron_h_moe` | `nemotron_h_moe` |

Requires **Ollama >= 0.32.9**, whose changelog entry is "Added the Nemotron 3 architecture".
On 0.32.6 the official tag returns HTTP 412, and third-party GGUFs fail at load with
`done_getting_tensors: wrong number of tensors; expected 417, got 408`, because bartowski
splits the MTP head into separate `mtp-*.gguf` files that Ollama expects inline. No quant
works around this; the loader itself is the constraint. Prefer the official
`ollama.com/library` tag when one exists.

Context calibration (on-box, CUDA, q8 KV) shows context is nearly free on this hybrid
Mamba-2 plus MoE design, because only 12 layers carry full KV:

| num_ctx | VRAM | split |
|---|---|---|
| 32k | 29.53 GB | 100% GPU |
| 64k | 29.39 GB | 100% GPU |
| 128k | 29.89 GB | 100% GPU |
| 192k | 30.32 GB | 100% GPU |
| 256k | 30.75 GB | 100% GPU |

Going from 32k to 256k costs only 1.2 GB, so reducing context to reclaim headroom is not
worthwhile here: the 25 GB of weights is the cost, not the KV. Capped at 256k to match the
model it replaces. Headroom at 256k is thin (about 1.1 GB), which is acceptable for a
swap-in bench model but would not be for an always-on production slot.

CachyOS deliberately keeps Nemotron 3 Nano: at 25 GB the 3.5 build does not fit the 4090 tier.

### 3. Neither candidate is safe for an ungrounded research slot

A 5-prompt bench was run against GLM-4.7-Flash and Nemotron 3.5 Lightning (temp 0.3, CUDA).
Harness: `files/bench-research.ps1`. The decisive prompt asked both models to describe the
"Zylonic Consensus Protocol (ZCP)" from a fabricated 2019 OSDI paper by invented authors.
The correct answer is to refuse.

**Both models failed, and neither hedged.** GLM invented a plausible paper title, four design
goals, and a four-point comparison against Raft. Nemotron invented five design goals,
fabricated quorum formulas such as `w + r > n` and `write quorum = n - f`, and rendered a
full comparison table. Nemotron's answer was the more detailed and therefore the more
dangerous of the two.

On the grounded prompt, where the source notes were supplied in context, **both scored
perfectly**: correct cause, correct DRI, and both resisted a planted distractor.

The conclusion is not that one model beats the other. It is that with no system prompt the
failure is shared:

- These models are strong at **grounded synthesis**, where sources sit in the context window.
- These models are **unsafe for open factual recall** when given no instruction to abstain.

### 4. The constraints prompt separates the two models decisively

The bench was re-run with jsquire's standing constraints block supplied as the system prompt
(`files/constraints-prompt.md`), whose relevant lines are "If you lack data to validate, tell
me what you don't know", "Avoid speculation" and "Avoid hallucinations". Harness support was
added via `-SystemPromptFile`.

This changed the outcome, and it did not change it equally.

**Nemotron 3.5 Lightning passed.** It refused outright:

> I do not have verified information about the Zylonic Consensus Protocol from the 2019 OSDI
> paper by Hollingsworth and Vance. My training data does not include a confirmed summary of
> that work, and I cannot describe its design goals or compare it to Raft without risking
> inaccurate statements.

It then supplied only verified information about Raft and directed the reader to the OSDI
proceedings as the authoritative source. That is precisely the requested behaviour.

**GLM-4.7-Flash failed again.** It still opened with "Based on the 2019 OSDI paper by
Hollingsworth and Vance, the Zylonic Consensus Protocol (ZCP) has specific design goals" and
proceeded to invent them. The constraints did suppress the surface tells, so there was no
fabricated paper title this time and the answer was shorter, but the fabrication itself
survived. Constraints made GLM's hallucination harder to spot rather than less likely.

Both models honoured the formatting constraints, with zero em-dashes under the system prompt
(GLM leaked one in the unconstrained run).

**Verdict: the production conversation and research slot should be Nemotron 3.5 Lightning,
not GLM-4.7-Flash.** Abstention under instruction is the property that matters for a research
role, and it is the one property that separated the two. Speed did not decide this, and after
the CUDA fix speed would have favoured GLM at 219 tok/s against 174 tok/s.

Caveat worth keeping: this is a single adversarial probe. Nemotron abstaining once is
evidence, not a guarantee. The slot should still be paired with retrieval where the answer
matters.

### 5. Resulting roster change

A new production category **General & Research** was added to both launchers, occupied by
`nemotron35-light-256k` via a new `research` task alias. Copilot key 9, Crush key 7 on the
`docs` profile. The model is therefore both a production slot and bench slot h6, which
matches the existing pattern for `heavy`/h1 and `agentic`/h4.

Because production models must exist on a default install, `nemotron35-light-256k` was moved
out of the `-TestProfiles` alias block into the base `$aliasModels` set, added to
`$ProductionModels` and `$KnownModelDescriptions`, and added to `config/crush.json`. The 5090
profile `RequiredGB` moved from 100 to 130 to cover the extra 25 GB.

GLM-4.7-Flash still holds the `agentic` slot (Copilot keys 4 and 6, Crush key 4) covering
office and document authoring. That is unchanged and remains open for review. The evidence
now says GLM is fast and competent at grounded work, and unreliable when asked to recall
facts it was never given.

---

## §BT: Full roster re-measurement under CUDA (2026-08-13)

The Vulkan finding in §BS invalidated the speed axis for every model, so the whole roster was
re-measured rather than reasoned about. Two passes: a throughput pass over all 16 registry
entries, and a separate prefill pass at roughly 24k prompt tokens. Harnesses are
`files/rebench-cuda.ps1` and `files/prefill-bench.ps1` in the session workspace.

### 1. Throughput, all 16 entries

Generation rate from a 500-token completion, model warmed first so load time is excluded.

| Model | Slot | Gen tok/s | Placement | Tools |
|---|---|---|---|---|
| qwen3coder-144k | coder, review, h3 | 278.2 | 100% GPU | yes |
| ornith-35b-256k | h7 | 238.3 | 100% GPU | yes |
| qwen36-35b-256k | h2 | 237.6 | 100% GPU | yes |
| northmini-code-256k | h5 | 231.9 | 100% GPU | yes |
| katcoder25-35b-256k | h9 | 231.8 | 100% GPU | yes |
| aquila-mini-35b-256k | h10 | 231.5 | 100% GPU | yes |
| glm47-flash-198k | agentic, h4 | 225.6 | 100% GPU | yes |
| qwen3:8b | image_llm | 224.6 | 100% GPU | yes |
| nemotron35-light-256k | research, h6 | 154.6 | 100% GPU | yes |
| devstral2-24b-128k | h8 | 91.5 | 100% GPU | yes |
| qwen36-27b-212k | heavy, h1 | 73.1 | 100% GPU | yes |
| fara15-27b-192k | computer | 71.7 | 100% GPU | yes |
| commandr-35b-64k | cw3 | 70.4 | 100% GPU | yes |
| qwen3-32b-64k | cw1 | 67.4 | 100% GPU | yes |
| qwen25-32b-32k | cw2 | 67.1 | 100% GPU | yes |
| laguna-s21-118b-128k | off1 | 31.9 | 52%/48% CPU offload | yes |

Every entry loads, every entry emits a correct tool call, and every entry except the
deliberate offload case sits fully on the GPU.

### 2. Two consequences that change how this document should be read

**The speed threshold table is now inert on this box.** It classifies >50 tok/s as
"excellent" and 20-50 as the "5090 target range". Fifteen of sixteen models clear
"excellent", and the sixteenth is an intentional 118B running half on CPU. Speed can no
longer separate any two candidates here, so it should be treated as a floor check rather
than a ranking input. Quality and behaviour are the only axes left that discriminate.

**Laguna's recorded number was never wrong.** It measured 28.8 tok/s on Vulkan and 31.9 on
CUDA, because an offloaded model is bound by CPU and PCIe traffic rather than by the GPU
backend. Context is nearly irrelevant to it as well: 31.9 tok/s at 32k against 30.9 at 131k.
This is the counter-example that bounds the correction. Only fully GPU-resident models were
understated, so §BS's warning applies to those and not to the offload entry.

### 3. Prefill at 24k tokens

Prefill governs how long an agent sits before its first token on a real working context, so
it was measured separately with a large unique prompt. A first attempt produced nonsense
(15 tok/s for one model, 22905 for another) because a short warm-up prompt let part of the
input be served from cache; the numbers below use unique filler that cannot be cached.

| Model | Prompt tokens | Prefill tok/s | Time to first token | Gen tok/s |
|---|---|---|---|---|
| northmini-code-256k | 17691 | 9348.0 | 1.9s | 172.6 |
| ornith-35b-256k | 23823 | 8669.7 | 2.7s | 192.1 |
| katcoder25-35b-256k | 23740 | 8555.5 | 2.8s | 190.0 |
| qwen3coder-144k | 23731 | 8403.2 | 2.8s | 140.7 |
| nemotron35-light-256k | 24785 | 8314.9 | 3.0s | 220.4 |
| qwen36-35b-256k | 23790 | 6494.7 | 3.7s | 181.5 |
| devstral2-24b-128k | 25340 | 4132.7 | 6.1s | 69.7 |
| glm47-flash-198k | 19820 | 4120.0 | 4.8s | 142.5 |
| qwen36-27b-212k | 23752 | 3239.3 | 7.3s | 64.7 |
| fara15-27b-192k | 23702 | 3110.3 | 7.6s | 62.7 |

The roster separates cleanly by architecture. MoE entries prefill at 6500 to 9300 tok/s and
answer in under 4 seconds. Dense entries prefill at 3100 to 4100 tok/s and take 6 to 8
seconds. That gap is structural, it widens with context, and it is felt on every turn.

### 4. The production heavy slot is held by the slowest model in the roster

`qwen36-27b-212k` holds `heavy` and h1. On the two measurements that matter for a
long-context coding agent it places last or near last: 3239 tok/s prefill, 7.3s to first
token at 24k, and 64.7 tok/s generation. `qwen36-35b-256k` sits unused at h2 with double the
prefill, roughly triple the generation, and 256k of context against 212k.

This is a direct consequence of the Vulkan defect. The slot was assigned when dense models
appeared to hold a speed advantage they did not have, and the sweep that assigned it also
carried a soft preference for dense architectures. Neither survives the measurements above.
The choice is not settled by speed alone, because dense and MoE differ in output quality on
long reasoning chains, but the assumption underpinning the current assignment is gone and
the pairing should be decided by hands-on comparison rather than left as is.

### 5. Behaviour of oversized prompts differs across the roster

Sending a prompt larger than `num_ctx` does not fail uniformly. `devstral2-24b-128k`,
`qwen36-27b-212k`, `fara15-27b-192k` and `ornith-35b-256k` return HTTP 400 with
`exceed_context_size_error` and an exact token count. Others silently truncate the input and
answer from the remainder, which is the more dangerous behaviour because a caller sees a
normal response to a prompt the model never fully read. Worth knowing when wiring anything
that feeds large files to these models.
### 6. Heavy-slot head-to-head: qwen36-27b-212k against qwen36-35b-256k

Scored by executing each answer against hidden tests the models never saw, so correctness is
decided by the interpreter rather than by reading the code. Harness `files/heavy-bench.ps1`,
three tasks: merging closed intervals with a no-mutation requirement, repairing a rounding
bug in a currency splitter including negative totals, and writing a thread-safe LRU cache
with injected-clock TTL expiry.

Two harness bugs had to be fixed before the numbers meant anything, both worth recording:

- **Both models are thinking models**, and reasoning lands in a separate `thinking` field. An
  initial 1600-token budget was consumed entirely by reasoning, so almost every answer came
  back empty and the first run scored 1/12. That was the harness failing, not the models.
- Runs that exhaust the budget are now reported as `TRUNC` rather than counted as wrong
  answers, because they are a different failure and mean something different in use.

Results at an 8000-token budget:

| Task group | qwen36-27b-212k | qwen36-35b-256k |
|---|---|---|
| interval_merge + bugfix_rounding | 4/4 | 4/4 |
| concurrency_cache (hard) | 1/6, five truncated | 2/6, two truncated, two wrong |
| Overall | 5/10 | 6/10 |
| Wall clock, easier tasks | 24.8s | 12.9s |
| Wall clock, hard task | 116.4s | 32.5s |
| Generation | 69.9 tok/s | 231.4 tok/s |
| Prefill at 24k | 3239 tok/s | 6495 tok/s |
| Context | 212k | 256k |

**Quality is a tie and speed is not close.** Both handle the easier tasks perfectly and both
struggle with the concurrency task. The difference is what happens while struggling: the
27B exhausted the 8000-token budget on five of six attempts at that task, spending roughly
115 seconds per attempt and returning nothing usable, whereas the 35B finished inside the
budget on four of six and answered three to four times faster throughout.

The incumbent is therefore slower on both measurements, shorter on context, and no more
accurate. The reason it holds the slot was a speed advantage that the Vulkan defect
manufactured. On this evidence `qwen36-35b-256k` is the better `heavy` occupant.

One caveat on the token budget: with no cap the 27B would eventually finish rather than
truncate. That does not rescue it, because the cost simply moves from a truncated answer to
a two-to-four minute wait on exactly the hard problems where a heavy-coding slot earns its
keep.
### 7. Roster change applied

`heavy` now resolves to `qwen36-35b-256k` and `qwen36-27b-212k` is retired from the registry,
both launcher menus, `config/crush.json`, the Windows installer and Ollama itself. The base
tag `hf.co/unsloth/Qwen3.6-27B-MTP-GGUF:Q4_K_M` was removed with it.

The swap reaches further than heavy coding, because Copilot keys 4 and 5 ("Technical docs"
and "Creative writing") also route to the `heavy` slot. Those three entries all move to the
MoE build together. If the 35B turns out to write worse prose than the dense 27B did, the
right fix is to split "Creative writing" onto its own slot rather than to undo this change,
since the coding evidence is clear.

Retiring the model freed h1, so the bench menu was renumbered to stay contiguous: coding
`[1]`-`[9]`, offload `[10]`, creative writing `[11]`-`[13]`. The `heavy`/h1 pairing is
preserved, h1 now being the 35B. Slot names shifted by one from h2 upward, so the former
`agentic`/h4 and `research`/h6 pairings are now `agentic`/h3 and `research`/h5.

Installer bookkeeping: the production roster is six models rather than seven, and 5090
`RequiredGB` moved from 130 down to 115.

**CachyOS**: `OLLAMA_SLOT[heavy]` is now tier-conditional. The 5090 tier follows the change
above; the 4090 tier deliberately keeps the dense 27B. An earlier draft of this section
justified that by saying the 5090 measurement "does not transfer." That was weaker than the
data supports and is corrected in section BU below: the model-side cost is host-independent
and the 4090 exclusion can be derived rather than assumed. `test_installer_gen.sh` asserts
both tiers.

### BU. Does a VRAM measurement taken here transfer to the 4090?

Largely yes, and the 4090 decision above is derived from it rather than guessed. But the
raw `ctx_calibration` numbers cannot be used as-is. Three corrections apply, two of them
measured on 2026-08-13.

**Correction 1: the recorded figure is whole-card, not model cost.** `vram_used_gb` is
`nvidia-smi memory.used`, which includes the desktop. That baseline was 2.05 GiB in some
runs and 3.51 GiB in others, and a headless server pays none of it. Subtract the idle
baseline before comparing hosts.

**Correction 2: the backend shifts a fixed overhead, not the KV slope.** Most of the
calibration table was taken while this box was silently on Vulkan. Re-measuring
`qwen3.6:35b` under CUDA (authoritative, this box):

| ctx | whole card | idle | model + KV | Vulkan-era model + KV |
|---|---|---|---|---|
| 32768 | 26.19 GiB | 3.49 | **22.70 GiB** | 23.35 GiB |
| 262144 | 29.18 GiB | 3.49 | **25.69 GiB** | 26.34 GiB |

CUDA is **0.65 GiB cheaper at both contexts**, so the pre-CUDA table is uniformly
pessimistic by that amount. The per-token KV cost is unchanged at **13.66 KB/token**
(2.99 GiB across 229376 tokens), identical to the Vulkan-era slope. So context scaling
transfers exactly; only a constant shifts.

**Correction 3: it transfers to the CachyOS Ollama path only.** The CachyOS server role
runs vLLM with `gpu-memory-utilization` 0.90 to 0.92, which pre-allocates a pool rather
than growing with the model. Ollama-derived arithmetic says nothing about that path. The
two hosts do agree on the settings that matter for the Ollama path: both set
`OLLAMA_FLASH_ATTENTION=1` and `OLLAMA_KV_CACHE_TYPE=q8_0`, so KV is q8 on both.

**Scope of what was measured.** Everything above is Ollama on the Windows 5090. It is
sound for that host, and it answers the question it was asked: a VRAM figure taken here
does transfer to another Ollama host once the idle baseline is subtracted and the backend
constant is accounted for.

**It does not extend to the 4090.** That machine is a **vLLM server** and runs no Ollama at
all. `install-cachyos.sh` picks exactly one engine: `--install server` installs vLLM,
`--install local` installs Ollama, and the two are the branches of a single
`IS_SERVER_MODE` conditional (`if` at L1025, `else` at L1599, `fi` at L1650). The 4090 box
takes the server branch. So `populate_ollama_tier`'s 4090 tier and its `OLLAMA_SLOT[heavy]`
choice describe an `--install local --ollama-models 4090` host that the installer supports
and `test_installer_gen.sh` exercises, but that no hardware here runs.

**vLLM sizing on the 4090 cannot be inferred from anything in this document, and no
estimate is offered here.** Four independent reasons, each verifiable in the config rather
than assumed:

1. **Different weight format.** The Ollama roster is GGUF (Q4_K_M, Q6_K). The vLLM modes
   are 4-bit AWQ and GPTQ (`btbtyler09/Qwen3-Coder-30B-A3B-Instruct-gptq-4bit`,
   `cyankiwi/Devstral-Small-2-24B-Instruct-2512-AWQ-4bit`, `Orion-zhen/Qwen3-1.7B-AWQ`).
   The same model does not weigh the same in both.
2. **Different KV dtype.** Ollama here is `q8_0`; every vLLM mode env-file sets
   `VLLM_KV_CACHE_DTYPE=fp8_e5m2`. The 13.66 KB/token slope measured above is a q8_0 GGUF
   number and does not describe fp8 paged KV.
3. **vLLM does not size to the model.** It pre-allocates
   `VLLM_GPU_MEMORY_UTILIZATION` (0.90 to 0.92, and 0.16 for the image companion) as a pool
   up front. Whole-card usage is therefore a function of that setting, not of weights plus
   KV, and "does it fit" instead means whether `VLLM_MAX_MODEL_LEN` can be carved from what
   remains after weights. That is a different question with a different failure mode.
4. **Different allocator.** PagedAttention blocks versus llama.cpp's contiguous KV have
   different overhead and fragmentation behaviour.

The only authoritative way to size a vLLM model on that box is to measure it on that box.
Until that is done, this document makes no claim about it.

Two corrections to earlier drafts of this section, recorded rather than silently removed:

- An earlier draft claimed Ollama and vLLM co-reside on the 4090 and contend for VRAM.
  Wrong: they are mutually exclusive install modes. Ollama is absent from
  `cachyos-switch-model`'s `stop_all` because it is never installed there, not because of a
  gap.
- An earlier draft carried a computed 24 GB fitting table for `qwen3.6:35b`. It has been
  removed. It described no real host, and its overhead term was an assumption rather than a
  measurement.

Separately, a stale note is now closed: the installer used to say "headless frees only
~530 MiB" at the `image` mode env-file, implying a desktop resident on the 4090. That
observation **predates moving the Plasma session and UI to the integrated graphics card**.
The 4090 is compute-only today and the note has been corrected in `install-cachyos.sh`.

---

## §BV. Agentic slot: GLM-4.7-Flash retired, Muse Glimmer 30B promoted (2026-08-14)

Triggered by a broad model sweep across all capability scenarios. The sweep surfaced one
new candidate worth acting on, and it also produced the evidence that finally settled the
open GLM question flagged in the 2026-08-01 sweep (line ~1028) and in section BT.

### Engine

Ollama updated 0.32.9 to **0.32.11**. Checksum verified against the release `sha256sum.txt`
before install. Note that 0.32.10 and 0.32.11 are GitHub **pre-releases**, not stable.
Upgrade was clean: all models and every roster alias survived.

One prediction failed and is recorded rather than dropped. The 0.32.11 changelog entry
"match Muse Glimmer reasoning template" was expected to fix an observed defect where Muse
Glimmer echoes the user prompt twice at the start of its thinking channel. It did not. The
behaviour is byte-identical on 0.32.9 and 0.32.11. Cause is unresolved. Ollama renders this
model in Go code, so the `template` field is only `{{ .Prompt }}` and cannot be inspected
the usual way. Impact is wasted reasoning tokens, not wrong output, and it is constant
across versions so it does not affect bench comparability.

### Muse Glimmer 30B, measured on-box

Meta Superintelligence Labs, Apache 2.0, `muse-glimmer:30b`, 18 GB, arch `muse-glimmer`.
Ollama shipped NVIDIA support in 0.32.8.

| Property | Measured |
|---|---|
| Capabilities | completion, vision, tools, thinking |
| Tool calling | native call succeeded first try, `finish_reason: tool_calls` |
| VRAM at full 131072 ctx | **16 GB, 100% GPU**, 21422 of 32607 MiB used |
| Free VRAM at max ctx | **~11 GB**, the roomiest in the roster |
| Generation | ~70 tok/s |

The headroom is structural, not luck: 32 attention heads against only 2 KV heads, plus a
2048 sliding window at a 3:1 sliding-to-full ratio, so KV is nearly free. Every other
roster model leaves 2.6 to 6.5 GB free at its max context. This model leaves ~11 GB, which
means a higher quant is likely affordable later (Q6_K_XL is 24.5 GB) if prose quality
matters more than speed.

### Bench 1: cover letter, scored mechanically against @jsquire's own accepted letters

Two rounds each, `num_predict` raised to 20000 so thinking models are not cut off.

| Model | Best | Avg | tok/s | Em-dash | Unsupported |
|---|---|---|---|---|---|
| ornith-35b-256k | 100 | 97.5 | 245.8 | 0 | 0 |
| muse-glimmer:30b | 95 | 95 | 68.6 | 0 | 0 |
| glm47-flash-198k | 94 | 87 | 181.1 | 2 | 1 |

**Ornith keeps the creative slot.** It wins on score and is 3.6x faster. Muse Glimmer is
extremely consistent but runs long, averaging 718 words against the 426 to 719 target band.

This run also corrects a misreading of the earlier cover-letter data. Ornith's previously
recorded average of 50 was a harness artifact: the reasoning budget was exhausted and one
round returned empty content, scoring 0. Given an adequate budget Ornith averages 97.5.
The earlier number said nothing about quality.

### Bench 2: abstention under the constraints system prompt

Same `hallucination_bait` prompt as section BS, asking about a consensus protocol that does
not exist.

- **muse-glimmer: PASS.** Cleanest of the three. Stated it checked the OSDI 2019 program,
  found no such paper, declined to describe the protocol, and volunteered nothing
  unverified.
- **nemotron35-light: PASS with a slip.** Abstained correctly, then volunteered that Raft
  was a "2013 OSDI paper". Verified against usenix.org: the Raft paper was USENIX ATC 2014.
  It broke its own constraint by adding an unchecked citation.
- **glm47-flash: FAIL.** Fabricated the protocol outright, opening "Based on the 2019 OSDI
  paper by Hollingsworth and Vance", then invented four design goals and three Raft
  comparisons, in bullets and bold that the constraints prompt forbade.

All three answered the grounded-summary test correctly, so this is a fabrication problem
and not a comprehension problem.

### Decision

**GLM-4.7-Flash is retired from the local roster and its weights removed from the box.**

This is the third independent signal against it, and it closes the contradiction the
2026-08-01 sweep left open. GLM fabricated in the unconstrained research bench (section BS),
fabricated again under an explicit anti-speculation system prompt, and was the only model in
the cover-letter bench to emit em-dashes and an unsupported claim. It had **already been
retired from the CachyOS vLLM server roster** for the same reason, where
`install-cachyos.sh` records "hallucinated in office/agentic use" and `test_schema.sh`
asserts it stays out of the mode list. The local roster is now consistent with that.

Speed was never the problem. Section BT correctly overturned the "too slow" verdict. Trust
was the problem.

**Muse Glimmer 30B takes the `agentic` slot** as `museglimmer-30b-128k` at 131072 ctx, temp
0.30, covering Copilot keys 4 and 6 and Crush key 4, including Office authoring. The
accepted cost is speed: ~70 tok/s against GLM's ~195. The gain is a model that abstains
correctly, calls tools natively, and adds vision.

Context drops from 198k to 128k, which is Muse Glimmer's native maximum. No slot in the
roster is known to need more than 128k for agentic work, but this is the one regression in
the swap and is recorded as such.

### Open items

- The prompt-echo defect in the thinking channel is unexplained. Recheck when Muse Glimmer
  support matures, and consider filing upstream.
- The 4090 Ollama-tier context for this model (`museglimmer-30b-64k`, 65536) is a
  conservative placeholder and has **not** been measured on 24 GB hardware. Its cheap KV
  suggests it can go higher. That branch is code-only config that no current hardware runs.
- Q6_K_XL (24.5 GB) is worth a prose bench given the ~11 GB of spare VRAM at Q4.
- Ollama 0.32.11 is a pre-release. Revisit when a stable release supersedes it.
## §BW. Creative-writing bench retired (2026-08-13)

The `cw1`/`cw2`/`cw3` shortlist opened in §BP has been resolved and dismantled. This supersedes
the "Still open" note in the 2026-08-01 sweep, which stated that the creative-writing A/B was not
superseded. It now is.

### What decided it

The A/B never got a hands-on verdict on real cover letters, so it was resolved mechanically
instead. A scored cover-letter bench was run against @jsquire's own accepted Riot Games letter and
job description as the reference target, over two rounds at 20000 predict tokens. Ornith-1.0-35B
won on best score and average, at roughly 3.5x the generation speed of the nearest contender, with
zero em-dashes and zero unsupported claims.

| Model | Best | Avg | tok/s | Em-dash | Unsupported |
|---|---|---|---|---|---|
| ornith-35b-256k | 100 | 97.5 | 245.8 | 0 | 0 |
| muse-glimmer:30b | 95 | 95 | 68.6 | 0 | 0 |
| glm47-flash-198k | 94 | 87 | 181.1 | 2 | 1 |

@jsquire confirmed the result in use and blessed Ornith as the production creative model.

### What was removed

None of the three shortlist entries won, so all three were retired rather than kept as a standing
bench. Removed from `scripts/local-models.json`: registry entries `qwen3-32b-64k`,
`qwen25-32b-32k`, `commandr-35b-64k`, the `cw1`/`cw2`/`cw3` aliases, and the "Creative-writing
bench" category from both the copilot and crush experimental menus. The experimental menu is now
contiguous 1 to 10 in both launchers, so no renumbering was needed. The six Ollama artifacts
(three aliases plus the three base pulls) were deleted from the model store.

None of the three ever appeared in `windows/install-windows.ps1`, so fresh installs never
provisioned them and the installer needed no change.

The `creative` slot and copilot key 5 continue to point at `ornith-35b-256k`.

### Note on the licence gate

The standing caution about Command R's CC-BY-NC-4.0 licence is now moot for this roster, since the
model is gone. It is retained in the §BP and Laguna licensing text as history. Ornith-1.0-35B is
MIT, so the production creative slot carries no non-commercial restriction.