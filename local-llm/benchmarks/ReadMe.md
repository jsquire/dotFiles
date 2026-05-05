# Benchmarks

### Overview

This directory supports the bake-off evaluation framework (Phase 4) and ongoing model comparison.  Its purpose is to make AI assistant quality measurable and reproducible across model changes, quantization levels, and hardware configurations.

### Structure

* **tasks/**  
  _Structured prompt definitions organized by category.  Each task has a clear expected outcome (correct code, valid document, accurate answer) so results can be objectively scored._

* **results/**  
  _Timestamped result files recording model tag, quantization, hardware, token speed (tok/s), time-to-completion, and a pass/fail/partial quality score.  Results are committed to the repository to build a longitudinal baseline._

### What It Answers

- Is 27B Q3_K_M sufficient for daily use, or is cloud fallback needed too often?
- How does Qwen 3.6 compare to DeepSeek R1 on tool-calling reliability?
- After a hardware upgrade (e.g., RTX 5090), how much did Q4_K_M improve over Q3_K_M?
- When a new model release drops, how does it compare to the current baseline?

### How to Use

1. Pick a task from `tasks/` (or define a new one following the format)
2. Run it against a model using Crush or `ollama run`
3. Record the result in `results/` using the format below
4. Compare across runs to make data-driven model/hardware decisions

### Task Format

Each task file contains multiple tasks in this format:

```markdown
## Task: [Short Name]

**Category:** coding | sysadmin | document | reasoning
**Difficulty:** easy | medium | hard
**Expected time:** <target seconds for acceptable response>

### Prompt

> [The exact prompt to give to the model]

### Expected Outcome

[What a correct/good answer looks like — enough detail to score objectively]

### Scoring

- **Pass:** [criteria]
- **Partial:** [criteria]
- **Fail:** [criteria]
```

### Result Format

Result files are named `YYYY-MM-DD-model-tag.md` and contain:

```markdown
# Benchmark Run: [date]

| Field | Value |
|-------|-------|
| **Date** | YYYY-MM-DD |
| **Model** | qwen3:30b |
| **Quantization** | Q4_K_M |
| **Hardware** | RTX 4090 24GB / Ryzen 7900X / 64GB DDR5 |
| **Profile** | Standard |

## Results

| Task | Category | Time (s) | Tok/s | Score | Notes |
|------|----------|----------|-------|-------|-------|
| reverse-linked-list | coding | 12.3 | 45.2 | Pass | Clean implementation |
| ... | ... | ... | ... | ... | ... |

## Summary

- **Pass rate:** X/Y
- **Average tok/s:** Z
- **Notes:** [observations, comparison to previous runs]
```
