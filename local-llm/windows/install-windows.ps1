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
      Layer 4 (Config):    %USERPROFILE%\.ollama and %USERPROFILE%\.crush

    Full mode installs the complete local stack. Client mode installs only the
    client tooling and points Crush at a remote Ollama endpoint.

.PARAMETER Mode
    Installation mode. Full installs Ollama locally and can pull models. Client
    skips all Ollama installation and model steps, and requires -OllamaHost.

.PARAMETER ModelProfile
    Controls which 30B Qwen quantization is pulled in Full mode. Standard uses
    qwen3:30b, High uses qwen3:30b-q5_K_M, and Ultra uses qwen3:30b-q6_K.
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

.EXAMPLE
    .\install-windows.ps1
    Full installation with Standard profile model pulls.

.EXAMPLE
    .\install-windows.ps1 -ModelProfile High
    Full install with the High profile primary model.

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

    [ValidateSet("Standard", "High", "Ultra")]
    [string]$ModelProfile = "Standard",

    [string]$OllamaHost,
    [string]$ModelPath,
    [switch]$SkipModels,
    [switch]$ModelsOnly,
    [switch]$EnableLAN
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Constants ────────────────────────────────────────────────────────────────

$LocalAppData   = $env:LOCALAPPDATA
$UserProfile    = $env:USERPROFILE
$AiToolsDir     = Join-Path $LocalAppData "ai-tools"
$CrushDir       = Join-Path $UserProfile ".crush"
$CustomModelListPath = Join-Path $PSScriptRoot "config\ollama-models.txt"
$DefaultModelRoot = Join-Path $UserProfile ".ollama\models"
$script:Warnings = @()

# Known model descriptions for progress display
$KnownModelDescriptions = @{
    "qwen3:30b"           = "Qwen 3.6-27B (Q4_K_M) — primary coder, ~18 GB"
    "qwen3:30b-q5_K_M"    = "Qwen 3.6-27B (Q5_K_M) — primary coder, ~21 GB"
    "qwen3:30b-q6_K"      = "Qwen 3.6-27B (Q6_K) — primary coder, ~24 GB"
    "qwen3:8b"            = "Qwen 3.6-8B — fast tasks, ~5 GB"
    "deepseek-r1:14b"     = "DeepSeek R1 14B — hard reasoning, ~9 GB"
    "llama3.1:8b"         = "Llama 3.1-8B — general/sysadmin, ~5 GB"
}

$ProfileDefinitions = @{
    "Standard" = @{
        RequiredGB = 38
        Models = [ordered]@{
            "qwen3:30b"       = $KnownModelDescriptions["qwen3:30b"]
            "qwen3:8b"        = $KnownModelDescriptions["qwen3:8b"]
            "deepseek-r1:14b" = $KnownModelDescriptions["deepseek-r1:14b"]
            "llama3.1:8b"     = $KnownModelDescriptions["llama3.1:8b"]
        }
    }
    "High" = @{
        RequiredGB = 41
        Models = [ordered]@{
            "qwen3:30b-q5_K_M" = $KnownModelDescriptions["qwen3:30b-q5_K_M"]
            "qwen3:8b"         = $KnownModelDescriptions["qwen3:8b"]
            "deepseek-r1:14b"  = $KnownModelDescriptions["deepseek-r1:14b"]
            "llama3.1:8b"      = $KnownModelDescriptions["llama3.1:8b"]
        }
    }
    "Ultra" = @{
        RequiredGB = 44
        Models = [ordered]@{
            "qwen3:30b-q6_K"  = $KnownModelDescriptions["qwen3:30b-q6_K"]
            "qwen3:8b"        = $KnownModelDescriptions["qwen3:8b"]
            "deepseek-r1:14b" = $KnownModelDescriptions["deepseek-r1:14b"]
            "llama3.1:8b"     = $KnownModelDescriptions["llama3.1:8b"]
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
            if (-not $customModels.Contains($trimmed)) {
                $description = if ($KnownModelDescriptions.ContainsKey($trimmed)) {
                    $KnownModelDescriptions[$trimmed]
                } else {
                    "Custom model from config\ollama-models.txt"
                }
                $customModels[$trimmed] = $description
            }
        }

        return @{
            Models = $customModels
            RequiredGB = $builtIn.RequiredGB
            Label = "custom"
            Message = "Using custom model list from config\ollama-models.txt."
            IsCustom = $true
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
Write-Host "║   Self-Hosted AI Coding Assistant — Windows Installer       ║" -ForegroundColor Magenta
Write-Host "║   Ollama · Crush · uv · MCP Servers                        ║" -ForegroundColor Magenta
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
    if ($ModelProfile -ne "Standard") {
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

    Write-Step "Install Python 3.12 via uv"
    Write-Info "This installs Python 3.12 under uv's managed directory — no system-wide Python."

    if (Test-CommandExists "uv") {
        uv python install 3.12
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Python 3.12 installed via uv."
        } else {
            Write-Warn "Python 3.12 install returned exit code $LASTEXITCODE. Check output above."
        }
    } else {
        Write-Warn "Skipping — uv not available. Restart your terminal and run: uv python install 3.12"
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

    # ── Step: MCP server directory ───────────────────────────────────────

    Write-Step "Create MCP server directories"
    Write-Info "MCP servers will live in isolated uv venvs under $AiToolsDir."

    $mcpDirs = @(
        (Join-Path $AiToolsDir "mcp-office")
        (Join-Path $AiToolsDir "mcp-pptx")
        (Join-Path $AiToolsDir "mcp-word")
    )

    foreach ($dir in $mcpDirs) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Write-Success "Created $dir"
        } else {
            Write-Info "$dir already exists."
        }
    }

    if (-not (Test-Path $CrushDir)) {
        New-Item -ItemType Directory -Path $CrushDir -Force | Out-Null
        Write-Success "Created $CrushDir"
    }

    Write-Info "MCP server venvs will be set up during Phase 2 (MCP Integration)."
    Write-Info "See README.md for instructions on installing OfficeMCP."

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
