# local-llm test harness

Regression tests for the canonical rosters, launchers, installer generation, switch daemon, proxy,
image tooling, Office skill deployment, and Windows removal symmetry.

## Run

```text
bash tests/run-all.sh
powershell -File tests\run-all.ps1
```

Both runners execute the dependency-controlled Python image suites through `uv`. They require
`python3` for Bash launcher helpers, PowerShell 5.1 or newer for Windows tests, and `uv` for isolated
Python dependencies. No Git command, GPU, model server, Copilot installation, or external network
endpoint is used by the tests themselves.

## Scenario proof

- **schema** validates canonical roster references and exact daemon fallback parity.
- **daemon** runs privately with a harmless switch command and covers routing, limits, fallback,
  whitelist enforcement, and HTML/JavaScript escaping.
- **launcher semantics** enumerates every canonical menu row dynamically. Bash and PowerShell use
  the same `semantic_oracle.py` for shared behavior, while platform-specific tests retain deliberate
  differences such as the Windows-only Qwen image profile.
- **launcher switch** uses stateful doubles to validate switch URL, JSON body, successful readiness,
  immediate failure, and bounded timeout behavior.
- **token budgets** asserts explicit canonical values independently from the launchers.
- **installer generation** validates every tier/profile combination and proves every visible row
  resolves through `task_alias` to `registry`.
- **image tests** cover environment routing, output paths, MCP backend identity, Qwen request
  validation, and the exact Turbo sigma schedule.
- **Office and Windows removal** verify deployment wiring and sandboxed removal symmetry.
- **proxy** exercises both supported chat routes through a private stub upstream.

## Isolation

Launcher executions use temporary HOME or USERPROFILE roots and fail-closed command doubles.
The complete runners recursively snapshot these protected live roots before and after execution:

- `~/.config/local-llm`
- `~/.copilot/mcp-config.json`
- `~/.copilot/skills/office`

Snapshots include path, object type, size, and content hash. Any child-file mutation fails the run.

## Canonical test data

Tests read `scripts/local-models.json` and `cachyos/server-models.json` directly. Installer tests
exercise generated deployment-equivalent rosters. Frozen pre-refactor fixtures and separate
platform goldens were removed because they no longer represented current production behavior.
