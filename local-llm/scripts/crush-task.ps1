<#
.SYNOPSIS
    Task picker for Crush — writes a project-level .crush.json with the right
    MCP servers enabled for the selected task, then launches Crush.

.DESCRIPTION
    Each task profile enables only the MCP servers relevant to that task,
    keeping the tool count low so the model can reliably use them all.

    Profiles:
      Coding  — no MCP servers (code tools only)
      Office  — word-mcp + pptx-mcp (document editing)
      Image   — imagegen-mcp (image generation)
      All     — everything enabled (may degrade with smaller models)

    The .crush.json is written to the current directory. Crush merges it
    on top of the global config at ~/.config/crush/crush.json.
#>

param(
    [ValidateSet("coding", "office", "image", "all")]
    [string]$Task
)

function Write-CrushConfig {
    param(
        [hashtable]$McpOverrides
    )
    $config = @{ mcp = $McpOverrides }
    $json = $config | ConvertTo-Json -Depth 4
    Set-Content -Path ".crush.json" -Value $json -Encoding UTF8
}

# If no task specified, show picker
if (-not $Task) {
    Write-Host ""
    Write-Host "  --- Crush Task Profiles ---"
    Write-Host "  [1] Coding          (no MCP — fast, all context for code)"
    Write-Host "  [2] Office docs     (Word + PowerPoint MCP)"
    Write-Host "  [3] Image gen       (FLUX.1-schnell MCP)"
    Write-Host "  [4] All tools       (all MCP servers — may be slow)"
    Write-Host ""
    $choice = Read-Host "  Select profile [1]"
    if (-not $choice) { $choice = "1" }

    switch ($choice) {
        "1" { $Task = "coding" }
        "2" { $Task = "office" }
        "3" { $Task = "image" }
        "4" { $Task = "all" }
        default {
            Write-Host "  Invalid selection, defaulting to coding."
            $Task = "coding"
        }
    }
}

switch ($Task) {
    "coding" {
        Write-CrushConfig @{
            "word-mcp"     = @{ disabled = $true }
            "pptx-mcp"     = @{ disabled = $true }
            "imagegen-mcp" = @{ disabled = $true }
        }
        Write-Host "  Profile: Coding (no MCP servers)"
    }
    "office" {
        Write-CrushConfig @{
            "word-mcp"     = @{ disabled = $false }
            "pptx-mcp"     = @{ disabled = $false }
            "imagegen-mcp" = @{ disabled = $true }
        }
        Write-Host "  Profile: Office (Word + PowerPoint)"
    }
    "image" {
        Write-CrushConfig @{
            "word-mcp"     = @{ disabled = $true }
            "pptx-mcp"     = @{ disabled = $true }
            "imagegen-mcp" = @{ disabled = $false }
        }
        Write-Host "  Profile: Image generation (FLUX.1-schnell)"
    }
    "all" {
        Write-CrushConfig @{
            "word-mcp"     = @{ disabled = $false }
            "pptx-mcp"     = @{ disabled = $false }
            "imagegen-mcp" = @{ disabled = $false }
        }
        Write-Host "  Profile: All tools (93 MCP tools — may be slow with smaller models)"
    }
}

Write-Host "  Config: $(Resolve-Path .crush.json)"
Write-Host ""

crush
