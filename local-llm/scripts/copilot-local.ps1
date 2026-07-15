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

# ── Resolve the selection: explicit model arg wins; otherwise the picker ──────
$choice = ""
if ($Model -and $Model -match ':') {
    # Direct model alias/tag (e.g. copilot-local qwen3:8b) — skip the picker.
    $env:COPILOT_MODEL = $Model
    $choice = "-"
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
                switch ($sel) {
                    "1" { $page = "local" }
                    "2" { $page = "exp" }
                    "3" { if ($hasServer) { $page = "server" } else { $menuErr = "Invalid selection, try again." } }
                    "Q" { Clear-Host; exit }
                    default { $menuErr = "Invalid selection, try again." }
                }
            }
            "local" {
                Show-Top; Show-Center "Copilot Local"; Show-Line ""; Show-Center "local : production models"; Show-Mid
                Show-Line ""
                Show-Line "     Coding"
                Show-Line "     ------"
                Show-Line ""
                Show-Row "1" "Heavy coding" "qwen36-27b-212k"
                Show-Row "2" "Light coding" "qwen3coder-144k"
                Show-Row "3" "Code review" "qwen3coder-144k"
                Show-Line ""
                Show-Line ""
                Show-Line "     Writing & Documents"
                Show-Line "     -------------------"
                Show-Line ""
                Show-Row "4" "Technical docs" "qwen36-27b-212k"
                Show-Row "5" "Creative writing" "qwen36-27b-212k"
                Show-Row "6" "Office documents" "glm47-flash-198k"
                Show-Line ""
                Show-Line ""
                Show-Line "     Visual"
                Show-Line "     ------"
                Show-Line ""
                Show-Row "7" "Image generation" "qwen3:8b + HiDream (MCP)"
                Show-Line ""; Show-Line ""; Show-Line ""; Show-Row "B" "Back to environments" ""; Show-Row "Q" "Quit" ""; Show-Line ""
                Show-Bot; Write-Host ""
                if ($menuErr) { Write-Host "   $menuErr"; $menuErr = "" }
                $sel = Read-Host "   Your choice [1]"; if (-not $sel) { $sel = "1" }
                if ($sel.ToUpper() -eq "Q") { Clear-Host; exit }
                if ($sel.ToUpper() -eq "B") { $page = "env"; continue picker }
                if ($sel -match '^[1-7]$') { $choice = $sel; break picker }
                $menuErr = "Invalid selection, try again."
            }
            "exp" {
                Show-Top; Show-Center "Copilot Local"; Show-Line ""; Show-Center "local : models under evaluation"; Show-Mid
                Show-Line ""
                Show-Line "     Heavy-coding bench"
                Show-Line "         (VRAM-resident; swap model, MCP off)"
                Show-Line ("     " + ("-" * 40))
                Show-Line ""
                Show-Row "1" "Qwen3.6 27B+MTP" "qwen36-27b-212k"
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
                Show-Top; Show-Center "Copilot Local"; Show-Line ""; Show-Center "squire-server : remote models"; Show-Mid
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
}

# ── Dispatch: resolve model, provider base URL, per-mode caps, MCP flags ──────
$env:COPILOT_PROVIDER_BASE_URL = $null
$offload = $false
$mcpKeep = $false   # keep imagegen-mcp enabled (image profiles only)
$officeSkill = $false

switch -Regex ($choice) {
    '^1$' { $env:COPILOT_MODEL = "qwen36-27b-212k" }
    '^2$' { $env:COPILOT_MODEL = "qwen3coder-144k" }
    '^3$' { $env:COPILOT_MODEL = "qwen3coder-144k" }
    '^4$' { $env:COPILOT_MODEL = "qwen36-27b-212k" }
    '^5$' { $env:COPILOT_MODEL = "qwen36-27b-212k" }
    '^6$' { $env:COPILOT_MODEL = "glm47-flash-198k"; $officeSkill = $true }
    '^7$' { $env:COPILOT_MODEL = "qwen3:8b"; $mcpKeep = $true }
    '^H1$' { $env:COPILOT_MODEL = "qwen36-27b-212k" }
    '^H2$' { $env:COPILOT_MODEL = "qwen36-35b-256k" }
    '^H3$' { $env:COPILOT_MODEL = "gemma4-31b-128k" }
    '^H4$' { $env:COPILOT_MODEL = "qwen3coder-144k" }
    '^H5$' { $env:COPILOT_MODEL = "glm47-flash-198k" }
    '^H6$' { $env:COPILOT_MODEL = "northmini-code-256k" }
    '^H7$' { $env:COPILOT_MODEL = "nemotron3-nano-256k" }
    '^H8$' { $env:COPILOT_MODEL = "ornith-35b-256k" }
    '^H9$' { $env:COPILOT_MODEL = "devstral2-24b-128k" }
    '^O2$' { $env:COPILOT_MODEL = "qwen3next-80b-offload"; $offload = $true }
    '^S$' { $env:COPILOT_MODEL = "mistral-small"; $env:COPILOT_PROVIDER_BASE_URL = "http://${SquireIp}:8000/v1"; $env:COPILOT_PROVIDER_MAX_PROMPT_TOKENS = "54272"; $env:COPILOT_PROVIDER_MAX_OUTPUT_TOKENS = "8192"; Invoke-SquireSwitch "mistral" }
    '^G$' { $env:COPILOT_MODEL = "glm-4.7-flash"; $env:COPILOT_PROVIDER_BASE_URL = "http://${SquireIp}:8000/v1"; $env:COPILOT_PROVIDER_MAX_PROMPT_TOKENS = "44032"; $env:COPILOT_PROVIDER_MAX_OUTPUT_TOKENS = "8192"; Invoke-SquireSwitch "glm" }
    '^C$' { $env:COPILOT_MODEL = "qwen3-coder"; $env:COPILOT_PROVIDER_BASE_URL = "http://${SquireIp}:8000/v1"; $env:COPILOT_PROVIDER_MAX_PROMPT_TOKENS = "46080"; $env:COPILOT_PROVIDER_MAX_OUTPUT_TOKENS = "8192"; Invoke-SquireSwitch "coder" }
    '^D$' { $env:COPILOT_MODEL = "devstral"; $env:COPILOT_PROVIDER_BASE_URL = "http://${SquireIp}:8000/v1"; $env:COPILOT_PROVIDER_MAX_PROMPT_TOKENS = "46080"; $env:COPILOT_PROVIDER_MAX_OUTPUT_TOKENS = "8192"; Invoke-SquireSwitch "coder-alt" }
    '^I$' { $env:COPILOT_MODEL = "qwen3-4b"; $env:COPILOT_PROVIDER_BASE_URL = "http://${SquireIp}:8000/v1"; $env:COPILOT_PROVIDER_MAX_PROMPT_TOKENS = "28672"; $env:COPILOT_PROVIDER_MAX_OUTPUT_TOKENS = "2048"; $mcpKeep = $true; Invoke-SquireSwitch "image" }
}

if (-not $env:COPILOT_MODEL) { Write-Host "  Invalid selection."; $env:COPILOT_MODEL = "qwen36-27b-212k" }

# ── Flags: MCP (imagegen only on image profiles), git-safety, office skill ────
$mcpFlags = if ($mcpKeep) { @() } else { @('--disable-mcp-server', 'imagegen-mcp') }
$gitSafety = @(
    '--deny-tool=shell(git add)', '--deny-tool=shell(git commit)', '--deny-tool=shell(git push)',
    '--deny-tool=shell(git merge)', '--deny-tool=shell(git rebase)', '--deny-tool=shell(git reset)',
    '--deny-tool=shell(git stash)', '--deny-tool=shell(git cherry-pick)', '--deny-tool=shell(git revert)',
    '--deny-tool=shell(git tag)'
)
$extraFlags = @()
if ($officeSkill) { $extraFlags = @('--custom-instructions', "$env:USERPROFILE\.config\crush\skills\office\SKILL.md") }

# ── Launch banner ────────────────────────────────────────────────────────────
$labels = @{
    "qwen36-27b-212k" = "Qwen3.6 27B (+MTP)"; "qwen36-35b-256k" = "Qwen3.6 35B-A3B MoE"
    "gemma4-31b-128k" = "Gemma 4 31B dense"; "qwen3coder-144k" = "Qwen3-Coder 30B-A3B"
    "glm47-flash-198k" = "GLM-4.7-Flash"; "northmini-code-256k" = "North Mini Code 1.0"
    "nemotron3-nano-256k" = "Nemotron 3 Nano 30B-A3B"; "ornith-35b-256k" = "Ornith-1.0-35B"
    "devstral2-24b-128k" = "Devstral Small 2 (24B)"; "qwen3next-80b-offload" = "Qwen3-Next-80B-A3B (partial offload)"
    "qwen3:8b" = "Qwen3 8B"; "mistral-small" = "Mistral-Small (server)"; "glm-4.7-flash" = "GLM-4.7-Flash (server)"
    "qwen3-coder" = "Qwen3-Coder (server)"; "devstral" = "Devstral-2 24B (server)"; "qwen3-4b" = "Qwen3-4B image companion (server)"
}
$modelLabel = if ($labels.ContainsKey($env:COPILOT_MODEL)) { $labels[$env:COPILOT_MODEL] } else { $env:COPILOT_MODEL }
$slot = switch -Regex ($choice) { '^H' { "[$choice] experimental - heavy bench" } '^O' { "[$choice] experimental - offload bench" } '^[1-9]$' { "[$choice] task profile" } default { "" } }
Write-Host "  Launching $modelLabel  [alias $($env:COPILOT_MODEL)]  $slot"

# ── Launch Copilot ───────────────────────────────────────────────────────────
$copilotArgs = @('--model', $env:COPILOT_MODEL, '--') + $mcpFlags + $gitSafety + $extraFlags + $args
if ($env:COPILOT_PROVIDER_BASE_URL) {
    Write-Host "  Remote: $($env:COPILOT_PROVIDER_BASE_URL)"; Write-Host ""
    & copilot @copilotArgs
} elseif ($offload) {
    Write-Host "  Offload mode: experts -> system RAM (partial; slower than VRAM-resident)"; Write-Host ""
    & powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\offload-serve.ps1" -Action start -NCpuMoe 24
    $env:COPILOT_PROVIDER_BASE_URL = "http://localhost:11434/v1"
    & copilot @copilotArgs
    & powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\offload-serve.ps1" -Action stop
} else {
    Write-Host ""
    $env:COPILOT_PROVIDER_BASE_URL = "http://localhost:11434/v1"
    & copilot @copilotArgs
}
