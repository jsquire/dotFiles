# local-llm launcher test harness

Regression tests for the data-driven launchers, the switch daemon, and the installer roster generation.

## Run

    bash tests/run-all.sh                                   # schema, daemon, .sh parity, installer-gen
    powershell -File tests\run-all.ps1                      # schema (PS), .ps1 parity

Both exit non-zero on any failure. A run needs `python3` (via WSL on Windows), `curl`, and `git`. No GPU,
model server, `copilot`/`crush` binary, or network is required.

## What it proves

- **schema** - the roster JSON is internally consistent and parses in both python3 and PowerShell.
- **daemon** - `vllm-switch-web.py` serves `/models` (no `unit` leak), renders its page from the roster,
  enforces the `/switch` whitelist + limits, and falls back to a built-in roster on a missing/bad file.
- **launcher parity** - every menu selection (and the direct/arg paths) resolves to the *same* model, base
  URL, token caps, MCP/office/offload flags, and `.crush.json` as the **pre-refactor** launchers
  (`git cf852ee^`). This is the guarantee that data-driving the rosters changed no behaviour.
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
