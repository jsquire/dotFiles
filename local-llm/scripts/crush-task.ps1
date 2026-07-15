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
      Documents   — office authoring (docx/pptx/xlsx) via the 'office' skill: the
                    model writes python-docx/python-pptx/openpyxl and runs it with uv.
                    No document MCP servers — the skill costs almost no context.
      Image       — imagegen-mcp (image generation)

    The .crush.json is written to the current directory. Crush merges it
    on top of the global config at ~/.config/crush/crush.json.
#>

param(
    [ValidateSet("coding", "review", "docs", "image")]
    [string]$Task,
    [string]$Model
)

# -- Provider gating (local Ollama / remote squire-server) ---------------------
# Baked in by the installer; falls back to both if the placeholder was not substituted.
$LlProviders = "__LL_PROVIDERS__"
if ($LlProviders -like "*__*" -or [string]::IsNullOrWhiteSpace($LlProviders)) { $LlProviders = "local,server" }
function Test-LlProvider { param([string]$Name) return ((",$LlProviders,") -like "*,$Name,*") }

# Switch the squire-server's active model via the accountless web endpoint (:4090). The server
# loads one model at a time, so POST the mode then poll /status until it is ready before launching
# Crush (so we never hand Crush a not-yet-loaded model).
function Invoke-SquireSwitch {
    param([string]$Mode)
    $ip = "__SQUIRE_SERVER_IP__"; $port = "4090"
    try {
        Invoke-RestMethod -Uri "http://${ip}:${port}/switch" -Method Post -ContentType 'application/json' `
            -Body "{`"mode`":`"$Mode`"}" -TimeoutSec 10 -ErrorAction Stop | Out-Null
    } catch {
        Write-Host "  WARN: could not reach the model-switch service at http://${ip}:${port}/ - is the server up?"
        return
    }
    Write-Host -NoNewline "  ... switching server to $Mode"
    for ($i = 0; $i -lt 30; $i++) {
        try {
            $st = Invoke-RestMethod -Uri "http://${ip}:${port}/status" -TimeoutSec 5 -ErrorAction Stop
            if ($st.mode -eq $Mode -and $st.api_up) { Write-Host " - ready."; return }
        } catch {}
        Write-Host -NoNewline "."
        Start-Sleep -Seconds 3
    }
    Write-Host " (still loading; give it a few more seconds)"
}

$DefaultModel = if ($Model) { $Model } else { "qwen36-128k" }
$ReviewModel  = "qwen3coder-65k"

# 5090 model assignments per task profile
$ModelByTask = @{
    coding  = "qwen36-27b-212k"   # heavy coding default (Qwen3.6-27B dense)
    review  = "qwen3coder-144k"   # Qwen3-Coder 30B-A3B
    docs    = "glm47-flash-198k"  # GLM-4.7-Flash for office authoring (roomy, capable)
    image   = "qwen3:8b"          # image-gen companion (HiDream)
}
$SelectedModel = $null
$OffloadMode = $false
$Provider = "ollama"
$SwitchMode = $null
$ServerMcp = $null

function Write-CrushConfig {
    param(
        [hashtable]$McpOverrides,
        [string]$SystemPromptPrefix,
        [string]$Model,
        [string]$Provider = "ollama",
        [string]$ActiveLabel
    )
    $config = @{ mcp = $McpOverrides }
    # Output cap + assumed window, by provider. Server window per mode: coder/devstral
    # 56K, glm 54K, mistral 64K, image companion 32K -> cap output at 8K so agentic context isn't starved
    # (image companion caps output at 2K — it only emits a small tool call). Local Ollama runs 128K-256K
    # windows, so a larger 32K cap is cheap.
    $maxTok = 16384; $ctxWin = 65536
    if ($Provider -eq "server") {
        $maxTok = 8192
        switch ($ActiveLabel) {
            "mistral-small" { $ctxWin = 65536 }
            "glm-4.7-flash" { $ctxWin = 55296 }
            "qwen3-coder"   { $ctxWin = 57344 }
            "devstral"      { $ctxWin = 57344 }
            "qwen3-4b"      { $ctxWin = 32768; $maxTok = 2048 }  # image companion: 1.7B, 32K served; small output (tool call only)
            default         { $ctxWin = 32768 }
        }
    }
    $providerBlock = @{}
    # Server provider: expose ONE 'active-model' entry (so /model can't pick a not-yet-loaded model),
    # relabeled "Active: <model>" for visibility.
    if ($ActiveLabel) {
        $providerBlock["models"] = @(
            @{ name = "Active: $ActiveLabel"; id = "active-model"; context_window = $ctxWin; default_max_tokens = $maxTok }
        )
    }
    if ($SystemPromptPrefix) {
        $providerBlock["system_prompt_prefix"] = $SystemPromptPrefix
    }
    if ($providerBlock.Count -gt 0) {
        $config["providers"] = @{ $Provider = $providerBlock }
    }
    if ($Model) {
        $config["models"] = @{
            "large" = @{
                "model" = $Model
                "provider" = $Provider
                "max_tokens" = $maxTok
            }
            "small" = @{
                "model" = $Model
                "provider" = $Provider
                "max_tokens" = $maxTok
            }
        }
    }
    $json = $config | ConvertTo-Json -Depth 5
    Set-Content -Path ".crush.json" -Value $json -Encoding UTF8
}

# If no task specified, show picker
if (-not $Task) {
    $e = [char]27
    $Frame = "$e[38;5;25m"; $Text = "$e[97m"; $Rst = "$e[0m"
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
    $W = 110
    $Bar = ([string][char]0x2550) * $W
    function Show-Top { Write-Host ("  $Frame" + [char]0x2554 + $Bar + [char]0x2557 + $Rst) }
    function Show-Mid { Write-Host ("  $Frame" + [char]0x2560 + $Bar + [char]0x2563 + $Rst) }
    function Show-Bot { Write-Host ("  $Frame" + [char]0x255A + $Bar + [char]0x255D + $Rst) }
    function Show-Line { param([string]$s)
        if ($s.Length -gt $W) { $s = $s.Substring(0, $W) }
        Write-Host ("  $Frame" + [char]0x2551 + $Text + $s.PadRight($W) + $Frame + [char]0x2551 + $Rst)
    }
    function Show-Center { param([string]$s) $p = [math]::Max(0, [math]::Floor(($W - $s.Length) / 2)); Show-Line ((" " * $p) + $s) }
    function Show-Row { param([string]$k, [string]$l, [string]$d)
        $kf = ("[$k]").PadRight(5)
        if ($l.Length -gt 26) { $l = $l.Substring(0, 26) }
        Show-Line ("       $kf " + $l.PadRight(26) + " $d")
    }
    $hasLocal  = Test-LlProvider 'local'
    $hasServer = Test-LlProvider 'server'
    $choice = ""
    $menuErr = ""
    $page = if ($hasLocal) { "env" } else { "server" }
    :picker while ($true) {
        Clear-Host
        Write-Host ""
        switch ($page) {
            "env" {
                Show-Top; Show-Center "Crush"; Show-Line ""; Show-Center "pick an environment"; Show-Mid
                Show-Line ""
                Show-Line "     [1]  Local";                Show-Line "          Production daily-drivers"; Show-Line ""
                Show-Line "     [2]  Local - Experimental"; Show-Line "          Models under evaluation"
                if ($hasServer) { Show-Line ""; Show-Line "     [3]  Squire-Server"; Show-Line "          Models hosted on the server" }
                Show-Line ""; Show-Line ""; Show-Line "     [Q]  Quit"; Show-Line ""; Show-Bot; Write-Host ""
                if ($menuErr) { Write-Host "   $menuErr"; $menuErr = "" }
                $sel = Read-Host "   Your choice [1]"; if (-not $sel) { $sel = "1" }
                switch ($sel) {
                    "1" { $page = "local" }
                    "2" { $page = "exp" }
                    "3" { if ($hasServer) { $page = "server" } else { $menuErr = "Invalid selection, try again." } }
                    "Q" { Clear-Host; exit }
                    default { $menuErr = "Invalid selection, try again." }
                }
            }
            "local" {
                Show-Top; Show-Center "Crush"; Show-Line ""; Show-Center "local : production models"; Show-Mid
                Show-Line ""
                Show-Line "     Coding"
                Show-Line "     ------"
                Show-Line ""
                Show-Row "1" "Heavy coding" "Qwen3.6 27B dense"
                Show-Row "2" "Light coding" "Qwen3-Coder 30B"
                Show-Row "3" "Code review" "Qwen3-Coder 30B"
                Show-Line ""
                Show-Line ""
                Show-Line "     Writing & Documents"
                Show-Line "     -------------------"
                Show-Line ""
                Show-Row "4" "Documents" "GLM-4.7-Flash + office skill"
                Show-Line ""
                Show-Line ""
                Show-Line "     Visual"
                Show-Line "     ------"
                Show-Line ""
                Show-Row "5" "Image generation" "Qwen3 8B + HiDream (MCP)"
                Show-Line ""; Show-Line ""; Show-Line ""; Show-Row "B" "Back to environments" ""; Show-Row "Q" "Quit" ""; Show-Line ""
                Show-Bot; Write-Host ""
                if ($menuErr) { Write-Host "   $menuErr"; $menuErr = "" }
                $sel = Read-Host "   Your choice [1]"; if (-not $sel) { $sel = "1" }
                if ($sel.ToUpper() -eq "Q") { Clear-Host; exit }
                if ($sel.ToUpper() -eq "B") { $page = "env"; continue picker }
                if ($sel -match '^[1-5]$') { $choice = $sel; break picker }
                $menuErr = "Invalid selection, try again."
            }
            "exp" {
                Show-Top; Show-Center "Crush"; Show-Line ""; Show-Center "local : models under evaluation"; Show-Mid
                Show-Line ""
                Show-Line "     Heavy-coding bench"
                Show-Line "         (coding profile, swap model)"
                Show-Line ("     " + ("-" * 32))
                Show-Line ""
                Show-Row "1" "Qwen3.6 27B dense" "qwen36-27b-212k"
                Show-Row "2" "Qwen3.6 35B-A3B MoE" "qwen36-35b-256k"
                Show-Row "3" "Gemma 4 31B dense" "gemma4-31b-128k"
                Show-Row "4" "Qwen3-Coder 30B-A3B" "qwen3coder-144k"
                Show-Row "5" "GLM-4.7-Flash" "glm47-flash-198k"
                Show-Row "6" "North Mini Code 1.0" "northmini-code-256k"
                Show-Row "7" "Nemotron 3 Nano 30B" "nemotron3-nano-256k"
                Show-Row "8" "Ornith-1.0-35B" "ornith-35b-256k"
                Show-Row "9" "Devstral Small 2 24B" "devstral2-24b-128k"
                Show-Line ""
                Show-Line ""
                Show-Line "     Big-MoE expert-offload bench"
                Show-Line "         (experts to RAM; slower)"
                Show-Line ("     " + ("-" * 28))
                Show-Line ""
                Show-Row "10" "Qwen3-Next-80B-A3B" "offload, Q4_K_M ~45 GB"
                Show-Line ""; Show-Line ""; Show-Line ""; Show-Row "B" "Back to environments" ""; Show-Row "Q" "Quit" ""; Show-Line ""
                Show-Bot; Write-Host ""
                if ($menuErr) { Write-Host "   $menuErr"; $menuErr = "" }
                $sel = Read-Host "   Your choice [1]"; if (-not $sel) { $sel = "1" }
                if ($sel.ToUpper() -eq "Q") { Clear-Host; exit }
                if ($sel.ToUpper() -eq "B") { $page = "env"; continue picker }
                if ($sel -match '^[1-9]$') { $choice = "H$sel"; break picker }
                if ($sel -eq "10") { $choice = "O2"; break picker }
                $menuErr = "Invalid selection, try again."
            }
            "server" {
                Show-Top; Show-Center "Crush"; Show-Line ""; Show-Center "squire-server : remote models"; Show-Mid
                Show-Line ""
                Show-Line "     Remote"
                Show-Line "         (server - switches the standing model on pick)"
                Show-Line ("     " + ("-" * 50))
                Show-Line ""
                Show-Row "1" "Mistral-Small" "default : office/authoring, 64K"
                Show-Row "2" "GLM-4.7-Flash" "agentic / reasoning"
                Show-Row "3" "Qwen3-Coder" "coding-first"
                Show-Row "4" "Devstral-2 24B" "coding-alt, agentic"
                Show-Row "5" "Image gen" "HiDream + Qwen3-4B"
                Show-Line ""; Show-Line ""; Show-Line ""
                if ($hasLocal) { Show-Row "B" "Back to environments" "" }
                Show-Row "Q" "Quit" ""; Show-Line ""
                Show-Bot; Write-Host ""
                if ($menuErr) { Write-Host "   $menuErr"; $menuErr = "" }
                $sel = Read-Host "   Your choice [1]"; if (-not $sel) { $sel = "1" }
                if ($sel.ToUpper() -eq "Q") { Clear-Host; exit }
                if ($sel.ToUpper() -eq "B" -and $hasLocal) { $page = "env"; continue picker }
                $map = @{ "1" = "S"; "2" = "G"; "3" = "C"; "4" = "D"; "5" = "I" }
                if ($map.ContainsKey($sel)) { $choice = $map[$sel]; break picker }
                $menuErr = "Invalid selection, try again."
            }
        }
    }


    switch ($choice.ToUpper()) {
        "1"  { $Task = "coding" }
        "2"  { $Task = "coding"; $SelectedModel = "qwen3coder-144k" }
        "3"  { $Task = "review" }
        "4"  { $Task = "docs" }
        "5"  { $Task = "image" }
        "H1" { $Task = "coding"; $SelectedModel = "qwen36-27b-212k" }
        "H2" { $Task = "coding"; $SelectedModel = "qwen36-35b-256k" }
        "H3" { $Task = "coding"; $SelectedModel = "gemma4-31b-128k" }
        "H4" { $Task = "coding"; $SelectedModel = "qwen3coder-144k" }
        "H5" { $Task = "coding"; $SelectedModel = "glm47-flash-198k" }
        "H6" { $Task = "coding"; $SelectedModel = "northmini-code-256k" }
        "H7" { $Task = "coding"; $SelectedModel = "nemotron3-nano-256k" }
        "H8" { $Task = "coding"; $SelectedModel = "ornith-35b-256k" }
        "H9" { $Task = "coding"; $SelectedModel = "devstral2-24b-128k" }
        "O2" { $Task = "coding"; $SelectedModel = "qwen3next-80b-offload"; $OffloadMode = $true }
        "S"  { $Provider = "server"; $SwitchMode = "mistral";   $SelectedModel = "mistral-small"; $ServerMcp = @{ "imagegen-mcp" = @{ disabled = $true } } }
        "G"  { $Provider = "server"; $SwitchMode = "glm";       $SelectedModel = "glm-4.7-flash"; $ServerMcp = @{ "imagegen-mcp" = @{ disabled = $true } } }
        "C"  { $Provider = "server"; $SwitchMode = "coder";     $SelectedModel = "qwen3-coder";   $ServerMcp = @{ "imagegen-mcp" = @{ disabled = $true } } }
        "D"  { $Provider = "server"; $SwitchMode = "coder-alt"; $SelectedModel = "devstral";      $ServerMcp = @{ "imagegen-mcp" = @{ disabled = $true } } }
        "I"  { $Provider = "server"; $SwitchMode = "image";     $SelectedModel = "qwen3-4b";      $ServerMcp = @{ "imagegen-mcp" = @{ disabled = $false } } }
        default {
            Write-Host "  Invalid selection, defaulting to heavy coding."
            $Task = "coding"
        }
    }
}

# Friendly labels for the launch-identity banner (keyed on the resolved alias; doubles as the
# human-readable bench roster registry).
$ModelLabel = @{
    "qwen36-27b-212k"       = "Qwen3.6 27B (+MTP)"
    "qwen36-35b-256k"       = "Qwen3.6 35B-A3B MoE"
    "gemma4-31b-128k"       = "Gemma 4 31B dense"
    "qwen3coder-144k"       = "Qwen3-Coder 30B-A3B"
    "glm47-flash-198k"      = "GLM-4.7-Flash"
    "northmini-code-256k"   = "North Mini Code 1.0"
    "nemotron3-nano-256k"   = "Nemotron 3 Nano 30B-A3B"
    "ornith-35b-256k"       = "Ornith-1.0-35B"
    "devstral2-24b-128k"    = "Devstral Small 2 (24B)"
    "qwen3next-80b-offload" = "Qwen3-Next-80B-A3B (partial offload)"
    "mistral-small"         = "Mistral-Small (squire-server)"
    "glm-4.7-flash"         = "GLM-4.7-Flash (squire-server)"
    "qwen3-coder"           = "Qwen3-Coder (squire-server)"
    "devstral"              = "Devstral-2 24B (squire-server)"
    "qwen3-4b"              = "Qwen3-4B image companion (squire-server)"
}

# Resolve the model: explicit -Model wins, then picker selection, then per-task default.
if (-not $SelectedModel) {
    $SelectedModel = if ($Model) { $Model } else { $ModelByTask[$Task] }
}
$DefaultModel = $SelectedModel
$ReviewModel  = $SelectedModel

$ModelFriendly = if ($ModelLabel.ContainsKey($DefaultModel)) { $ModelLabel[$DefaultModel] } else { $DefaultModel }
Write-Host ""
Write-Host "  ▶ $ModelFriendly  ·  alias=$DefaultModel" -ForegroundColor Cyan

if ($Provider -eq "server") {
    if ($SwitchMode) { Invoke-SquireSwitch $SwitchMode }
    Write-CrushConfig -McpOverrides $ServerMcp -Model "active-model" -Provider "server" -ActiveLabel $SelectedModel
    Write-Host "  Profile: squire-server ($SelectedModel, addressed as active-model)"
}
else {
switch ($Task) {
    "coding" {
        Write-CrushConfig -McpOverrides @{
            "imagegen-mcp" = @{ disabled = $true }
        } -Model $DefaultModel
        Write-Host "  Profile: Coding ($DefaultModel, no MCP servers)"
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
            "imagegen-mcp" = @{ disabled = $true }
        } -SystemPromptPrefix $reviewGuide -Model $ReviewModel
        Write-Host "  Profile: Code review (Qwen3-Coder 30B)"
    }
    "docs" {
        # Office authoring uses the vendored 'office' skill (discovered natively by crush from
        # ~/.config/crush/skills/office). The model writes python-docx/python-pptx/openpyxl and
        # runs it via `uv run --with ...` — no document MCP servers, near-zero context cost.
        Write-CrushConfig -McpOverrides @{
            "imagegen-mcp" = @{ disabled = $true }
        } -Model $DefaultModel
        Write-Host "  Profile: Documents / office authoring ($DefaultModel + office skill: docx/pptx/xlsx via Python)"
    }
    "image" {
        Write-CrushConfig -McpOverrides @{
            "imagegen-mcp" = @{ disabled = $false }
        } -Model $SelectedModel
        Write-Host "  Profile: Image generation (HiDream) — using $SelectedModel for VRAM headroom"
    }
}
}

Write-Host "  Config: $(Resolve-Path .crush.json)"
Write-Host ""

if ($OffloadMode) {
    # Big-MoE offload mode: run a dedicated Ollama serve with expert CPU-offload, then
    # restore the managed server when Crush exits. The model alias already carries
    # num_gpu 99; offload-serve.ps1 sets LLAMA_ARG_N_CPU_MOE so experts spill to RAM.
    $offloadScript = Join-Path $PSScriptRoot "offload-serve.ps1"
    Write-Host "  Offload mode: experts -> system RAM (partial; slower than VRAM-resident)" -ForegroundColor DarkYellow
    & $offloadScript -Action start -NCpuMoe 24
    try {
        crush
    } finally {
        & $offloadScript -Action stop
    }
} else {
    crush
}
