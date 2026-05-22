#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the self-hosted AI coding assistant stack on Windows.

.DESCRIPTION
    Sets up Ollama (model server), Crush (CLI agent), uv (Python toolchain),
    and supporting infrastructure for local LLM-powered coding assistance.

    Follows the Installation Containment Strategy:
      Layer 1 (System):   Ollama only (GPU access, runs as service)
      Layer 2 (User-local): uv + Crush via winget (portable packages)
      Layer 3 (Isolated):  Python 3.12 via uv, MCP server venvs
      Layer 4 (Config):    %USERPROFILE%\.ollama and %USERPROFILE%\.config\crush

    Full mode installs the complete local stack. Client mode installs only the
    client tooling and points Crush at a remote Ollama endpoint.

.PARAMETER Mode
    Installation mode. Full installs Ollama locally and can pull models. Client
    skips all Ollama installation and model steps, and requires -OllamaHost.

.PARAMETER ModelProfile
    GPU/environment profile that determines which models to pull:
      Desktop — RTX 5090 (32GB). Pulls gemma4:26b, qwen3:14b, qwen3:4b, qwen3-coder:30b (~40 GB).
      Server  — RTX 4090 (24GB dedicated). Pulls gemma4:26b, qwen3:14b, qwen3:4b, qwen3-coder:30b (~40 GB).
    Ignored in Client mode.

.PARAMETER OllamaHost
    Remote Ollama endpoint for Client mode (for example:
    http://192.168.1.100:11434). Required when -Mode Client is used.

.PARAMETER ModelPath
    Custom model storage directory for Full mode. Sets OLLAMA_MODELS to this
    path and creates the directory if needed.

.PARAMETER SkipModels
    Skip pulling Ollama models. Useful for fast install; pull models later
    with: ollama pull <model>. Only applies in Full mode.

.PARAMETER ModelsOnly
    Only pull models; skip all software installation. Useful to resume
    an interrupted model download. Only applies in Full mode.

.PARAMETER EnableLAN
    Set OLLAMA_HOST=0.0.0.0 to allow LAN access (e.g., from a laptop).
    Without this flag, Ollama only listens on localhost. Only applies in Full
    mode.

.PARAMETER Theme
    Shortcut icon theme. Dark = white icons (visible on dark backgrounds),
    Light = dark icons (visible on light backgrounds). Default: Dark.

.EXAMPLE
    .\install-windows.ps1
    Full installation with Standard profile model pulls.

.EXAMPLE
    .\install-windows.ps1 -ModelProfile Desktop
    Full install for RTX 5090 gaming desktop (pulls larger/better models).

.EXAMPLE
    .\install-windows.ps1 -ModelProfile Server
    Full install for dedicated 4090 inference server.

.EXAMPLE
    .\install-windows.ps1 -Mode Client -OllamaHost http://192.168.1.100:11434
    Client-only install that uses a remote Ollama server.

.EXAMPLE
    .\install-windows.ps1 -ModelPath D:\OllamaModels
    Full install with Ollama models stored on D:.

.EXAMPLE
    .\install-windows.ps1 -SkipModels
    Install software only; pull models later.

.EXAMPLE
    .\install-windows.ps1 -ModelsOnly
    Resume or add model downloads after initial install.

.EXAMPLE
    .\install-windows.ps1 -EnableLAN
    Full install with Ollama accessible from other machines on the LAN.
#>

[CmdletBinding()]
param(
    [ValidateSet("Full", "Client")]
    [string]$Mode = "Full",

    [ValidateSet("Desktop", "Server")]
    [string]$ModelProfile = "Desktop",

    [string]$OllamaHost,
    [string]$ModelPath,
    [switch]$SkipModels,
    [switch]$ModelsOnly,
    [switch]$EnableLAN,

    [ValidateSet("Dark", "Light")]
    [string]$Theme = "Dark",

    [switch]$Help
)

if ($Help) {
    Write-Host @"

  LOCAL LLM INSTALLER — Windows
  ══════════════════════════════════════════════════════════════

  USAGE:
    .\install-windows.ps1 [OPTIONS]

  MODES:
    -Mode Full      (default) Install Ollama, models, Crush, Copilot CLI, uv, MCP, Image Gen
    -Mode Client    Install client tools only (Crush, Copilot CLI, uv, MCP). Requires -OllamaHost.

  GPU PROFILES:
    -ModelProfile Desktop   RTX 5090 (32GB) — 4 models, ~40 GB total:
                              gemma4-65k          General (256k ctx)
                              qwen3:14b           Light coding
                              qwen3:4b            Image gen profile (VRAM-friendly)
                              qwen3coder-65k      Code review (different perspective)

    -ModelProfile Server    RTX 4090 (24GB dedicated) — 4 models, ~40 GB total:
                              gemma4-65k           General (256k ctx)
                              qwen3:14b            Light coding
                              qwen3:4b             Image gen profile (VRAM-friendly)
                              qwen3coder-65k       Code review (different perspective)

  OPTIONS:
    -OllamaHost <url>    Remote Ollama endpoint (required for Client mode)
                         Example: http://192.168.1.100:11434
    -ModelPath <path>    Custom model storage directory (sets OLLAMA_MODELS env var)
    -SkipModels          Install software only; pull models later with: ollama pull <tag>
    -ModelsOnly          Skip software installation; only pull/update models
    -EnableLAN           Set OLLAMA_HOST=0.0.0.0 so other machines can connect
    -Theme <Dark|Light>  Shortcut icon theme (default: Dark)
                         Dark  = white icons (for dark taskbar/Start Menu)
                         Light = dark icons (for light taskbar/Start Menu)
    -Help                Show this help text

  EXAMPLES:
    .\install-windows.ps1                                    # Desktop profile, full install
    .\install-windows.ps1 -ModelProfile Server -EnableLAN    # Server profile, LAN exposed
    .\install-windows.ps1 -Mode Client -OllamaHost http://server:11434
    .\install-windows.ps1 -SkipModels                        # Software only, models later
    .\install-windows.ps1 -ModelsOnly                        # Resume interrupted model pull
    .\install-windows.ps1 -ModelPath D:\OllamaModels         # Custom storage location

  WHAT GETS INSTALLED:
    Component        Location                              Requires Admin
    ─────────        ────────                              ──────────────
    Ollama           System service (winget)               Yes
    ComfyUI Desktop  (removed — replaced by diffusers+FastAPI image gen service)
    Image Gen        %LOCALAPPDATA%\ai-tools\imagegen       No
    Crush            winget portable                       No
    uv + Python      %USERPROFILE%\.local\bin              No
    MCP venvs        %LOCALAPPDATA%\ai-tools\mcp-*        No
    copilot-local    %USERPROFILE%\Documents\CLI           No
    Config           %USERPROFILE%\.config\crush           No

  AFTER INSTALL:
    copilot-local      Launch Copilot CLI with task picker
    crush              Launch Crush (MCP-enabled agent)
    ollama list        Check installed models
    ollama ps          Check loaded models + VRAM usage

"@
    exit 0
}

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Constants ────────────────────────────────────────────────────────────────

$LocalAppData   = $env:LOCALAPPDATA
$UserProfile    = $env:USERPROFILE
$AiToolsDir     = Join-Path $LocalAppData "ai-tools"
$CrushDir       = Join-Path $UserProfile ".config\crush"
$CustomModelListPath = Join-Path $PSScriptRoot "..\config\ollama-models.txt"
$DefaultModelRoot = Join-Path $UserProfile ".ollama\models"
$script:Warnings = @()

# Known model descriptions for progress display
$KnownModelDescriptions = @{
    "gemma4:26b"                     = "Gemma 4 26B MoE — general (256k ctx), ~17 GB"
    "qwen3:14b"                      = "Qwen3 14B — light coding profile (131k ctx), ~9 GB"
    "qwen3:4b"                       = "Qwen3 4B — image gen profile, VRAM-friendly (32k ctx), ~2.5 GB"
    "qwen2.5-coder:14b"             = "Qwen2.5-Coder 14B — code review profile (32k ctx), ~9 GB"
}

$ProfileDefinitions = @{
    "Desktop" = @{
        Description = "RTX 5090 (32GB) — gaming desktop with IDEs open (~25-27 GB available)"
        RequiredGB = 40
        Models = [ordered]@{
            "gemma4:26b"                     = $KnownModelDescriptions["gemma4:26b"]
            "qwen3:14b"                  = $KnownModelDescriptions["qwen3:14b"]
            "qwen3:4b"                   = $KnownModelDescriptions["qwen3:4b"]
            "qwen3-coder:30b"            = "Qwen3-Coder 30B MoE — code review (256k ctx), ~18 GB"
        }
    }
    "Server" = @{
        Description = "RTX 4090 (24GB) — dedicated server, full VRAM"
        RequiredGB = 40
        Models = [ordered]@{
            "gemma4:26b"             = $KnownModelDescriptions["gemma4:26b"]
            "qwen3:14b"            = $KnownModelDescriptions["qwen3:14b"]
            "qwen3:4b"             = $KnownModelDescriptions["qwen3:4b"]
            "qwen3-coder:30b"      = "Qwen3-Coder 30B MoE — code review (256k ctx), ~18 GB"
        }
    }
}

# ── Helpers ──────────────────────────────────────────────────────────────────

$script:StepNumber = 0
$script:Failures = @()

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

function Write-Fail {
    param([string]$Message)
    Write-Host "  ✗  $Message" -ForegroundColor Red
}

function Test-CommandExists {
    param([string]$Command)
    $null -ne (Get-Command $Command -ErrorAction SilentlyContinue)
}

function Set-UserEnvironmentVariable {
    param([string]$Name, [string]$Value)

    $current = [Environment]::GetEnvironmentVariable($Name, "User")
    if ($current -eq $Value) {
        Write-Info "$Name is already set to $Value."
        return
    }

    [Environment]::SetEnvironmentVariable($Name, $Value, "User")
    Set-Item -Path "Env:\$Name" -Value $Value
    Write-Success "Set $Name = $Value"
}

function Install-WinGetPackage {
    param(
        [string]$Id,
        [string]$Name,
        [switch]$Interactive,
        [switch]$Critical
    )

    # Check if already installed
    $installed = winget list --exact --id $Id 2>&1 | Select-String $Id
    if ($installed) {
        Write-Info "$Name is already installed."
        return $true
    }

    $wingetArgs = @("install", "--exact", "--id", $Id, "--accept-source-agreements", "--accept-package-agreements")
    if ($Interactive) {
        $wingetArgs += "--interactive"
        Write-Info "Interactive install — a setup wizard will open. Configure defaults as desired."
    }

    Write-Host "  Installing $Name..." -ForegroundColor White
    & winget @wingetArgs

    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Failed to install $Name (exit code $LASTEXITCODE)."
        Write-Fail "Try installing manually: winget install --exact --id $Id --interactive"
        if ($Critical) {
            $script:Failures += $Name
        }
        return $false
    }

    Write-Success "$Name installed."
    return $true
}

function Wait-ForOllama {
    param([int]$TimeoutSeconds = 30)

    Write-Info "Waiting for Ollama API to become ready..."
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-WebRequest -Uri "http://localhost:11434/api/tags" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
            if ($response.StatusCode -eq 200) {
                Write-Success "Ollama API is ready."
                return $true
            }
        } catch {
            # Not ready yet
        }
        Start-Sleep -Seconds 2
    }

    Write-Warn "Ollama API did not respond within $TimeoutSeconds seconds."
    return $false
}

function Add-NonFatalWarning {
    param([string]$Message)
    $script:Warnings += $Message
    Write-Warn $Message
}

function Get-ResolvedModelRoot {
    if (-not [string]::IsNullOrWhiteSpace($ModelPath)) {
        return $ModelPath
    }

    $configuredModelRoot = [Environment]::GetEnvironmentVariable("OLLAMA_MODELS", "User")
    if (-not [string]::IsNullOrWhiteSpace($configuredModelRoot)) {
        return $configuredModelRoot
    }

    return $DefaultModelRoot
}

function Get-ModelDriveLetter {
    param([string]$Path)

    try {
        return ([System.IO.Path]::GetPathRoot($Path)).TrimEnd("\\")
    } catch {
        return "C:"
    }
}

function Get-EffectiveModelConfig {
    $builtIn = $ProfileDefinitions[$ModelProfile]
    if (Test-Path $CustomModelListPath) {
        $customModels = [ordered]@{}
        foreach ($line in Get-Content -Path $CustomModelListPath) {
            $trimmed = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
                continue
            }
            # Strip inline comments (everything after first #)
            if ($trimmed.Contains("#")) {
                $trimmed = $trimmed.Substring(0, $trimmed.IndexOf("#")).Trim()
            }
            if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
            if (-not $customModels.Contains($trimmed)) {
                $description = if ($KnownModelDescriptions.ContainsKey($trimmed)) {
                    $KnownModelDescriptions[$trimmed]
                } else {
                    "Custom model from config\ollama-models.txt"
                }
                $customModels[$trimmed] = $description
            }
        }

        if ($customModels.Count -eq 0) {
            Write-Warn "Custom model list at $CustomModelListPath is empty after stripping comments. Falling back to $ModelProfile profile."
        } else {
            return @{
                Models = $customModels
                RequiredGB = $builtIn.RequiredGB
                Label = "custom"
                Message = "Using custom model list from config\ollama-models.txt."
                IsCustom = $true
            }
        }
    }

    return @{
        Models = $builtIn.Models
        RequiredGB = $builtIn.RequiredGB
        Label = $ModelProfile
        Message = "Using $ModelProfile profile models."
        IsCustom = $false
    }
}

# ── Pre-flight ───────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "║   Self-Hosted AI Coding Assistant — Windows Installer        ║" -ForegroundColor Magenta
Write-Host "║   Ollama · Crush · uv · MCP Servers                          ║" -ForegroundColor Magenta
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Magenta

if (-not (Test-CommandExists "winget")) {
    Write-Fail "winget is not available. Install App Installer from the Microsoft Store."
    exit 1
}

$IsFullMode = $Mode -eq "Full"
$IsClientMode = $Mode -eq "Client"
$ShouldInstallSoftware = $IsClientMode -or (-not $ModelsOnly)
$ShouldPullModels = $IsFullMode -and (-not $SkipModels)
$EffectiveModelConfig = if ($IsFullMode) { Get-EffectiveModelConfig } else { $null }
$ModelProfileLabel = if ($IsFullMode) { $EffectiveModelConfig.Label } else { "n/a (client mode)" }
$ResolvedModelRoot = if ($IsFullMode) { Get-ResolvedModelRoot } else { $null }
$ModelBlobsPath = if ($IsFullMode) { Join-Path $ResolvedModelRoot "blobs\*" } else { $null }

if ($IsClientMode -and [string]::IsNullOrWhiteSpace($OllamaHost)) {
    Write-Fail "-OllamaHost is required when -Mode Client is used. Example: -Mode Client -OllamaHost http://192.168.1.100:11434"
    exit 1
}

if ($IsClientMode) {
    if ($ModelsOnly) {
        Add-NonFatalWarning "ModelsOnly is ignored in client mode. Continuing with client installation."
        $ShouldInstallSoftware = $true
    }
    if ($SkipModels) {
        Add-NonFatalWarning "SkipModels is irrelevant in client mode because no local models are pulled."
    }
    if ($ModelProfile -ne "Desktop") {
        Add-NonFatalWarning "ModelProfile is ignored in client mode because no local models are pulled."
    }
    if ($EnableLAN) {
        Add-NonFatalWarning "EnableLAN is ignored in client mode because Ollama is not installed locally."
    }
    if (-not [string]::IsNullOrWhiteSpace($ModelPath)) {
        Add-NonFatalWarning "ModelPath is ignored in client mode because no local Ollama model storage is used."
    }
} elseif ($null -ne $EffectiveModelConfig) {
    Write-Info $EffectiveModelConfig.Message
}

# ── Disk space check ─────────────────────────────────────────────────────────

if ($ShouldPullModels) {
    $driveLetter = Get-ModelDriveLetter -Path $ResolvedModelRoot
    $drive = Get-PSDrive -Name $driveLetter.TrimEnd(":") -ErrorAction SilentlyContinue
    if ($drive -and $drive.Free) {
        $freeGB = [math]::Round($drive.Free / 1GB, 1)
        $requiredGB = $EffectiveModelConfig.RequiredGB
        if ($freeGB -lt $requiredGB) {
            Write-Warn "Only $freeGB GB free on $driveLetter. Model pulls need ~$requiredGB GB for the $ModelProfileLabel profile."
            Write-Warn "Consider using -SkipModels and freeing space first."
        } else {
            Write-Info "$freeGB GB free on $driveLetter — sufficient for ~$requiredGB GB of model downloads."
        }
    }
}

# ── Software Installation ────────────────────────────────────────────────────

if ($ShouldInstallSoftware) {

    # ── Step: uv (Python toolchain manager) ──────────────────────────────

    Write-Step "Install uv (Python toolchain manager)"
    Write-Info "uv manages Python versions and virtual environments without touching system Python."
    Write-Info "Installed as a winget portable package (no admin required)."

    Install-WinGetPackage -Id "astral-sh.uv" -Name "uv" -Critical

    # Refresh PATH — winget portable packages add to PATH via WinGet\Links
    $wingetLinks = Join-Path $LocalAppData "Microsoft\WinGet\Links"
    if (($wingetLinks -notin ($env:PATH -split ";")) -and (Test-Path $wingetLinks)) {
        $env:PATH = "$wingetLinks;$env:PATH"
    }

    if (-not (Test-CommandExists "uv")) {
        Write-Warn "uv not found on PATH after install. You may need to restart your terminal."
    } else {
        Write-Success "uv is available: $(uv --version 2>&1)"
    }

    # ── Step: Python 3.12 via uv ────────────────────────────────────────

    Write-Step "Install Python via uv"
    Write-Info "This installs the latest stable Python and adds 'python' to PATH (--default)."

    if (Test-CommandExists "uv") {
        uv python install --default
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Python installed via uv."
        } else {
            Write-Warn "Python install returned exit code $LASTEXITCODE. Check output above."
        }

        # Ensure uv's shim directory is on user PATH
        $uvShimDir = Join-Path $UserProfile ".local\bin"
        $currentUserPath = [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::User)
        if ($currentUserPath -notlike "*$uvShimDir*") {
            [Environment]::SetEnvironmentVariable("Path", "$uvShimDir;$currentUserPath", [EnvironmentVariableTarget]::User)
            Write-Success "Added $uvShimDir to user PATH."
        } else {
            Write-Info "$uvShimDir is already on user PATH."
        }
        # Also add to current session so subsequent steps can find python
        if ($env:PATH -notlike "*$uvShimDir*") {
            $env:PATH = "$uvShimDir;$env:PATH"
        }

        # Disable Windows Store python.exe / python3.exe App Execution Aliases
        # These stubs open the Microsoft Store and intercept the real python on PATH.
        $windowsApps = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps"
        $storeStubs = @("python.exe", "python3.exe")
        foreach ($stub in $storeStubs) {
            $stubPath = Join-Path $windowsApps $stub
            if (Test-Path $stubPath) {
                try {
                    Remove-Item $stubPath -Force -ErrorAction Stop
                    Write-Success "Removed Store alias: $stub"
                } catch {
                    Add-NonFatalWarning "Could not remove Store alias $stub. Disable manually: Settings > Apps > App Execution Aliases."
                }
            }
        }
    } else {
        Write-Warn "Skipping — uv not available. Restart your terminal and run: uv python install --default"
    }

    if ($IsFullMode) {
        # ── Step: Ollama (model server) ──────────────────────────────────

        Write-Step "Install Ollama (model server)"
        Write-Info "Ollama is the ONLY system-level install. It needs GPU access and runs as a service."
        Write-Info "The interactive installer will open — configure install location as desired."

        $ollamaOk = Install-WinGetPackage -Id "Ollama.Ollama" -Name "Ollama" -Interactive -Critical

        # ── Step: Configure Ollama environment ───────────────────────────

        Write-Step "Configure Ollama environment variables"
        Write-Info "OLLAMA_KEEP_ALIVE=5m unloads models after 5 min idle (frees VRAM for IDEs)."

        if ($EnableLAN) {
            Write-Info "OLLAMA_HOST=0.0.0.0 — Ollama will accept connections from the LAN."
            Write-Warn "This exposes an unauthenticated API. Ensure your network is trusted."
            Set-UserEnvironmentVariable -Name "OLLAMA_HOST" -Value "0.0.0.0"
        } else {
            Write-Info "Ollama will listen on localhost only. Use -EnableLAN to allow LAN access."
            Set-UserEnvironmentVariable -Name "OLLAMA_HOST" -Value "127.0.0.1"
        }

        Set-UserEnvironmentVariable -Name "OLLAMA_KEEP_ALIVE" -Value "5m"
        Set-UserEnvironmentVariable -Name "OLLAMA_FLASH_ATTENTION" -Value "1"
        Set-UserEnvironmentVariable -Name "OLLAMA_KV_CACHE_TYPE" -Value "q8_0"
        Write-Info "OLLAMA_FLASH_ATTENTION=1 and OLLAMA_KV_CACHE_TYPE=q8_0 reduce VRAM usage for large contexts."

        if (-not [string]::IsNullOrWhiteSpace($ModelPath)) {
            if (-not (Test-Path $ModelPath)) {
                New-Item -ItemType Directory -Path $ModelPath -Force | Out-Null
                Write-Success "Created $ModelPath"
            } else {
                Write-Info "$ModelPath already exists."
            }
            Set-UserEnvironmentVariable -Name "OLLAMA_MODELS" -Value $ModelPath
            Write-Info "Ollama models will use $ModelPath after Ollama is restarted."
        }

        Write-Warn "Ollama must be restarted to pick up new environment variables."
        Write-Info "After this script completes, restart Ollama from the system tray or reboot."

        # ── Step: Configure backup exclusion ─────────────────────────────

        Write-Step "Configure backup exclusion for Ollama models"
        Write-Info "Adding the Ollama blob store to Macrium Reflect snapshot exclusions reduces backup churn."

        try {
            $registryPath = "HKLM:\SYSTEM\CurrentControlSet\Control\BackupRestore\FilesNotToSnapshotMacriumImage"
            if (-not (Test-Path $registryPath)) {
                New-Item -Path $registryPath -Force | Out-Null
            }
            New-ItemProperty -Path $registryPath -Name "OllamaModels" -Value $ModelBlobsPath -PropertyType String -Force | Out-Null
            Write-Success "Set backup exclusion: OllamaModels = $ModelBlobsPath"
        } catch {
            Add-NonFatalWarning "Could not set Macrium Reflect backup exclusion for $ModelBlobsPath. Re-run elevated if you want this exclusion."
        }
    }

    # ── Step: Crush (CLI agent) ──────────────────────────────────────────

    Write-Step "Install Crush (CLI agent, formerly OpenCode)"
    Write-Info "Crush is the terminal-based AI agent with MCP support, LSP context, and multi-provider."
    Write-Info "Installed as a winget portable package (no admin required)."

    Install-WinGetPackage -Id "charmbracelet.crush" -Name "Crush" -Critical

    if ($IsClientMode) {
        Write-Info "Client mode uses remote Ollama at $OllamaHost."
        Write-Info "Launch Crush after install and set its provider endpoint to $OllamaHost."
    }

    # ── Step: Install MCP tools ──────────────────────────────────────────

    Write-Step "Install MCP tools (uv global)"
    Write-Info "MCP servers installed as uv tools — accessible via 'uvx' command."

    $mcpTools = @(
        @{ Package = "ppt-mcp";         Python = $null;  Desc = "PowerPoint COM automation" }
        @{ Package = "docx-mcp-server"; Python = "3.12"; Desc = "Word OOXML editing" }
    )

    foreach ($tool in $mcpTools) {
        Write-Host "  Installing $($tool.Desc)..." -ForegroundColor White
        $uvArgs = @("tool", "install", $tool.Package)
        if ($tool.Python) {
            $uvArgs += "--python"
            $uvArgs += $tool.Python
        }
        uv @uvArgs 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Success "$($tool.Package) ready."
        } else {
            Write-Warn "$($tool.Package) install failed."
            $script:Failures += "MCP: $($tool.Package)"
        }
    }

    if (-not (Test-Path $CrushDir)) {
        New-Item -ItemType Directory -Path $CrushDir -Force | Out-Null
        Write-Success "Created $CrushDir"
    }

    # ── Step: Deploy Crush configuration ─────────────────────────────────

    Write-Step "Deploy Crush configuration"
    $crushConfigSource = Join-Path $PSScriptRoot "..\config\crush.json"
    $crushConfigDest = Join-Path $CrushDir "crush.json"

    if (Test-Path $crushConfigSource) {
        if (Test-Path $crushConfigDest) {
            Write-Info "Crush config already exists at $crushConfigDest — skipping (won't overwrite)."
        } else {
            # Expand template placeholders for this platform
            $crushContent = Get-Content $crushConfigSource -Raw
            $expandedLocalAppData = ($LocalAppData -replace '\\', '/') # forward slashes for JSON
            $expandedConfigDir = ($crushConfigDir -replace '\\', '/')
            $crushContent = $crushContent -replace '__LOCALAPPDATA__', $expandedLocalAppData
            $crushContent = $crushContent -replace '__VENV_BIN__', '.venv/Scripts'
            $crushContent = $crushContent -replace '__EXE_SUFFIX__', '.exe'
            $crushContent = $crushContent -replace '__EXE__', '.exe'
            $crushContent = $crushContent -replace '__CONFIG_DIR__', $expandedConfigDir
            $crushContent = $crushContent -replace '__IMAGEGEN_HOST__', '127.0.0.1'
            $crushContent = $crushContent -replace '__SQUIRE_SERVER_IP__', '127.0.0.1'
            Set-Content -Path $crushConfigDest -Value $crushContent -Encoding UTF8
            Write-Success "Deployed crush.json to $crushConfigDest"
            Write-Info "Local Ollama is the default provider. Mistral, Google AI Studio, Groq, and OpenRouter available as fallbacks."
            Write-Info "Set MISTRAL_API_KEY, GEMINI_API_KEY, GROQ_API_KEY, and/or OPENROUTER_API_KEY to enable cloud providers."
            Write-Info "MCP servers (Word, PowerPoint) are enabled. Run setup-mcp-venvs.ps1 to install them."
        }
    } else {
        Write-Warn "Config template not found at $crushConfigSource — skipping Crush config."
    }

    # ── Step: Deploy Crush skills and MCP servers ───────────────────────

    Write-Step "Deploy Crush skills and MCP servers"

    # Deploy custom MCP servers (if any)
    $mcpSourceDir = Join-Path $PSScriptRoot "..\config\mcp"
    $mcpDestDir = Join-Path $CrushDir "mcp"
    if (Test-Path $mcpSourceDir) {
        New-Item -ItemType Directory -Path $mcpDestDir -Force | Out-Null
        Copy-Item "$mcpSourceDir\*" $mcpDestDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Success "Deployed MCP servers to $mcpDestDir"
    }

    # Deploy local skills from dotFiles
    $skillsSourceDir = Join-Path $PSScriptRoot "..\config\skills"
    $skillsDestDir = Join-Path $CrushDir "skills"
    if (Test-Path $skillsSourceDir) {
        New-Item -ItemType Directory -Path $skillsDestDir -Force | Out-Null
        Copy-Item "$skillsSourceDir\*" $skillsDestDir -Recurse -Force
        Write-Success "Deployed local skills (git-safety) to $skillsDestDir"
    }

    # Download latest doc-coauthoring skill from anthropics/skills
    $docCoauthoringDir = Join-Path $skillsDestDir "doc-coauthoring"
    New-Item -ItemType Directory -Path $docCoauthoringDir -Force | Out-Null
    $docCoauthoringUrl = "https://raw.githubusercontent.com/anthropics/skills/main/skills/doc-coauthoring/SKILL.md"
    try {
        Invoke-WebRequest -Uri $docCoauthoringUrl -OutFile (Join-Path $docCoauthoringDir "SKILL.md") -ErrorAction Stop
        Write-Success "Downloaded latest doc-coauthoring skill from anthropics/skills"
    } catch {
        Write-Warn "Could not download doc-coauthoring skill: $_"
    }

    # ── Step: Deploy Copilot CLI MCP configuration ────────────────────

    Write-Step "Deploy Copilot CLI MCP configuration"
    $copilotMcpSource = Join-Path $PSScriptRoot "..\config\copilot-mcp-config.json"
    $copilotDir = Join-Path $env:USERPROFILE ".copilot"
    $copilotMcpDest = Join-Path $copilotDir "mcp-config.json"

    if (Test-Path $copilotMcpSource) {
        if (-not (Test-Path $copilotDir)) { New-Item -ItemType Directory -Path $copilotDir -Force | Out-Null }
        if (Test-Path $copilotMcpDest) {
            Write-Info "Copilot MCP config already exists at $copilotMcpDest — skipping (won't overwrite)."
        } else {
            $mcpContent = Get-Content $copilotMcpSource -Raw
            $expandedLocalAppData = ($LocalAppData -replace '\\', '/')
            $expandedConfigDir = ($crushConfigDir -replace '\\', '/')
            $mcpContent = $mcpContent -replace '__LOCALAPPDATA__', $expandedLocalAppData
            $mcpContent = $mcpContent -replace '__VENV_BIN__', '.venv/Scripts'
            $mcpContent = $mcpContent -replace '__EXE_SUFFIX__', '.exe'
            $mcpContent = $mcpContent -replace '__EXE__', '.exe'
            $mcpContent = $mcpContent -replace '__CONFIG_DIR__', $expandedConfigDir
            $mcpContent = $mcpContent -replace '__IMAGEGEN_HOST__', '127.0.0.1'
            Set-Content -Path $copilotMcpDest -Value $mcpContent -Encoding UTF8
            Write-Success "Deployed mcp-config.json to $copilotMcpDest"
        }
    } else {
        Write-Warn "Copilot MCP config template not found — skipping."
    }

    # ── Step: Set up Image Generation service (diffusers + FastAPI) ─────

    if ($IsFullMode) {
        Write-Step "Set up Image Generation service (HiDream-O1-Image-Dev)"
        $imagegenVenv = "$env:LOCALAPPDATA\ai-tools\imagegen\.venv"
        $imagegenDir = "$env:LOCALAPPDATA\ai-tools\imagegen"
        $imagegenRepoDir = "$imagegenDir\HiDream-O1-Image"
        $imagegenScript = "$PSScriptRoot\imagegen-server.py"
        $imagegenStart = "$PSScriptRoot\imagegen-start.cmd"

        # Clone inference repo if missing
        if (-not (Test-Path "$imagegenRepoDir\models\pipeline.py")) {
            Write-Info "Cloning HiDream-O1-Image inference repo..."
            & git clone --depth 1 https://github.com/HiDream-ai/HiDream-O1-Image.git $imagegenRepoDir
        } else {
            Write-Info "HiDream-O1-Image repo already present."
        }

        if (Test-Path "$imagegenVenv\Scripts\python.exe") {
            Write-Info "Image generation venv already exists."
        } else {
            Write-Info "Creating isolated venv for image generation..."
            & uv venv $imagegenVenv --python 3.12 --quiet
            Write-Info "Installing PyTorch (CUDA) + transformers + FastAPI..."
            $env:VIRTUAL_ENV = $imagegenVenv
            & uv pip install --quiet torch torchvision --index-url https://download.pytorch.org/whl/cu128
            & uv pip install --quiet `
                "transformers==4.57.1" diffusers accelerate einops scipy numpy pillow tqdm fastapi uvicorn pydantic huggingface_hub
            Write-Info "Image generation venv created."
        }

        # Download model weights if not cached
        Write-Info "Ensuring HiDream-O1-Image-Dev model is cached (35GB, may take a few minutes)..."
        & "$imagegenVenv\Scripts\python.exe" -c "from huggingface_hub import snapshot_download; snapshot_download('HiDream-ai/HiDream-O1-Image-Dev')" 2>$null
        Write-Info "Model cached."

        # Copy server script and start script to ai-tools directory
        Copy-Item $imagegenScript "$imagegenDir\imagegen-server.py" -Force -ErrorAction SilentlyContinue
        Copy-Item $imagegenStart "$imagegenDir\imagegen-start.cmd" -Force -ErrorAction SilentlyContinue
        Write-Info "Start with: copilot-local (option 7) or imagegen-start.cmd"
        Write-Info "API: POST http://localhost:8001/v1/images/generations"
    }

    # ── Step: Set up imagegen MCP client (fastmcp wrapper) ────────────────

    Write-Step "Set up imagegen MCP client"
    $mcpImagegenDir = "$env:LOCALAPPDATA\ai-tools\mcp-imagegen"
    $mcpImagegenScript = Join-Path $PSScriptRoot "..\mcp\imagegen-mcp-server.py"
    $mcpImagegenVenv = "$mcpImagegenDir\.venv"

    if (Test-Path $mcpImagegenScript) {
        if (-not (Test-Path $mcpImagegenDir)) {
            New-Item -ItemType Directory -Path $mcpImagegenDir -Force | Out-Null
        }
        Copy-Item $mcpImagegenScript "$mcpImagegenDir\imagegen-mcp-server.py" -Force
        if (-not (Test-Path "$mcpImagegenVenv\Scripts\python.exe")) {
            Write-Info "Creating MCP client venv with fastmcp + httpx..."
            & uv venv $mcpImagegenVenv --python 3.12 --quiet 2>$null
            $env:VIRTUAL_ENV = $mcpImagegenVenv
            & uv pip install --quiet fastmcp httpx 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Success "imagegen MCP client venv created."
            } else {
                Write-Warn "Failed to install fastmcp/httpx for imagegen MCP."
                $script:Failures += "imagegen MCP venv"
            }
        } else {
            Write-Info "imagegen MCP client venv already exists."
        }
    } else {
        Write-Warn "imagegen-mcp-server.py not found at $mcpImagegenScript — skipping."
    }

    # ── Step: Deploy copilot-local launcher ───────────────────────────────

    Write-Step "Deploy copilot-local launcher"
    $launcherSource = Join-Path $PSScriptRoot "..\scripts\copilot-local.cmd"
    $launcherDest = Join-Path $UserProfile "Documents\CLI\copilot-local.cmd"

    if (Test-Path $launcherSource) {
        $cliDir = Split-Path $launcherDest
        if (-not (Test-Path $cliDir)) {
            New-Item -ItemType Directory -Path $cliDir -Force | Out-Null
        }
        Copy-Item -Path $launcherSource -Destination $launcherDest -Force
        Write-Success "Deployed copilot-local.cmd to $launcherDest"

        # Ensure Documents\CLI is on PATH
        $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
        if ($userPath -notlike "*$cliDir*") {
            [Environment]::SetEnvironmentVariable("Path", "$userPath;$cliDir", "User")
            $env:PATH = "$env:PATH;$cliDir"
            Write-Success "Added $cliDir to user PATH."
        } else {
            Write-Info "$cliDir is already on PATH."
        }
        Write-Info "Usage: copilot-local (from any directory)"
    } else {
        Write-Warn "Launcher script not found at $launcherSource — skipping."
    }

    # ── Step: Deploy crush-task launcher ──────────────────────────────────

    Write-Step "Deploy crush-task launcher"
    $crushSource = Join-Path $PSScriptRoot "..\scripts\crush-task.ps1"
    $crushDest = Join-Path $UserProfile "Documents\CLI\crush-task.ps1"

    if (Test-Path $crushSource) {
        $cliDir = Split-Path $crushDest
        if (-not (Test-Path $cliDir)) {
            New-Item -ItemType Directory -Path $cliDir -Force | Out-Null
        }
        Copy-Item -Path $crushSource -Destination $crushDest -Force
        Write-Success "Deployed crush-task.ps1 to $crushDest"
    } else {
        Write-Warn "Crush task script not found at $crushSource — skipping."
    }

    # ── Step: Create Start Menu shortcuts ─────────────────────────────────

    Write-Step "Create Start Menu shortcuts"
    $aiFolder = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\AI"
    if (-not (Test-Path $aiFolder)) {
        New-Item -ItemType Directory -Path $aiFolder -Force | Out-Null
    }

    # Deploy all icon variants to ~/.config/crush/
    $iconsSource = Join-Path $PSScriptRoot "icons"
    $iconsDest = Join-Path $UserProfile ".config\crush"
    if (Test-Path $iconsSource) {
        Get-ChildItem (Join-Path $iconsSource "*.ico") | ForEach-Object {
            Copy-Item $_.FullName $iconsDest -Force -ErrorAction SilentlyContinue
        }
        Write-Info "Deployed icon variants to $iconsDest"
    }

    # Select icons based on theme: Dark bg → light variant, Light bg → dark variant
    $themeVariant = if ($Theme -eq "Light") { "dark" } else { "light" }
    $crushIconPath = Join-Path $iconsDest "crush-$themeVariant.ico"
    $copilotIconPath = Join-Path $iconsDest "copilot-$themeVariant.ico"
    # Fallback for Copilot if new naming not found
    if (-not (Test-Path $copilotIconPath)) {
        $copilotIconPath = if ($Theme -eq "Light") {
            Join-Path $iconsDest "copilot.ico"
        } else {
            Join-Path $iconsDest "copilot-white.ico"
        }
    }
    Write-Info "Theme: $Theme → Crush: $(Split-Path $crushIconPath -Leaf), Copilot: $(Split-Path $copilotIconPath -Leaf)"

    $shell = New-Object -ComObject WScript.Shell
    $cliDir = Join-Path $UserProfile "Documents\CLI"

    # Crush (Local) shortcut — launches crush-task.ps1 picker
    $crushLnk = $shell.CreateShortcut((Join-Path $aiFolder "Crush (Local).lnk"))
    $crushLnk.TargetPath = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
    $crushLnk.Arguments = "-NoExit -ExecutionPolicy Bypass -File `"$cliDir\crush-task.ps1`""
    $crushLnk.WorkingDirectory = $UserProfile
    $crushLnk.Description = "Crush CLI with local Ollama — task profile picker"
    if (Test-Path $crushIconPath) { $crushLnk.IconLocation = "$crushIconPath,0" }
    $crushLnk.Save()
    Write-Success "Created shortcut: Crush (Local)"

    # Copilot (Local) shortcut — launches copilot-local.cmd picker
    $copilotLnk = $shell.CreateShortcut((Join-Path $aiFolder "Copilot (Local).lnk"))
    $copilotLnk.TargetPath = "C:\Windows\System32\cmd.exe"
    $copilotLnk.Arguments = "/k `"$cliDir\copilot-local.cmd`""
    $copilotLnk.WorkingDirectory = $UserProfile
    $copilotLnk.Description = "GitHub Copilot CLI with local Ollama — task profile picker"
    if (Test-Path $copilotIconPath) { $copilotLnk.IconLocation = "$copilotIconPath,0" }
    $copilotLnk.Save()
    Write-Success "Created shortcut: Copilot (Local)"

    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null

} # end if ($ShouldInstallSoftware)

# ── Model Pulls ──────────────────────────────────────────────────────────────

if ($ShouldPullModels) {

    Write-Step "Pull Ollama models"
    Write-Info $EffectiveModelConfig.Message

    if (-not (Test-CommandExists "ollama")) {
        # Try common install paths
        $ollamaPaths = @(
            "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe",
            "$env:ProgramFiles\Ollama\ollama.exe"
        )
        foreach ($p in $ollamaPaths) {
            if (Test-Path $p) {
                $env:PATH = "$env:PATH;$(Split-Path $p)"
                break
            }
        }
    }

    if (-not (Test-CommandExists "ollama")) {
        Write-Warn "Ollama not found on PATH. Models cannot be pulled."
        Write-Warn "Restart your terminal and run: ollama pull <model>"
        $script:Failures += "Model pulls (Ollama not on PATH)"
    } else {
        # Wait for Ollama API to be ready before pulling
        $apiReady = Wait-ForOllama -TimeoutSeconds 30
        if (-not $apiReady) {
            Write-Warn "Ollama API not responding. Trying to start Ollama..."
            Start-Process "ollama" -ArgumentList "serve" -WindowStyle Hidden -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 5
            $apiReady = Wait-ForOllama -TimeoutSeconds 15
        }

        if (-not $apiReady) {
            Write-Warn "Could not connect to Ollama. Models cannot be pulled now."
            Write-Warn "Start Ollama manually, then run: .\install-windows.ps1 -ModelsOnly"
            $script:Failures += "Model pulls (Ollama not responding)"
        } else {
            $requiredGB = $EffectiveModelConfig.RequiredGB
            Write-Info "This will download ~$requiredGB GB of model data."
            Write-Info "Each model pull is resumable — safe to interrupt and re-run."
            Write-Host ""

            foreach ($entry in $EffectiveModelConfig.Models.GetEnumerator()) {
                $tag  = $entry.Key
                $desc = $entry.Value
                Write-Host "  Pulling $tag" -ForegroundColor White
                Write-Info $desc
                ollama pull $tag
                if ($LASTEXITCODE -eq 0) {
                    Write-Success "$tag ready."
                } else {
                    Write-Warn "$tag pull returned exit code $LASTEXITCODE."
                    $script:Failures += "Model: $tag"
                }
                Write-Host ""
            }

            # Set num_ctx on models via Modelfiles (Ollama defaults to 2048)
            Write-Host "  Setting context window (num_ctx) on models..." -ForegroundColor White
            $numCtxSettings = @{
                "gemma4:26b"    = 65536
                "qwen3:14b"     = 16384
                "qwen3:4b"      = 8192
                "qwen3-coder:30b" = 65536
            }
            foreach ($entry in $numCtxSettings.GetEnumerator()) {
                $tag = $entry.Key
                $ctx = $entry.Value
                $modelfilePath = Join-Path $env:TEMP "Modelfile-$($tag -replace '[:\.]', '-')"
                @"
FROM $tag
PARAMETER num_ctx $ctx
"@ | Set-Content $modelfilePath
                ollama create $tag -f $modelfilePath 2>$null
                if ($LASTEXITCODE -eq 0) {
                    Write-Info "  $tag → num_ctx $ctx"
                }
                Remove-Item $modelfilePath -ErrorAction SilentlyContinue
            }

            # Create named alias models used by launcher scripts
            Write-Host "  Creating launcher model aliases..." -ForegroundColor White
            $aliasModels = @{
                "gemma4-65k"       = @{ From = "gemma4:26b"; Ctx = 65536 }
                "qwen3coder-65k"   = @{ From = "qwen3-coder:30b"; Ctx = 65536 }
            }
            foreach ($entry in $aliasModels.GetEnumerator()) {
                $alias = $entry.Key
                $cfg   = $entry.Value
                $modelfilePath = Join-Path $env:TEMP "Modelfile-$alias"
                @"
FROM $($cfg.From)
PARAMETER num_ctx $($cfg.Ctx)
"@ | Set-Content $modelfilePath
                ollama create $alias -f $modelfilePath 2>$null
                if ($LASTEXITCODE -eq 0) {
                    Write-Info "  $alias → $($cfg.From) @ num_ctx $($cfg.Ctx)"
                }
                Remove-Item $modelfilePath -ErrorAction SilentlyContinue
            }
        }
    }

} elseif ($IsFullMode) {
    Write-Host ""
    Write-Info "Model pulls skipped. Run later with: .\install-windows.ps1 -ModelsOnly"
}

# ── Summary ──────────────────────────────────────────────────────────────────

Write-Host ""

if ($script:Failures.Count -gt 0 -or $script:Warnings.Count -gt 0) {
    Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "║   Installation Completed with Warnings                      ║" -ForegroundColor Yellow
    Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
    Write-Host ""

    if ($script:Failures.Count -gt 0) {
        Write-Host "  The following items need attention:" -ForegroundColor Yellow
        foreach ($f in $script:Failures) {
            Write-Host "    • $f" -ForegroundColor Yellow
        }
        Write-Host ""
    }

    if ($script:Warnings.Count -gt 0) {
        Write-Host "  Non-fatal warnings:" -ForegroundColor Yellow
        foreach ($w in $script:Warnings) {
            Write-Host "    • $w" -ForegroundColor Yellow
        }
        Write-Host ""
    }
} else {
    Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║   Installation Complete                                     ║" -ForegroundColor Green
    Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""
}

Write-Host "  Mode:" -ForegroundColor White
Write-Host "    • $Mode" -ForegroundColor Gray
Write-Host "  Model profile:" -ForegroundColor White
Write-Host "    • $ModelProfileLabel" -ForegroundColor Gray
Write-Host ""

if ($ShouldInstallSoftware) {
    Write-Host "  What was installed:" -ForegroundColor White
    Write-Host "    • uv              Python toolchain manager (winget portable)" -ForegroundColor Gray
    Write-Host "    • Python 3.12     Managed by uv (isolated)" -ForegroundColor Gray
    if ($IsFullMode) {
        Write-Host "    • Ollama          Model server (system service, GPU access)" -ForegroundColor Gray
    }
    Write-Host "    • Crush           CLI agent (winget portable)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Directories created:" -ForegroundColor White
    Write-Host "    • $AiToolsDir\mcp-*  (MCP server venvs)" -ForegroundColor Gray
    if ($IsClientMode) {
        Write-Host "    • $CrushDir  (Crush configuration)" -ForegroundColor Gray
    } elseif (-not [string]::IsNullOrWhiteSpace($ModelPath)) {
        Write-Host "    • $ModelPath  (Ollama model storage)" -ForegroundColor Gray
    }
    Write-Host ""
}

Write-Host "  Next steps:" -ForegroundColor White
Write-Host "    1. Restart your terminal (PATH changes need a new session)" -ForegroundColor Yellow
if ($IsFullMode) {
    Write-Host "    2. Restart Ollama from system tray (picks up env vars)" -ForegroundColor Yellow
    Write-Host "    3. Verify: ollama list" -ForegroundColor Yellow
    Write-Host "    4. Test:   crush" -ForegroundColor Yellow
} else {
    Write-Host "    2. Configure Crush to point to $OllamaHost" -ForegroundColor Yellow
    Write-Host "    3. Test remote inference from Crush" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  See README.md for 'How to Test' and 'How to Get Started' guides." -ForegroundColor Gray
Write-Host ""

if ($script:Failures.Count -gt 0) {
    exit 1
}
