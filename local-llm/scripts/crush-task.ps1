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

# ── Box-drawing UI: dark-blue frame, white text, 110-wide ─────────────────────
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

# ── Data-driven model roster ─────────────────────────────────────────────────
# Local models come from local-models.json (installer-generated per GPU tier). Server models are
# advertised live by the switch daemon at :4090/models, with a bundled server-models.json fallback.
$ConfigDir = Join-Path $env:USERPROFILE ".config\local-llm"
$LocalModelsFile = $null
foreach ($cand in @((Join-Path $ConfigDir "local-models.json"), (Join-Path $PSScriptRoot "local-models.json"))) {
    if ($cand -and (Test-Path $cand)) { $LocalModelsFile = $cand; break }
}
if (-not $LocalModelsFile) { Write-Host "  ERROR: local-models.json not found (looked in $ConfigDir and beside the launcher)."; exit 1 }
$LM = Get-Content $LocalModelsFile -Raw | ConvertFrom-Json

function LL-Alias([string]$slot) { $p = $LM.task_alias.PSObject.Properties[$slot]; if ($p) { $p.Value } else { $slot } }
function LL-Label([string]$alias) { $p = $LM.registry.PSObject.Properties[$alias]; if ($p -and $p.Value.label) { $p.Value.label } else { $alias } }
function Model-ForTask([string]$t) {
    switch ($t) { "coding" { LL-Alias 'heavy' } "review" { LL-Alias 'review' } "docs" { LL-Alias 'agentic' } "image" { LL-Alias 'image_llm' } default { LL-Alias 'heavy' } }
}
function Row-Detail($row) {
    if ($row.PSObject.Properties['detail']) { return $row.detail }
    $a = LL-Alias $row.slot
    if ($row.PSObject.Properties['note'] -and $row.note) { "$a $($row.note)" } else { $a }
}
function Resolve-LocalRow([string]$which, [string]$key) {
    foreach ($c in $LM.launchers.crush.$which.categories) {
        foreach ($r in $c.rows) { if ($r.key -eq $key) { return $r } }
    }
    return $null
}
function Render-Local([string]$which) {
    Show-Line ""
    $first = $true
    foreach ($c in $LM.launchers.crush.$which.categories) {
        if (-not $first) { Show-Line ""; Show-Line "" }
        $first = $false
        Show-Line "     $($c.heading)"
        if ($c.PSObject.Properties['subtitle'] -and $c.subtitle) { Show-Line "         $($c.subtitle)"; $ul = $c.subtitle.Length + 4 } else { $ul = $c.heading.Length }
        Show-Line ("     " + ("-" * $ul)); Show-Line ""
        foreach ($r in $c.rows) { Show-Row $r.key $r.label (Row-Detail $r) }
    }
    Show-Line ""; Show-Line ""; Show-Line ""
    Show-Row "B" "Back to environments" ""; Show-Row "Q" "Quit" ""; Show-Line ""
}
$script:SM = $null
function Get-ServerRoster {
    if ($script:SM) { return $script:SM }
    try { $script:SM = Invoke-RestMethod -Uri "http://__SQUIRE_SERVER_IP__:4090/models" -TimeoutSec 2 -ErrorAction Stop } catch { $script:SM = $null }
    if (-not $script:SM) {
        $fb = Join-Path $ConfigDir "server-models.json"
        if (Test-Path $fb) { try { $script:SM = Get-Content $fb -Raw | ConvertFrom-Json } catch { $script:SM = $null } }
    }
    return $script:SM
}

$SelectedModel = $null
$OffloadMode = $false
$Provider = "ollama"
$SwitchMode = $null
$ServerMcp = $null
$SrvCtx = 0
$SrvMax = 0
$SelLabel = ""

function Write-CrushConfig {
    param(
        [hashtable]$McpOverrides,
        [string]$SystemPromptPrefix,
        [string]$Model,
        [string]$Provider = "ollama",
        [string]$ActiveLabel,
        [int]$ServerCtx = 0,
        [int]$ServerMax = 0
    )
    $config = @{ mcp = $McpOverrides }
    # Output cap + context window. For the server provider these come from the advertised roster
    # (passed as -ServerCtx / -ServerMax); local Ollama runs roomy windows so a fixed cap is cheap.
    $maxTok = 16384; $ctxWin = 65536
    if ($Provider -eq "server") {
        $ctxWin = if ($ServerCtx) { $ServerCtx } else { 32768 }
        $maxTok = if ($ServerMax) { $ServerMax } else { 8192 }
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
            "large" = @{ "model" = $Model; "provider" = $Provider; "max_tokens" = $maxTok }
            "small" = @{ "model" = $Model; "provider" = $Provider; "max_tokens" = $maxTok }
        }
    }
    $json = $config | ConvertTo-Json -Depth 5
    Set-Content -Path ".crush.json" -Value $json -Encoding UTF8
}

# If no task specified, show the data-driven picker.
if (-not $Task) {
    $hasLocal  = Test-LlProvider 'local'
    $hasServer = Test-LlProvider 'server'
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
                switch ($sel.ToUpper()) {
                    "1" { $page = "local" }
                    "2" { $page = "exp" }
                    "3" { if ($hasServer) { $page = "server" } else { $menuErr = "Invalid selection, try again." } }
                    "Q" { Clear-Host; exit }
                    default { $menuErr = "Invalid selection, try again." }
                }
            }
            { $_ -eq "local" -or $_ -eq "exp" } {
                $which = if ($page -eq "local") { "production" } else { "experimental" }
                Show-Top; Show-Center "Crush"; Show-Line ""
                if ($page -eq "local") { Show-Center "local : production models" } else { Show-Center "local : models under evaluation ($($LM.tier) tier)" }
                Show-Mid
                Render-Local $which
                Show-Bot; Write-Host ""
                if ($menuErr) { Write-Host "   $menuErr"; $menuErr = "" }
                $sel = Read-Host "   Your choice [1]"; if (-not $sel) { $sel = "1" }
                if ($sel.ToUpper() -eq "Q") { Clear-Host; exit }
                if ($sel.ToUpper() -eq "B") { $page = "env"; continue picker }
                $r = Resolve-LocalRow $which $sel
                if ($r) {
                    $Task = $r.profile
                    $SelectedModel = LL-Alias $r.slot
                    $SelLabel = LL-Label $SelectedModel
                    $OffloadMode = [bool]($r.PSObject.Properties['offload'] -and $r.offload)
                    break picker
                }
                $menuErr = "Invalid selection, try again."
            }
            "server" {
                $sm = Get-ServerRoster
                if (-not $sm) { Clear-Host; Write-Host "  ERROR: could not reach the server model list at :4090/models and no fallback file found."; exit 1 }
                Show-Top; Show-Center "Crush"; Show-Line ""; Show-Center "squire-server : remote models"; Show-Mid
                Show-Line ""
                $sub = "(server - switches the standing model on pick)"
                Show-Line "     Remote"; Show-Line "         $sub"; Show-Line ("     " + ("-" * ($sub.Length + 4))); Show-Line ""
                foreach ($m in $sm.modes) { Show-Row $m.key $m.label $m.task }
                Show-Line ""; Show-Line ""; Show-Line ""
                if ($hasLocal) { Show-Row "B" "Back to environments" "" }
                Show-Row "Q" "Quit" ""; Show-Line ""
                Show-Bot; Write-Host ""
                if ($menuErr) { Write-Host "   $menuErr"; $menuErr = "" }
                $sel = Read-Host "   Your choice [1]"; if (-not $sel) { $sel = "1" }
                if ($sel.ToUpper() -eq "Q") { Clear-Host; exit }
                if ($sel.ToUpper() -eq "B" -and $hasLocal) { $page = "env"; continue picker }
                $m = $sm.modes | Where-Object { $_.key -eq $sel } | Select-Object -First 1
                if ($m) {
                    $Provider = "server"; $SwitchMode = $m.mode; $SelectedModel = $m.model_id; $SelLabel = $m.label
                    $ServerMcp = @{ "imagegen-mcp" = @{ disabled = [bool]$m.imagegen_disabled } }
                    $SrvCtx = [int]$m.ctx; $SrvMax = [int]$m.max_output
                    break picker
                }
                $menuErr = "Invalid selection, try again."
            }
        }
    }
}

# Resolve the model: explicit -Model wins, then picker selection, then per-task default.
if (-not $SelectedModel) {
    $SelectedModel = if ($Model) { $Model } else { Model-ForTask $Task }
}
$DefaultModel = $SelectedModel
$ReviewModel  = $SelectedModel

$ModelFriendly = if ($SelLabel) { $SelLabel } else { LL-Label $DefaultModel }
Write-Host ""
Write-Host "  ▶ $ModelFriendly  ·  alias=$DefaultModel" -ForegroundColor Cyan

if ($Provider -eq "server") {
    if ($SwitchMode) { Invoke-SquireSwitch $SwitchMode }
    Write-CrushConfig -McpOverrides $ServerMcp -Model "active-model" -Provider "server" -ActiveLabel $SelectedModel -ServerCtx $SrvCtx -ServerMax $SrvMax
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
        # runs it via 'uv run --with ...', no document MCP servers, near-zero context cost.
        Write-CrushConfig -McpOverrides @{
            "imagegen-mcp" = @{ disabled = $true }
        } -Model $DefaultModel
        Write-Host "  Profile: Documents / office authoring ($DefaultModel + office skill: docx/pptx/xlsx via Python)"
    }
    "image" {
        Write-CrushConfig -McpOverrides @{
            "imagegen-mcp" = @{ disabled = $false }
        } -Model $SelectedModel
        Write-Host "  Profile: Image generation (HiDream) using $SelectedModel for VRAM headroom"
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
