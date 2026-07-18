<#
.SYNOPSIS
    Launch GitHub Copilot CLI against local Ollama models or the squire-server,
    via a two-level environment picker (Local / Local-Experimental / Squire-Server).

.DESCRIPTION
    Ported from copilot-local.cmd to PowerShell so the double-line box-drawing UI and
    ANSI colour render reliably in any console (cmd.exe cannot parse a UTF-8 batch file
    with box glyphs because CALL/GOTO seeks desync on the multi-byte characters).
    A thin copilot-local.cmd shim invokes this script so `copilot-local` still works on PATH.
#>
param([string]$Model)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# ── Provider wiring (baked in by the installer; fallback to both) ─────────────
$LlProviders = "__LL_PROVIDERS__"
if ($LlProviders -like "*__*" -or [string]::IsNullOrWhiteSpace($LlProviders)) { $LlProviders = "local,server" }
function Test-LlProvider { param([string]$Name) return ((",$LlProviders,") -like "*,$Name,*") }
$SquireIp = "__SQUIRE_SERVER_IP__"

# ── Global token caps (per-mode server caps override below) ───────────────────
$env:COPILOT_PROVIDER_MAX_PROMPT_TOKENS = "51200"
$env:COPILOT_PROVIDER_MAX_OUTPUT_TOKENS = "16384"

# ── Switch the squire-server's active model via the accountless :4090 endpoint ──
function Invoke-SquireSwitch {
    param([string]$Mode)
    $port = "4090"
    try {
        Invoke-RestMethod -Uri "http://${SquireIp}:${port}/switch" -Method Post -ContentType 'application/json' `
            -Body "{`"mode`":`"$Mode`"}" -TimeoutSec 10 -ErrorAction Stop | Out-Null
    } catch {
        Write-Host "  WARN: could not reach the model-switch service at http://${SquireIp}:${port}/ - is the server up?"
        return
    }
    Write-Host -NoNewline "  ... switching server to $Mode"
    for ($i = 0; $i -lt 30; $i++) {
        try {
            $st = Invoke-RestMethod -Uri "http://${SquireIp}:${port}/status" -TimeoutSec 5 -ErrorAction Stop
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
$W = 110
$Bar = ([string][char]0x2550) * $W
function Show-Top { Write-Host ("  $Frame" + [char]0x2554 + $Bar + [char]0x2557 + $Rst) }
function Show-Mid { Write-Host ("  $Frame" + [char]0x2560 + $Bar + [char]0x2563 + $Rst) }
function Show-Bot { Write-Host ("  $Frame" + [char]0x255A + $Bar + [char]0x255D + $Rst) }
function Show-Line { param([string]$s)
    if ($s.Length -gt $W) { $s = $s.Substring(0, $W) }
    Write-Host ("  $Frame" + [char]0x2551 + $Text + $s.PadRight($W) + $Frame + [char]0x2551 + $Rst)
}
function Show-Center { param([string]$s)
    $p = [math]::Max(0, [math]::Floor(($W - $s.Length) / 2)); Show-Line ((" " * $p) + $s)
}
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
function Row-Detail($row) {
    if ($row.PSObject.Properties['detail']) { return $row.detail }
    $a = LL-Alias $row.slot
    if ($row.PSObject.Properties['note'] -and $row.note) { "$a $($row.note)" } else { $a }
}
function Resolve-LocalRow([string]$which, [string]$key) {
    foreach ($c in $LM.launchers.copilot.$which.categories) {
        foreach ($r in $c.rows) { if ($r.key -eq $key) { return $r } }
    }
    return $null
}
function Render-Local([string]$which) {
    Show-Line ""
    $first = $true
    foreach ($c in $LM.launchers.copilot.$which.categories) {
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
    try { $script:SM = Invoke-RestMethod -Uri "http://${SquireIp}:4090/models" -TimeoutSec 2 -ErrorAction Stop } catch { $script:SM = $null }
    if (-not $script:SM) {
        $fb = Join-Path $ConfigDir "server-models.json"
        if (Test-Path $fb) { try { $script:SM = Get-Content $fb -Raw | ConvertFrom-Json } catch { $script:SM = $null } }
    }
    return $script:SM
}

# ── Resolve the selection: explicit model arg wins; otherwise the picker ──────
$selLabel = ""; $selTag = ""; $mcpKeep = $false; $officeSkill = $false; $selRemote = $false
$env:COPILOT_PROVIDER_BASE_URL = $null
if ($Model -and $Model -match ':') {
    # Direct model alias/tag (e.g. copilot-local qwen3:8b) — skip the picker.
    $env:COPILOT_MODEL = $Model
} else {
    $hasLocal = Test-LlProvider 'local'
    $hasServer = Test-LlProvider 'server'
    $menuErr = ""
    $page = if ($hasLocal) { "env" } else { "server" }
    :picker while ($true) {
        Clear-Host
        Write-Host ""
        switch ($page) {
            "env" {
                Show-Top; Show-Center "Copilot Local"; Show-Line ""; Show-Center "pick an environment"; Show-Mid
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
                Show-Top; Show-Center "Copilot Local"; Show-Line ""
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
                    $env:COPILOT_MODEL = LL-Alias $r.slot
                    $selLabel = LL-Label $env:COPILOT_MODEL
                    $mcpKeep = [bool]($r.PSObject.Properties['imagegen'] -and $r.imagegen)
                    $officeSkill = [bool]($r.PSObject.Properties['office'] -and $r.office)
                    $selTag = if ($which -eq "experimental") { "[$sel] experimental" } else { "[$sel] task profile" }
                    break picker
                }
                $menuErr = "Invalid selection, try again."
            }
            "server" {
                $sm = Get-ServerRoster
                if (-not $sm) { Clear-Host; Write-Host "  ERROR: could not reach the server model list at :4090/models and no fallback file found."; exit 1 }
                $sMenu = if ($sm.PSObject.Properties['menu'] -and $sm.menu) { $sm.menu.categories } else { $null }
                Show-Top; Show-Center "Copilot Local"; Show-Line ""; Show-Center "squire-server : pick a task"; Show-Mid
                Show-Line ""
                Show-Center "(picking a task switches the served model)"
                Show-Line ""
                if ($sMenu) {
                    $first = $true
                    foreach ($c in $sMenu) {
                        if (-not $first) { Show-Line ""; Show-Line "" }
                        $first = $false
                        Show-Line "     $($c.heading)"; Show-Line ("     " + ("-" * $c.heading.Length)); Show-Line ""
                        foreach ($r in $c.rows) { Show-Row $r.key $r.label "" }
                    }
                } else {
                    foreach ($m in $sm.modes) { Show-Row $m.key $m.label $m.task }
                }
                Show-Line ""; Show-Line ""; Show-Line ""
                if ($hasLocal) { Show-Row "B" "Back to environments" "" }
                Show-Row "Q" "Quit" ""; Show-Line ""
                Show-Bot; Write-Host ""
                if ($menuErr) { Write-Host "   $menuErr"; $menuErr = "" }
                $sel = Read-Host "   Your choice [1]"; if (-not $sel) { $sel = "1" }
                if ($sel.ToUpper() -eq "Q") { Clear-Host; exit }
                if ($sel.ToUpper() -eq "B" -and $hasLocal) { $page = "env"; continue picker }
                # Resolve the selection to a vLLM mode: via the task menu when present, else a flat mode key.
                $m = $null
                if ($sMenu) {
                    $row = $sMenu.rows | Where-Object { $_.key -eq $sel } | Select-Object -First 1
                    if ($row) { $m = $sm.modes | Where-Object { $_.mode -eq $row.mode } | Select-Object -First 1 }
                } else {
                    $m = $sm.modes | Where-Object { $_.key -eq $sel } | Select-Object -First 1
                }
                if ($m) {
                    Invoke-SquireSwitch $m.mode
                    $env:COPILOT_MODEL = $m.model_id
                    $env:COPILOT_PROVIDER_BASE_URL = "http://${SquireIp}:8000/v1"
                    $env:COPILOT_PROVIDER_MAX_PROMPT_TOKENS = "$($m.max_prompt)"
                    $env:COPILOT_PROVIDER_MAX_OUTPUT_TOKENS = "$($m.max_output)"
                    $selLabel = $m.label; $selTag = "[$sel] squire-server"
                    $mcpKeep = (-not $m.imagegen_disabled)
                    $selRemote = $true
                    break picker
                }
                $menuErr = "Invalid selection, try again."
            }
        }
    }
}

if (-not $env:COPILOT_MODEL) { Write-Host "  Invalid selection."; $env:COPILOT_MODEL = (LL-Alias 'heavy') }

# ── Flags: MCP (imagegen only on image profiles), git-safety, office skill ────
$mcpFlags = if ($mcpKeep) { @() } else { @('--disable-mcp-server', 'imagegen-mcp') }
# Point the imagegen MCP tool at the selected environment's image server (the mcp-config expands
# ${COPILOT_MCP_IMAGEGEN_HOST}): local -> localhost, server -> the squire-server.
$env:COPILOT_MCP_IMAGEGEN_HOST = if ($selRemote) { $SquireIp } else { "127.0.0.1" }
$gitSafety = @(
    '--deny-tool=shell(git add)', '--deny-tool=shell(git commit)', '--deny-tool=shell(git push)',
    '--deny-tool=shell(git merge)', '--deny-tool=shell(git rebase)', '--deny-tool=shell(git reset)',
    '--deny-tool=shell(git stash)', '--deny-tool=shell(git cherry-pick)', '--deny-tool=shell(git revert)',
    '--deny-tool=shell(git tag)'
)
$extraFlags = @()
# Office authoring: the 'office' skill is deployed to ~/.copilot/skills/office and discovered natively by
# Copilot (see `copilot skill list`), so it's available in every session regardless of model/provider. No
# launcher injection needed (Copilot's COPILOT_CUSTOM_INSTRUCTIONS_DIRS ignores SKILL.md anyway).

# ── Launch banner ────────────────────────────────────────────────────────────
$modelLabel = if ($selLabel) { $selLabel } else { LL-Label $env:COPILOT_MODEL }
Write-Host "  Launching $modelLabel  [alias $($env:COPILOT_MODEL)]  $selTag"

# ── Launch Copilot ───────────────────────────────────────────────────────────
# Local Ollama is reached through the compat proxy (:11435), which coerces content:null -> ""
# so reasoning-model turns can't poison a session with Ollama's "invalid message content type: <nil>"
# 400. Start it on demand if it isn't already up (it's the only thing on :11435, so no port race).
function Ensure-OllamaProxy {
    if ($env:LL_TEST) { return }   # test harness / CI: never probe or start the proxy
    if (Get-NetTCPConnection -LocalPort 11435 -State Listen -ErrorAction SilentlyContinue) { return }
    $proxy = Join-Path $PSScriptRoot "ollama-compat-proxy.py"
    if (-not (Test-Path $proxy)) { Write-Host "  WARN: ollama-compat-proxy.py not found; using Ollama directly (content:null 400s possible)."; return }
    Start-Process -WindowStyle Hidden -FilePath 'python' -ArgumentList "`"$proxy`"" | Out-Null
    for ($i = 0; $i -lt 12; $i++) { Start-Sleep -Milliseconds 300; if (Get-NetTCPConnection -LocalPort 11435 -State Listen -ErrorAction SilentlyContinue) { return } }
}
$copilotArgs = @('--model', $env:COPILOT_MODEL) + $mcpFlags + $gitSafety + $extraFlags + $args
if ($env:COPILOT_PROVIDER_BASE_URL) {
    Write-Host "  Remote: $($env:COPILOT_PROVIDER_BASE_URL)"; Write-Host ""
    & copilot @copilotArgs
} else {
    Write-Host ""
    Ensure-OllamaProxy
    $env:COPILOT_PROVIDER_BASE_URL = "http://localhost:11435/v1"
    & copilot @copilotArgs
}
