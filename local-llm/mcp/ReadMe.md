# MCP servers & office authoring

This stack keeps its always-on tool surface tiny. Only **one** MCP server ships enabled:
`imagegen-mcp` (HiDream image generation), which genuinely needs a tool call to drive the
image pipeline.

Office authoring (Word / PowerPoint / Excel) is **no longer done via MCP servers**.

## Why office MCP was retired

The office MCP servers (`ppt-mcp`, `docx-mcp-server`, `office-powerpoint-mcp-server`) injected
their full tool schemas into **every** request, always-on:

- `pptx-mcp` ≈ 154 tools
- `docx-mcp-server` ≈ 45 tools
- `office-powerpoint-mcp-server` ≈ 32 tools

That is roughly **37K tokens of tool schema on every call** — before any user content. Served
context windows here are 32K (coder/devstral/image), 45K (glm), and 65K (mistral), so the tool
surface alone exceeded most windows and requests failed before the prompt was even considered.
This is unfixable by token tuning, so office MCP was removed entirely.

## The replacement: the `office` skill (code generation)

Office authoring now runs as a lean, vendored Crush skill at
`config/skills/office/SKILL.md` (deployed to `~/.config/crush/skills/office/SKILL.md`).

Instead of calling MCP tools, the model **writes a short Python script** using
[`python-docx`](https://python-docx.readthedocs.io/),
[`python-pptx`](https://python-pptx.readthedocs.io/), and
[`openpyxl`](https://openpyxl.readthedocs.io/), then runs it with `uv`:

```bash
uv run --with python-docx --with python-pptx --with openpyxl script.py
```

This costs **zero standing tokens** (Crush loads the skill body on demand via progressive
disclosure; Copilot CLI injects it via `--custom-instructions`), works on every window including
the 32K server modes, and is host-agnostic (uv caches the wheels — no venv paths baked in).

### How each launcher exposes it

- **crush-task** — the office skill is discovered natively from the deployed skills directory.
- **copilot-local** — the "Office documents" profile passes
  `--custom-instructions <deployed office SKILL.md>` (Copilot CLI has no native skill discovery).

## Warming the uv cache

The installers prime the uv wheel cache once so document authoring works offline afterward. To
re-run the warm-up manually:

```powershell
# Windows
.\setup-mcp-venvs.ps1
```

```bash
# Linux
./setup-mcp-venvs.sh
```

## Templates

Place branded `.docx` / `.pptx` template files in `mcp/templates/`. The generated Python can open
a template as a starting point (`Document("template.docx")` / `Presentation("template.pptx")`) to
apply your styles, logos, and formatting.
