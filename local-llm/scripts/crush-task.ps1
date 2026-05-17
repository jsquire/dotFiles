<#
.SYNOPSIS
    Task picker for Crush — writes a project-level .crush.json with the right
    MCP servers enabled for the selected task, then launches Crush.

.DESCRIPTION
    Each task profile enables only the MCP servers relevant to that task,
    keeping the tool count low so the model can reliably use them all.

    Profiles:
      Coding      — no MCP servers (code tools only)
      Word        — word-mcp only (Word document editing)
      PowerPoint  — pptx-mcp only (PowerPoint editing)
      Image       — imagegen-mcp (image generation)
      All         — everything enabled (may degrade with smaller models)

    The .crush.json is written to the current directory. Crush merges it
    on top of the global config at ~/.config/crush/crush.json.
#>

param(
    [ValidateSet("coding", "review", "word", "pptx", "docs", "image", "all")]
    [string]$Task
)

$DefaultModel = "gemma4-65k"
$ReviewModel  = "qwen25coder-65k"

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
                "max_tokens" = 8000
            }
        }
    }
    $json = $config | ConvertTo-Json -Depth 5
    Set-Content -Path ".crush.json" -Value $json -Encoding UTF8
}

# If no task specified, show picker
if (-not $Task) {
    Write-Host ""
    Write-Host "  --- Crush Task Profiles ---"
    Write-Host "  [1] Coding          (no MCP - fast, all context for code)"
    Write-Host "  [2] Code review     (Qwen2.5-Coder - different perspective)"
    Write-Host "  [3] Word docs       (Word MCP only - 54 tools)"
    Write-Host "  [4] PowerPoint      (PPTX MCP only - 37 tools)"
    Write-Host "  [5] Document create (guided co-authoring workflow)"
    Write-Host "  [6] Image gen       (FLUX.1-schnell MCP)"
    Write-Host "  [7] All tools       (all MCP servers - may be slow)"
    Write-Host ""
    $choice = Read-Host "  Select profile [1]"
    if (-not $choice) { $choice = "1" }

    switch ($choice) {
        "1" { $Task = "coding" }
        "2" { $Task = "review" }
        "3" { $Task = "word" }
        "4" { $Task = "pptx" }
        "5" { $Task = "docs" }
        "6" { $Task = "image" }
        "7" { $Task = "all" }
        default {
            Write-Host "  Invalid selection, defaulting to coding."
            $Task = "coding"
        }
    }
}

switch ($Task) {
    "coding" {
        Write-CrushConfig -McpOverrides @{
            "word-mcp"     = @{ disabled = $true }
            "pptx-mcp"     = @{ disabled = $true }
            "imagegen-mcp" = @{ disabled = $true }
        } -Model $DefaultModel
        Write-Host "  Profile: Coding (no MCP servers)"
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
        Write-Host "  Profile: Code review (Qwen2.5-Coder 14B)"
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
        $env:CRUSH_SHORT_TOOL_DESCRIPTIONS = "1"
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
        Write-Host "  Profile: Document creation (doc-coauthoring skill + Word MCP)"
    }
    "image" {
        Write-CrushConfig -McpOverrides @{
            "word-mcp"     = @{ disabled = $true }
            "pptx-mcp"     = @{ disabled = $true }
            "imagegen-mcp" = @{ disabled = $false }
        } -Model "qwen3:14b"
        Write-Host "  Profile: Image generation (FLUX.1-schnell) — using qwen3:14b for VRAM headroom"
    }
    "all" {
        $env:CRUSH_SHORT_TOOL_DESCRIPTIONS = "1"
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

crush
