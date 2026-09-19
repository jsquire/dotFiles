# RTX 4090 vLLM candidate evaluation handoff

Use this document as the complete prompt for a new agent session running on the CachyOS
RTX 4090 server.

## Objective

Evaluate the exact checkpoint `nvidia/Qwen3.8-27B-NVFP4` as an isolated vLLM experiment.
Determine whether it is a viable replacement or experimental alternative for either:

- `qwen3-coder`, currently used for coding and Office documents.
- `mistral-small`, currently used for basic chat and general technical work.

Stop at an evidence-backed recommendation. Do not promote, deploy, register, or remove a
model unless the user gives a separate explicit directive.

## Required working context

Read these files before changing anything:

- `local-llm/cachyos/ReadMe.md`
- `local-llm/cachyos/server-models.json`
- `local-llm/cachyos/install-cachyos.sh`
- `local-llm/5090-model-evaluation.md`, especially sections BU, BX, and BY

The authoritative server roster is `local-llm/cachyos/server-models.json`.

Current server:

- CachyOS Linux
- NVIDIA RTX 4090 with 24 GiB VRAM
- 64 GiB system RAM
- vLLM server
- One model mode loaded at a time
- Mistral Small is the standing default at 65,536 context
- Qwen3-Coder is the coding and Office mode at 57,344 context
- Devstral Small 2 is the agentic coding and review mode at 57,344 context
- Existing modes must remain intact

## Candidate facts

Primary checkpoint:

- Repository: `nvidia/Qwen3.8-27B-NVFP4`
- Pinned revision: `482ca0f3832238542f8f5295dde86b5f22711d80`
- Published safetensors size: approximately 20.4 GiB
- Base model: Qwen3.8 27B
- License: Apache 2.0
- Format: NVIDIA ModelOpt mixed NVFP4/FP8
- Publisher examples use datacenter hardware, not an RTX 4090

Current vLLM documentation describes ModelOpt NVFP4 and weight-only NVFP4 support, including
Marlin fallback when native FP4 instructions are unavailable. This is generic runtime
support, not proof that this exact checkpoint, architecture, vision path, or tool template
works on this host.

The RTX 4090 does not have native FP4 tensor cores. Record the actual kernel and quantization
path. Do not describe the model as accelerated by native FP4 unless runtime evidence proves
that claim.

This candidate uses the same underlying model family already evaluated on the 5090. Treat it
as a serving-format and runtime experiment, not a presumed intelligence upgrade.

## Safety and change boundaries

- Do not edit `server-models.json`.
- Do not edit or redeploy the production installer.
- Do not replace or overwrite any existing systemd unit.
- Do not enable an experimental service at boot.
- Do not remove models, caches, environments, or rollback assets.
- Do not change NVIDIA drivers, CUDA, stable vLLM, or Python dependencies without first
  showing the exact need and receiving user approval.
- Do not send private repositories, credentials, or sensitive data to external services.
- Do not run Git commands unless the user explicitly asks.
- Preserve the current default mode and record its state before testing.
- If testing requires an interruption, show the exact services that would stop and wait for
  explicit user approval before interrupting them.
- Restore the original active mode after each approved experimental run.
- Put temporary scripts, logs, generated fixtures, and reports in the current session
  workspace, not in dotFiles or arbitrary system directories.

## Phase 1 - Read-only preflight

Record:

- Hostname and operating system.
- GPU model, driver, total memory, free memory, and current processes.
- Installed vLLM version and exact installation environment.
- CUDA and PyTorch versions.
- Free model-storage space.
- Current active model and systemd unit.
- Existing vLLM unit and environment-file conventions.
- Current `gpu-memory-utilization`, KV-cache dtype, tensor parallelism, maximum model length,
  maximum sequences, tool parser, reasoning parser, and served-name settings for Mistral,
  Qwen3-Coder, and Devstral.
- Whether the pinned candidate revision is already cached.
- Whether the installed stable vLLM version declares support for the checkpoint's exact
  architecture and quantization metadata.

Do not infer compatibility from the repository name or file extension.

## Phase 2 - Isolated loadability

Use an isolated foreground command or temporary experimental unit that does not overwrite an
existing unit. Keep its served name distinct from production.

Start with:

- One request at a time.
- 16,384 context.
- FP8 KV cache if supported by this exact model and runtime.
- The server's existing safe GPU-memory-utilization convention.
- No CPU offload.
- No speculative decoding.

Record:

- Exact checkpoint revision and downloaded bytes.
- Successful or failed engine initialization.
- Actual quantization and kernel path, including whether Marlin is used.
- GPU and system memory after load.
- Workspace allocation and remaining GPU headroom.
- Any repacking, compilation, or first-load latency.
- CPU spill, swap use, warnings, retries, or fallback.
- Declared capabilities, chat template, tool parser, reasoning parser, and vision support.

Stop the replacement track on reproducible load failure, OOM, silent CPU spill, unsupported
model architecture, missing required chat or tool behavior, or less than 2 GiB operational
GPU headroom. Preserve the complete error and classify the result as blocked or rejected.
Do not change quantization or download an unreviewed derivative to force a fit.

## Phase 3 - Context and concurrency

Only continue if the 16K load gate passes.

1. Exercise a genuinely occupied 16K prompt and produce a normal completion.
2. Increase to an occupied 32K prompt.
3. Test exact retrieval from the beginning, middle, and end of the occupied context.
4. Run one request, then two concurrent requests at 32K.
5. Record peak GPU memory, system memory, throughput, time to first useful output, errors,
   retries, and per-request completion.

Do not count a configured context limit as a context test. Prompts must occupy the tested
window and continue through useful generation.

The preferred server gate is two concurrent 32K requests with no OOM or CPU spill and at
least 10 generation tokens per second per request. A single-user or lower-context result may
still qualify as experimental, but not as a production replacement for an incumbent mode
with stronger capacity.

## Phase 4 - Paired behavior evaluation

Use public or synthetic fixtures only. Compare identical tasks and comparable budgets.

Compare against `qwen3-coder` for:

- Executed coding tasks in C#, Python, and PowerShell.
- A repository-style bug fix with hidden tests.
- Native tool-schema fidelity.
- Multi-step tools.
- Tool failure recovery.
- A constrained Office or technical-document workflow.

Compare against `mistral-small` for:

- General technical explanation.
- Grounded synthesis from supplied notes.
- Contradictory-source handling.
- A false-premise prompt.
- A nonexistent-publication prompt.
- Correct abstention when authoritative evidence is unavailable.

Run at least three repetitions for screening. Treat output truncation separately from wrong
answers. Thinking must not consume the entire answer budget. A claim to have searched or
verified a source is unsupported unless the tool trace proves it.

A fabricated citation, fabricated source, or approval-boundary violation blocks promotion
for this cycle. Speed cannot compensate for a correctness or grounding regression.

## Phase 5 - Performance comparison

Measure separately:

- Cold load.
- Warm time to first useful output.
- Unique-prompt prefill.
- Generation rate.
- End-to-end task time.
- Peak GPU and system memory.
- Remaining GPU headroom.
- One-request and two-request throughput.
- Errors, retries, and truncations.

Compare the candidate with the current Qwen3-Coder and Mistral modes at contexts each model
can safely sustain. Do not hide a reduced context or concurrency limit inside a single
aggregate score.

## Required output

Produce a report containing:

| Candidate | Compared role | Exact runtime and revision | Max verified context | Concurrency | Quality result | Performance result | Memory result | Decision |
|---|---|---|---:|---:|---|---|---|---|

Use one of these decisions:

- **Promote** when required quality and capabilities are preserved and a repeatable,
  operationally useful benefit is demonstrated.
- **Experimental** when useful but limited by context, concurrency, stability, or evidence.
- **Retain incumbent** when no clear benefit exists.
- **Reject or blocked** with the exact reproducible failure or missing prerequisite.

For any promotion recommendation, name the exact mode it would replace, the rollback mode,
the accepted regressions, and all remaining uncertainty. Stop before changing the roster,
installer, services, or production model storage.

## Secondary candidates

Do not start either secondary evaluation as part of the primary Qwen task unless the user
explicitly expands the session scope.

### Muse Glimmer NVFP4

- Repository: `nvidia/Muse-Glimmer-30B-NVFP4`
- Pinned revision: `47818374517751c48c55cde2621594926b1888b6`
- Published safetensors size: approximately 23.0 GiB

This is a lower-priority load-feasibility candidate. Its weights nearly consume the 4090's
usable memory before workspace and KV cache, so useful context and concurrency are doubtful.
The Ollama DFlash speedup measured on the 5090 does not transfer to this vLLM checkpoint. It
does not contain the promoted Ollama GGUF draft layer.

### DeepSeek V4.1 Flash

- Repository: `deepseek-ai/DeepSeek-V4.1-Flash`
- Pinned revision: `dba1be0a40aa45a94ad051997016db3960a90277`
- Official checkpoint size: approximately 475.2 GiB

DeepSeek V4.1 Flash is a separate hosted-service evaluation. It is not a local 4090
candidate. Any hosted session must choose and record the provider, pricing, served identity,
privacy terms, quotas, latency, and measured cost. Use only public or synthetic fixtures.

## Excluded from local 4090 testing

- DeepSeek V4.1 Flash local weights, approximately 475.2 GiB.
- NVIDIA DeepSeek V4.1 Flash NVFP4, approximately 491.1 GiB.
- Qwen3.8 Flash Next NVIDIA artifact, approximately 123.6 GiB.
- GLM-5.3 Flash and its NVIDIA NVFP4 artifact, 320B total parameters.

Do not spend server time attempting to load these artifacts. They exceed the available
memory envelope before runtime overhead.

## Primary sources

- `https://huggingface.co/nvidia/Qwen3.8-27B-NVFP4`
- `https://huggingface.co/nvidia/Muse-Glimmer-30B-NVFP4`
- `https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash`
- `https://docs.vllm.ai/en/latest/features/quantization/modelopt/`
- `https://api-docs.deepseek.com/updates/`
- `https://api-docs.deepseek.com/quick_start/pricing/`

Base conclusions only on local measurements and primary sources. State what remains unknown.
Avoid speculation and invented compatibility claims.
