# local-llm launcher test harness

Regression tests for the data-driven launchers, the switch daemon, and the installer roster generation.

## Run

    bash tests/run-all.sh                                   # schema, daemon, .sh parity, token budgets, installer-gen
    powershell -File tests\run-all.ps1                      # schema (PS), .ps1 parity, token budgets, imagegen

Both exit non-zero on any failure. A run needs `python3`, `curl`, and `git`. On Windows the PowerShell
suites prefer a native `python3` and fall back to `wsl python3` only if none is on PATH. No GPU,
model server, `copilot`/`crush` binary, or network is required.

## What it proves

- **schema** - the roster JSON is internally consistent and parses in both python3 and PowerShell.
- **daemon** - `vllm-switch-web.py` serves `/models` (no `unit` leak), renders its page from the roster,
  enforces the `/switch` whitelist + limits, and falls back to a built-in roster on a missing/bad file.
- **launcher parity** - every menu selection (and the direct/arg paths) resolves to the *same* model, base
  URL, MCP/office flags, and `.crush.json` as the **pre-refactor** launchers
  (`git cf852ee^`). This is the guarantee that data-driving the rosters changed no behaviour.
  The token-budget fields are masked on both sides of this comparison (see below) and are covered by
  their own suite instead.
- **token budgets** - local token caps are derived from the selected model's registry `ctx`
  (`copilot` prompt = `floor(ctx * 0.75)` and output = `min(16384, ctx - prompt)`; `crush`
  `max_tokens` = `min(16384, floor(ctx / 4))`), while squire-server picks keep their
  roster-advertised caps. Asserted against explicit numbers, not a re-derivation of the launcher's
  own formula, in both `test_token_budgets.ps1` and `test_token_budgets.sh`.
- **installer-gen** - `write_local_models_json` produces valid, tier-correct `local-models.json` for
  4090/5090 with and without `--test-profiles`.

## Isolation

Tests never touch the real system: each launcher runs in a throwaway sandbox with `HOME`/`USERPROFILE` and
CWD redirected to temp dirs, `PATH` prefixed with `tests/stubs/` (fake `curl`/`copilot`/`crush`/`clear`/`ollama`
that fail-closed on any real host), and the daemon suite runs a private instance with
`VLLM_SWITCH_CMD=/bin/true`. `run-all.sh` asserts the real `~/.config/local-llm` is untouched afterward.

## Golden files

`fixtures/golden-*.tsv` freeze the expected per-selection results, generated from the pre-refactor baseline:

    bash tests/test_launchers_parity.sh --rebuild-golden          # bash golden
    powershell -File tests\test_launchers_parity.ps1 -RebuildGolden   # PowerShell golden

Commit them; the check-mode runs compare current output against these frozen values. bash and PowerShell have
their own goldens because of two documented pre-existing platform differences (the office-skill file guard and
the direct-model MCP handling).

**`--rebuild-golden` cannot absorb an intentional behaviour change.** It regenerates from `cf852ee^`
via `git show`, so it reproduces the old behaviour by design; re-running it will not bless a new
value, it will just restore the baseline. When a field is deliberately changed after the baseline,
mask it on *both* sides of the comparison (`mask_budget` / `Mask-Budget`) and assert it in a
dedicated suite. The value is masked rather than the key removed, so a field vanishing entirely is
still a failure.
