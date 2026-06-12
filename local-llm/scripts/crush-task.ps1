<#
.SYNOPSIS
    Task picker for Crush — writes a project-level .crush.json with the right
    MCP servers enabled for the selected task, then launches Crush.

.DESCRIPTION
    Each task profile enables only the MCP servers relevant to that task,
    keeping the tool count low so the model can reliably use them all.

    Profiles:
      Coding      — no MCP servers (code tools + LSP only)
      Code review — Qwen3-Coder model, no MCP (different perspective)
      General     — Word MCP + gh CLI (research & document authoring)
      Word        — word-mcp only (Word document editing)
      PowerPoint  — pptx-mcp only (PowerPoint editing)
      Guided auth — doc-coauthoring skill + Word MCP (structured workflow)
      Image       — imagegen-mcp (image generation)
      All         — everything enabled (may degrade with smaller models)

    The .crush.json is written to the current directory. Crush merges it
    on top of the global config at ~/.config/crush/crush.json.
#>

param(
    [ValidateSet("general", "coding", "review", "word", "pptx", "docs", "image", "all")]
    [string]$Task,
    [string]$Model
)

$DefaultModel = if ($Model) { $Model } else { "qwen36-128k" }
$ReviewModel  = "qwen3coder-65k"

# 5090 model assignments per task profile
$ModelByTask = @{
    coding  = "qwen36-27b-256k"   # heavy coding default (Qwen3.6-27B dense)
    review  = "qwen3coder-256k"   # Qwen3-Coder 30B-A3B
    general = "glm47-flash-198k"  # GLM-4.7-Flash for all tool/MCP profiles
    word    = "glm47-flash-198k"
    pptx    = "glm47-flash-198k"
    docs    = "glm47-flash-198k"
    image   = "qwen3:8b"          # image-gen companion (HiDream)
    all     = "glm47-flash-198k"
}
$SelectedModel = $null
$OffloadMode = $false

function Write-CrushConfig {
    param(
        [hashtable]$McpOverrides,
        [string]$SystemPromptPrefix,
        [string]$Model
    )
    $config = @{ mcp = $McpOverrides }
    if ($SystemPromptPrefix) {
        $config["providers"] = @{
            "ollama" = @{
                "system_prompt_prefix" = $SystemPromptPrefix
            }
        }
    }
    if ($Model) {
        $config["models"] = @{
            "large" = @{
                "model" = $Model
                "provider" = "ollama"
                "max_tokens" = 32000
            }
            "small" = @{
                "model" = $Model
                "provider" = "ollama"
                "max_tokens" = 32000
            }
        }
    }
    $json = $config | ConvertTo-Json -Depth 5
    Set-Content -Path ".crush.json" -Value $json -Encoding UTF8
}

# If no task specified, show picker
if (-not $Task) {
    Write-Host ""
    Write-Host "  --- Coding ---"
    Write-Host "  [1] Heavy coding        (Qwen3.6 27B dense, no MCP)"
    Write-Host "  [2] Light coding        (Qwen3-Coder 30B, no MCP)"
    Write-Host "  [3] Code review         (Qwen3-Coder 30B, no MCP)"
    Write-Host ""
    Write-Host "  --- Writing & Documents ---"
    Write-Host "  [4] General research    (GLM-4.7-Flash + Word MCP)"
    Write-Host "  [5] Word editing        (GLM-4.7-Flash + Word MCP)"
    Write-Host "  [6] PowerPoint          (GLM-4.7-Flash + PPTX MCP)"
    Write-Host "  [7] Guided authoring    (GLM-4.7-Flash + doc skill)"
    Write-Host ""
    Write-Host "  --- Visual ---"
    Write-Host "  [8] Image generation    (Qwen3 8B + HiDream MCP)"
    Write-Host ""
    Write-Host "  --- Everything ---"
    Write-Host "  [9] All tools           (GLM-4.7-Flash, all MCP, may be slow)"
    Write-Host ""
    Write-Host "  --- Heavy-coding bench (coding profile, swap model) ---"
    Write-Host "  [H1] Qwen3.6 27B dense (default)"
    Write-Host "  [H2] Qwen3.6 35B-A3B MoE"
    Write-Host "  [H3] Gemma 4 31B dense"
    Write-Host "  [H4] Qwen3-Coder 30B-A3B"
    Write-Host "  [H5] GLM-4.7-Flash"
    Write-Host ""
    Write-Host "  --- Big-MoE expert-offload bench (experts->RAM; slower, for models that don't fit) ---"
    Write-Host "  [O1] gpt-oss-120b           (offload, ~65 GB MXFP4)"
    Write-Host "  [O2] Qwen3-Next-80B-A3B     (offload, needs imported Q4 GGUF)"
    Write-Host ""
    $choice = Read-Host "  Select profile [1]"
    if (-not $choice) { $choice = "1" }

    switch ($choice.ToUpper()) {
        "1"  { $Task = "coding" }
        "2"  { $Task = "coding"; $SelectedModel = "qwen3coder-256k" }
        "3"  { $Task = "review" }
        "4"  { $Task = "general" }
        "5"  { $Task = "word" }
        "6"  { $Task = "pptx" }
        "7"  { $Task = "docs" }
        "8"  { $Task = "image" }
        "9"  { $Task = "all" }
        "H1" { $Task = "coding"; $SelectedModel = "qwen36-27b-256k" }
        "H2" { $Task = "coding"; $SelectedModel = "qwen36-35b-256k" }
        "H3" { $Task = "coding"; $SelectedModel = "gemma4-31b-128k" }
        "H4" { $Task = "coding"; $SelectedModel = "qwen3coder-256k" }
        "H5" { $Task = "coding"; $SelectedModel = "glm47-flash-198k" }
        "O1" { $Task = "coding"; $SelectedModel = "gptoss-120b-offload";   $OffloadMode = $true }
        "O2" { $Task = "coding"; $SelectedModel = "qwen3next-80b-offload"; $OffloadMode = $true }
        default {
            Write-Host "  Invalid selection, defaulting to heavy coding."
            $Task = "coding"
        }
    }
}

# Resolve the model: explicit -Model wins, then picker selection, then per-task default.
if (-not $SelectedModel) {
    $SelectedModel = if ($Model) { $Model } else { $ModelByTask[$Task] }
}
$DefaultModel = $SelectedModel
$ReviewModel  = $SelectedModel

switch ($Task) {
    "coding" {
        Write-CrushConfig -McpOverrides @{
            "word-mcp"     = @{ disabled = $true }
            "pptx-mcp"     = @{ disabled = $true }
            "imagegen-mcp" = @{ disabled = $true }
        } -Model $DefaultModel
        Write-Host "  Profile: Coding ($DefaultModel, no MCP servers)"
    }
    "general" {
        Write-CrushConfig -McpOverrides @{
            "word-mcp"     = @{ disabled = $false }
            "pptx-mcp"     = @{ disabled = $true }
            "imagegen-mcp" = @{ disabled = $true }
        } -Model $DefaultModel
        Write-Host "  Profile: General (Word MCP + gh CLI)"
    }
    "review" {
        $reviewGuide = @"
You are a code reviewer. Focus on:
- Bugs, logic errors, and edge cases
- Security vulnerabilities (injection, auth, data exposure)
- Performance issues (N+1 queries, unnecessary allocations, blocking calls)
- API contract violations and type mismatches
- Concurrency issues (race conditions, deadlocks)
Do NOT comment on style, formatting, or naming conventions unless they cause bugs.
Be direct. If the code is correct, say so briefly.
"@
        Write-CrushConfig -McpOverrides @{
            "word-mcp"     = @{ disabled = $true }
            "pptx-mcp"     = @{ disabled = $true }
            "imagegen-mcp" = @{ disabled = $true }
        } -SystemPromptPrefix $reviewGuide -Model $ReviewModel
        Write-Host "  Profile: Code review (Qwen3-Coder 30B)"
    }
    "word" {
        $wordGuide = @"
docx-mcp-server Tool Guide:
This server edits Word documents via direct OOXML manipulation. Key tools:
- Open/create documents, then edit with tracked changes visible in Word
- search_and_replace: Find and replace text
- add_paragraph / add_heading / add_table: Add content
- format_text: Apply formatting
- Supports footnotes, endnotes, comments, headers/footers, sections
- All edits create real tracked changes (visible in Word's Review tab)
"@
        Write-CrushConfig -McpOverrides @{
            "word-mcp"     = @{ disabled = $false }
            "pptx-mcp"     = @{ disabled = $true }
            "imagegen-mcp" = @{ disabled = $true }
        } -SystemPromptPrefix $wordGuide -Model $DefaultModel
        Write-Host "  Profile: Word (docx-mcp-server, 45 tools)"
    }
    "pptx" {
        $pptxGuide = @"
IMPORTANT: Be concise. Do not explain what you will do — just do it. Minimize output.

ppt-mcp controls a live PowerPoint instance via COM automation (154 tools).

WORKFLOW: Open file in PowerPoint → ppt_activate_presentation → edit → ppt_save_presentation

ESSENTIAL TOOLS:
- ppt_activate_presentation (CALL FIRST after opening a file!)
- ppt_find_replace_text, ppt_set_text, ppt_get_text, ppt_get_all_text
- ppt_get_slide_info, ppt_list_slides, ppt_add_slide, ppt_delete_slide
- ppt_save_presentation, ppt_save_presentation_as (export to PDF/PNG)

ADVANCED TOOLS (use these for professional results):
- Charts: ppt_add_chart (20+ types: column, bar, line, pie, scatter, area, doughnut, radar)
  → ppt_set_chart_data → ppt_format_chart
- SmartArt: ppt_add_smartart (any layout: Process, Org Chart, Cycle, Funnel, Venn, Timeline)
  → ppt_modify_smartart (set_text, add_node, change_layout, change_color)
- Tables: ppt_add_table → ppt_set_table_data (batch write) → ppt_merge_table_cells
  → ppt_set_table_borders → ppt_set_table_style
- Themes: ppt_set_theme_colors (17 presets: corporate_blue, executive, nord_light, etc.
  OR auto-generate harmonious palette from one brand color)
- Animations: ppt_add_animation (entrance/exit/emphasis/motion path, 50+ effects)
  → ppt_set_slide_transition (fade, push, wipe, dissolve)
- Layout: ppt_align_shapes, ppt_distribute_shapes, ppt_merge_shapes (boolean ops)
- Icons: ppt_add_svg_icon (2500+ Material Symbols) → ppt_search_icons to find by keyword
- Typography: ppt_check_typography (auto-fix widow lines, shrunk text)

DESIGN PRINCIPLES:
- Set a bold color palette FIRST with ppt_set_theme_colors (don't default to blue)
- Every slide needs a visual element: image, chart, icon, SmartArt, or shape
- Don't repeat the same layout on consecutive slides
- Typography: Title 36-44pt bold, Body 14-16pt, Captions 10-12pt
- Use two-column, icon+text, grid, or half-bleed image layouts for variety

QA: After editing, use ppt_get_slide_preview on modified slides to verify visually.
Check for: overlapping elements, text overflow, low-contrast text, misaligned columns.
"@
        Write-CrushConfig -McpOverrides @{
            "word-mcp"     = @{ disabled = $true }
            "pptx-mcp"     = @{ disabled = $false }
            "imagegen-mcp" = @{ disabled = $true }
        } -SystemPromptPrefix $pptxGuide -Model $DefaultModel
        Write-Host "  Profile: PowerPoint (ppt-mcp COM, 154 tools, short descriptions)"
    }
    "docs" {
        # Download latest doc-coauthoring skill
        $docSkillDir = Join-Path $env:USERPROFILE ".config\crush\skills\doc-coauthoring"
        $docSkillFile = Join-Path $docSkillDir "SKILL.md"
        if (-not (Test-Path $docSkillDir)) { New-Item -ItemType Directory -Path $docSkillDir -Force | Out-Null }

        if (Test-Path $docSkillFile) {
            # Cached version exists — update in background, use cached now
            Start-Job -ScriptBlock {
                param($dir, $file)
                try {
                    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/anthropics/skills/main/skills/doc-coauthoring/SKILL.md" `
                        -OutFile $file -TimeoutSec 5 -ErrorAction Stop
                } catch {}
            } -ArgumentList $docSkillDir, $docSkillFile | Out-Null
            $docsGuide = Get-Content $docSkillFile -Raw
        } else {
            # No cached version — block on download
            Write-Host "  Downloading doc-coauthoring skill..."
            try {
                Invoke-WebRequest -Uri "https://raw.githubusercontent.com/anthropics/skills/main/skills/doc-coauthoring/SKILL.md" `
                    -OutFile $docSkillFile -TimeoutSec 10 -ErrorAction Stop
                $docsGuide = Get-Content $docSkillFile -Raw
            } catch {
                $docsGuide = "You are a document co-authoring assistant. Guide the user through structured document creation."
            }
        }

        Write-CrushConfig -McpOverrides @{
            "word-mcp"     = @{ disabled = $false }
            "pptx-mcp"     = @{ disabled = $true }
            "imagegen-mcp" = @{ disabled = $true }
        } -SystemPromptPrefix $docsGuide -Model $DefaultModel
        Write-Host "  Profile: Guided document authoring (doc-coauthoring skill + Word MCP)"
    }
    "image" {
        Write-CrushConfig -McpOverrides @{
            "word-mcp"     = @{ disabled = $true }
            "pptx-mcp"     = @{ disabled = $true }
            "imagegen-mcp" = @{ disabled = $false }
        } -Model $SelectedModel
        Write-Host "  Profile: Image generation (HiDream) — using $SelectedModel for VRAM headroom"
    }
    "all" {
        Write-CrushConfig -McpOverrides @{
            "word-mcp"     = @{ disabled = $false }
            "pptx-mcp"     = @{ disabled = $false }
            "imagegen-mcp" = @{ disabled = $false }
        } -Model $DefaultModel
        Write-Host "  Profile: All tools (93 MCP tools - may be slow with smaller models)"
    }
}

Write-Host "  Config: $(Resolve-Path .crush.json)"
Write-Host ""

if ($OffloadMode) {
    # Big-MoE offload mode: run a dedicated Ollama serve with expert CPU-offload, then
    # restore the managed server when Crush exits. The model alias already carries
    # num_gpu 99; offload-serve.ps1 sets LLAMA_ARG_CPU_MOE so experts spill to RAM.
    $offloadScript = Join-Path $PSScriptRoot "offload-serve.ps1"
    Write-Host "  Offload mode: experts -> system RAM (slower; for models that don't fit)" -ForegroundColor DarkYellow
    & $offloadScript -Action start
    try {
        crush
    } finally {
        & $offloadScript -Action stop
    }
} else {
    crush
}
