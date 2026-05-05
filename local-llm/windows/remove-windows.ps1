#Requires -Version 5.1
<#
.SYNOPSIS
    Removes the self-hosted AI coding assistant stack from Windows.

.DESCRIPTION
    Cleanly removes components installed by install-windows.ps1.

    Full mode removes the complete stack:
      Layer 1 (System):     Ollama uninstall + model storage
      Layer 2 (User-local): Crush and uv uninstall (winget portable packages)
      Layer 3 (Isolated):   MCP server venvs, uv-managed Python
      Layer 4 (Config):     .ollama, .crush configuration

    Client mode removes only the client-side tooling:
      Crush, uv, MCP server venvs, and related user-local data.
      Ollama service, model storage, and Ollama-specific environment settings
      are preserved.

    Follows the Installation Containment Strategy — every layer is
    independently removable.

.PARAMETER Mode
    Removal mode. Full (default) removes the entire stack. Client removes only
    Crush + uv + MCP venvs + uv data and skips all Ollama-related cleanup.

.PARAMETER KeepModels
    Keep downloaded Ollama models (~38+ GB in %USERPROFILE%\.ollama\models).
    Useful if you plan to reinstall. Ollama configuration is also preserved.
    This parameter is irrelevant in Client mode.

.PARAMETER KeepConfig
    Keep Crush configuration files (~/.crush). Preserves your model aliases,
    MCP server definitions, and provider settings.

.PARAMETER Force
    Skip all confirmation prompts.

.EXAMPLE
    .\remove-windows.ps1
    Interactive full removal with confirmations.

.EXAMPLE
    .\remove-windows.ps1 -Mode Client
    Remove only client-side tooling and keep Ollama installed.

.EXAMPLE
    .\remove-windows.ps1 -KeepModels
    Remove everything except downloaded models and Ollama config.

.EXAMPLE
    .\remove-windows.ps1 -Force
    Non-interactive full removal.
#>

[CmdletBinding()]
param(
    [ValidateSet("Full", "Client")]
    [string]$Mode = "Full",
    [switch]$KeepModels,
    [switch]$KeepConfig,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Constants ────────────────────────────────────────────────────────────────

$LocalAppData   = $env:LOCALAPPDATA
$UserProfile    = $env:USERPROFILE
$AiToolsDir     = Join-Path $LocalAppData "ai-tools"
$UvDir          = Join-Path $LocalAppData "uv"
$OllamaDir      = Join-Path $UserProfile ".ollama"
$CrushDir       = Join-Path $UserProfile ".crush"
$IsFullMode     = $Mode -eq "Full"
$RemovalLabel   = if ($IsFullMode) { "full removal" } else { "client removal" }

# ── Helpers ──────────────────────────────────────────────────────────────────

$script:StepNumber = 0

function Write-Step {
    param([string]$Message)
    $script:StepNumber++
    Write-Host ""
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "  Step $($script:StepNumber): $Message" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
}

function Write-Info {
    param([string]$Message)
    Write-Host "  ℹ  $Message" -ForegroundColor DarkGray
}

function Write-Success {
    param([string]$Message)
    Write-Host "  ✓  $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  ⚠  $Message" -ForegroundColor Yellow
}

function Remove-SafeItem {
    param(
        [string]$Path,
        [string]$Description
    )

    if (-not (Test-Path $Path)) {
        Write-Info "$Description not found at $Path — skipping."
        return
    }

    $isDir = (Get-Item $Path).PSIsContainer
    $sizeInfo = ""
    if ($isDir) {
        try {
            $size = (Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue |
                     Measure-Object -Property Length -Sum).Sum
            $sizeGB = [math]::Round($size / 1GB, 2)
            $sizeMB = [math]::Round($size / 1MB, 0)
            $sizeInfo = if ($sizeGB -ge 1) { " ($sizeGB GB)" } else { " ($sizeMB MB)" }
        } catch {
            $sizeInfo = ""
        }
    }

    if ($PSCmdlet.ShouldProcess("$Path$sizeInfo", "Remove $Description")) {
        try {
            Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
            Write-Success "Removed $Description$sizeInfo"
        } catch {
            Write-Warn "Could not remove $Path — $($_.Exception.Message)"
            Write-Warn "Try closing applications that may be using it, then remove manually."
        }
    }
}

function Confirm-Action {
    param([string]$Message)

    if ($Force) { return $true }

    $response = Read-Host "  $Message (y/N)"
    return ($response -eq "y" -or $response -eq "Y")
}

# ── Pre-flight ───────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Red
Write-Host "║   Self-Hosted AI Coding Assistant — Windows Removal         ║" -ForegroundColor Red
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Red
Write-Host ""

# Show what will be removed
Write-Host "  Mode: $Mode" -ForegroundColor White
Write-Host "  This script will remove:" -ForegroundColor White
if ($IsFullMode) {
    Write-Host "    • Ollama (system service + winget uninstall)" -ForegroundColor Gray
    if (-not $KeepModels) {
        Write-Host "    • Ollama models + config in $OllamaDir" -ForegroundColor Gray
    }
}
Write-Host "    • Crush CLI agent (winget uninstall)" -ForegroundColor Gray
if (-not $KeepConfig) {
    Write-Host "    • Crush configuration in $CrushDir" -ForegroundColor Gray
}
Write-Host "    • MCP server venvs in $AiToolsDir" -ForegroundColor Gray
Write-Host "    • uv + uv-managed Python (winget uninstall + data)" -ForegroundColor Gray
if ($IsFullMode) {
    Write-Host "    • Ollama environment variables (OLLAMA_HOST, OLLAMA_KEEP_ALIVE, OLLAMA_MODELS)" -ForegroundColor Gray
    Write-Host "    • Ollama backup registry entry cleanup" -ForegroundColor Gray
}
Write-Host ""

if ($KeepModels) {
    if ($IsFullMode) {
        Write-Warn "Models will be KEPT (use without -KeepModels to remove them)."
    } else {
        Write-Warn "KeepModels is irrelevant in Client mode — Ollama models are not removed."
    }
}
if ($KeepConfig) {
    Write-Warn "Configuration will be KEPT (use without -KeepConfig to remove it)."
}

if (-not (Confirm-Action "Proceed with $RemovalLabel?")) {
    Write-Host "  Cancelled." -ForegroundColor Yellow
    exit 0
}

# ── Step 1: Ollama cleanup ───────────────────────────────────────────────────

if ($IsFullMode) {
    Write-Step "Stop Ollama service"

    $ollamaProcess = Get-Process -Name "ollama*" -ErrorAction SilentlyContinue
    if ($ollamaProcess) {
        Write-Info "Stopping Ollama processes..."
        foreach ($proc in $ollamaProcess) {
            try {
                Stop-Process -Id $proc.Id -Force -ErrorAction Stop
                Write-Success "Stopped process $($proc.ProcessName) (PID $($proc.Id))"
            } catch {
                Write-Warn "Could not stop $($proc.ProcessName) (PID $($proc.Id)): $($_.Exception.Message)"
            }
        }
        Start-Sleep -Seconds 2
    } else {
        Write-Info "No Ollama processes running."
    }

    # ── Step 2: Uninstall Ollama via winget ──────────────────────────────────

    Write-Step "Uninstall Ollama (system package)"

    $ollamaInstalled = winget list --exact --id Ollama.Ollama 2>&1 | Select-String "Ollama.Ollama"
    if ($ollamaInstalled) {
        Write-Host "  Uninstalling Ollama..." -ForegroundColor White
        winget uninstall --exact --id Ollama.Ollama --silent
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Ollama uninstalled."
        } else {
            Write-Warn "winget uninstall returned exit code $LASTEXITCODE."
            Write-Warn "Try manually: winget uninstall --exact --id Ollama.Ollama"
        }
    } else {
        Write-Info "Ollama is not installed via winget."
    }

    # ── Step 3: Remove Ollama data ───────────────────────────────────────────

    Write-Step "Remove Ollama data and models"

    if ($KeepModels) {
        Write-Info "Keeping models in $OllamaDir as requested."
    } else {
        Remove-SafeItem -Path $OllamaDir -Description "Ollama data directory (models + config)"
    }
} else {
    Write-Step "Skip Ollama cleanup"
    Write-Info "Client mode selected — skipping Ollama uninstall, model removal, and Ollama settings cleanup."
}

# ── Step 4: Remove Crush ────────────────────────────────────────────────────

Write-Step "Remove Crush CLI agent"

$crushInstalled = winget list --exact --id charmbracelet.crush 2>&1 | Select-String "charmbracelet.crush"
if ($crushInstalled) {
    Write-Host "  Uninstalling Crush via winget..." -ForegroundColor White
    winget uninstall --exact --id charmbracelet.crush --silent
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Crush uninstalled."
    } else {
        Write-Warn "winget uninstall returned exit code $LASTEXITCODE."
        Write-Warn "Try manually: winget uninstall --exact --id charmbracelet.crush"
    }
} else {
    Write-Info "Crush is not installed via winget."
}

if (-not $KeepConfig) {
    Remove-SafeItem -Path $CrushDir -Description "Crush configuration"
}

# ── Step 5: Remove MCP server venvs ─────────────────────────────────────────

Write-Step "Remove MCP server environments"

Remove-SafeItem -Path $AiToolsDir -Description "MCP server venvs"

# ── Step 6: Remove uv and uv-managed Python ─────────────────────────────────

Write-Step "Remove uv and uv-managed Python"

# Uninstall uv via winget (this is the primary install method)
$uvInstalled = winget list --exact --id astral-sh.uv 2>&1 | Select-String "astral-sh.uv"
if ($uvInstalled) {
    Write-Host "  Uninstalling uv via winget..." -ForegroundColor White
    winget uninstall --exact --id astral-sh.uv --silent
    if ($LASTEXITCODE -eq 0) {
        Write-Success "uv uninstalled from winget."
    } else {
        Write-Warn "winget uninstall of uv returned exit code $LASTEXITCODE."
    }
}

# Remove uv data directory (managed Python installs + cache)
Remove-SafeItem -Path $UvDir -Description "uv data directory (managed Python installs + cache)"

# ── Step 7: Clean user PATH ─────────────────────────────────────────────────

Write-Step "Clean up (no user PATH changes needed)"
Write-Info "Crush and uv are winget portable packages — winget manages their PATH entries."
Write-Info "No manual PATH cleanup required."

# ── Step 8: Remove Ollama environment variables ─────────────────────────────

if ($IsFullMode) {
    Write-Step "Remove Ollama environment variables"

    $envVarsToRemove = @("OLLAMA_HOST", "OLLAMA_KEEP_ALIVE", "OLLAMA_MODELS")
    foreach ($varName in $envVarsToRemove) {
        $current = [Environment]::GetEnvironmentVariable($varName, "User")
        if ($null -ne $current) {
            [Environment]::SetEnvironmentVariable($varName, $null, "User")
            Write-Success "Removed $varName from user environment."
        } else {
            Write-Info "$varName was not set."
        }
    }

    # ── Step 9: Clean backup registry entry ──────────────────────────────────

    Write-Step "Clean Ollama backup registry entry"

    $backupRegistryPath = "HKLM:\SYSTEM\CurrentControlSet\Control\BackupRestore\FilesNotToSnapshotMacriumImage"
    $backupRegistryValueName = "OllamaModels"
    try {
        if (Test-Path $backupRegistryPath) {
            $backupRegistryValue = Get-ItemProperty -Path $backupRegistryPath -Name $backupRegistryValueName -ErrorAction SilentlyContinue
            if ($null -ne $backupRegistryValue) {
                Remove-ItemProperty -Path $backupRegistryPath -Name $backupRegistryValueName -ErrorAction Stop
                Write-Success "Removed $backupRegistryValueName from backup registry exclusions."

                $remainingProperties = (Get-ItemProperty -Path $backupRegistryPath -ErrorAction Stop).PSObject.Properties |
                    Where-Object { $_.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$' }
                if (-not $remainingProperties) {
                    Remove-Item -Path $backupRegistryPath -Force -ErrorAction Stop
                    Write-Success "Removed empty backup registry key."
                }
            } else {
                Write-Info "$backupRegistryValueName was not present in backup registry exclusions."
            }
        } else {
            Write-Info "Backup registry exclusions key not found."
        }
    } catch {
        Write-Warn "Could not clean backup registry exclusions — $($_.Exception.Message)"
        Write-Warn "This usually requires running the script in an elevated PowerShell session."
    }
} else {
    Write-Step "Skip Ollama environment cleanup"
    Write-Info "Client mode selected — no Ollama environment variables or backup registry entries were removed."
}

# ── Step 10: Credential cleanup ─────────────────────────────────────────────

Write-Step "Credential cleanup"
Write-Host ""
Write-Info "If you stored API keys in Windows Credential Manager (e.g., for OpenRouter),"
Write-Info "remove them manually:"
Write-Host ""
Write-Host "    1. Open: Control Panel → Credential Manager → Windows Credentials" -ForegroundColor Yellow
if ($IsFullMode) {
    Write-Host "    2. Look for entries related to: openrouter, ollama, crush, ai-assistant" -ForegroundColor Yellow
} else {
    Write-Host "    2. Look for entries related to: openrouter, crush, ai-assistant" -ForegroundColor Yellow
}
Write-Host "    3. Remove any that are no longer needed" -ForegroundColor Yellow
Write-Host ""

# ── Summary ──────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║   Removal Complete                                          ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  Mode: $Mode" -ForegroundColor White
Write-Host "  Removed:" -ForegroundColor White
if ($IsFullMode) {
    Write-Host "    • Ollama (service + winget package)" -ForegroundColor Gray
    if (-not $KeepModels) {
        Write-Host "    • Ollama models, config, and data" -ForegroundColor Gray
    }
}
Write-Host "    • Crush (winget package)" -ForegroundColor Gray
if (-not $KeepConfig) {
    Write-Host "    • Crush configuration" -ForegroundColor Gray
}
Write-Host "    • MCP server venvs" -ForegroundColor Gray
Write-Host "    • uv + managed Python (winget package + data)" -ForegroundColor Gray
if ($IsFullMode) {
    Write-Host "    • Ollama environment variables" -ForegroundColor Gray
    Write-Host "    • Ollama backup registry exclusions entry" -ForegroundColor Gray
}
Write-Host ""

if ($IsFullMode -and $KeepModels) {
    Write-Warn "Models were kept in $OllamaDir"
    Write-Warn "To remove: Remove-Item -Recurse `"$OllamaDir`""
}
if ($KeepConfig) {
    Write-Warn "Configuration was kept in $CrushDir"
    Write-Warn "To remove: Remove-Item -Recurse `"$CrushDir`""
}

Write-Host "  Restart your terminal for PATH changes to take effect." -ForegroundColor Yellow
Write-Host ""
