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
    skips all Ollama installation and model steps and targets the vLLM server
    (use -SquireServerIP if it is not 192.168.1.99).

.PARAMETER OllamaModels
    Ollama roster GPU tier that determines which models to pull:
      5090 — (default) RTX 5090 (32GB). Pulls the six production models
             (Qwen3.6 27B+MTP, Qwen3.6 35B-A3B, Gemma 4 31B, Qwen3-Coder 30B,
             GLM-4.7-Flash, Qwen3 8B) (~100 GB) — coherent with config\crush.json.
      4090 — RTX 4090 (24GB). Same production roster fallback (~100 GB); contexts
             are tuned for 32GB and may spill to CPU on 24GB.
    -TestProfiles installs the same roster PLUS the heavy-coding + expert-offload
    bench contenders. Ignored in Client mode.

.PARAMETER SquireServerIP
    IP/host of the CachyOS vLLM "Squire Server" used by the launcher Remote
    [S]/[C]/[V]/[I] options and the crush.json 'server' provider. Default:
    192.168.1.99.

.PARAMETER SquireSSHTarget
    SSH target (user@host or ssh-config alias) the launcher uses to call
    'cachyos-switch-model' on the Squire Server. Default: jesse@192.168.1.99.

.PARAMETER OllamaHost
    Optional. An additional remote Ollama endpoint to keep available as a Crush
    provider (for example: http://192.168.1.100:11434). Not required for Client
    mode — Client mode targets the vLLM server via -SquireServerIP.

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
    .\install-windows.ps1 -OllamaModels 5090
    Full install for RTX 5090 gaming desktop (pulls larger/better models).

.EXAMPLE
    .\install-windows.ps1 -OllamaModels 4090
    Full install for dedicated 4090 inference server.

.EXAMPLE
    .\install-windows.ps1 -Mode Client
    Client-only install (Profile 2): tools only, Crush defaults to the vLLM server (192.168.1.99).

.EXAMPLE
    .\install-windows.ps1 -ModelPath D:\OllamaModels
    Full install with Ollama models stored on D:.

.EXAMPLE
    .\install-windows.ps1 -TestProfiles -DataRoot V:\ollama
    Full install with ALL large AI-stack data (models, image-gen, MCP venvs, HF cache)
    stored under V:\ollama instead of the OS drive.

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

    [ValidateSet("", "Full", "Client", "OllamaOnly")]
    [string]$Install = "",

    [string]$Providers = "",

    [ValidateSet("", "local", "server", "squire-server")]
    [string]$DefaultProvider = "",

    [ValidateSet("4090", "5090")]
    [string]$OllamaModels = "5090",

    [string]$OllamaHost,
    [string]$ModelPath,
    [string]$DataRoot,
    [switch]$SkipModels,
    [switch]$ModelsOnly,
    [switch]$EnableLAN,
    [switch]$TestProfiles,
    [switch]$SkipWslNetworking,
    [switch]$Force,

    [string]$SquireServerIP = "192.168.1.99",
    [string]$SquireSSHTarget = "jesse@192.168.1.99",

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

  MODES (legacy alias for -Install; kept for back-compat):
    -Mode Full      = -Install Full
    -Mode Client    = -Install Client

  INSTALL (what to install; -Install supersedes the legacy -Mode alias):
    -Install Full        (default) Local Ollama server + models + client tools
    -Install Client      Client tools only (Crush, Copilot CLI, uv, MCP) — no local Ollama
    -Install OllamaOnly  Local Ollama server + models only — no client tools

  PROVIDERS (which crush providers + launcher entries; cloud providers always kept):
    -Providers <list>        Comma list of: local, server  (default: Full->both, Client->server)
                             local = local Ollama · server = CachyOS vLLM server. ('squire-server' accepted as a deprecated alias.)
    -DefaultProvider <p>     local | server  (default: Full->local, Client->server)
    -SquireServerIP <ip>     vLLM server address (default: 192.168.1.99)

  GPU TIER:
    -OllamaModels 5090      (default) RTX 5090 (32GB) — the six production models, ~100 GB:
                              qwen36-27b-212k     Heavy coding default (Qwen3.6 27B+MTP)
                              qwen36-35b-256k     Heavy coding / multimodal (Qwen3.6 35B-A3B)
                              gemma4-31b-128k     Heavy coding / general (Gemma 4 31B)
                              qwen3coder-144k     Light coding / review (Qwen3-Coder 30B)
                              glm47-flash-198k    Agentic / all MCP+tools (GLM-4.7-Flash)
                              qwen3:8b            Image-gen companion

    -OllamaModels 4090      RTX 4090 (24GB) — same production roster fallback (~100 GB);
                              contexts are tuned for 32GB and may spill to CPU on 24GB.

  OPTIONS:
    -OllamaHost <url>    Optional extra remote Ollama provider (not required for Client mode)
                         Example: http://192.168.1.100:11434
    -TestProfiles        RTX 5090 side-by-side bench: installs the heavy-coding contenders
                         (qwen3.6 27B+MTP/35B, gemma4 31B, qwen3-coder, glm-4.7-flash,
                         qwen3 8B + the §K/§L additions North Mini Code 1.0, Nemotron
                         Cascade 2 30B-A3B, Ornith-1.0-35B) and their launcher aliases
                         (qwen36-27b-212k/qwen3coder-144k/glm47-flash-198k/northmini-code-256k/
                         nemotron-c2-256k/ornith-35b-256k/etc.), PLUS the
                         Qwen3-Next-80B-A3B (Q4_K_M GGUF) expert-offload bench
                         (qwen3next-80b-offload). ~225 GB. Use with
                         -ModelPath to put the models off the OS drive.
    -ModelPath <path>    Custom model storage directory (sets OLLAMA_MODELS env var)
    -DataRoot <path>     Put ALL large AI-stack data off the OS drive under one root:
                         <root>\models (Ollama), <root>\ai-tools (image-gen + MCP
                         venvs), <root>\hf-cache (HuggingFace cache / HF_HOME).
                         Sets AI_TOOLS_DIR + HF_HOME. uv/Python stay on C: (excluded).
                         -ModelPath still overrides just the models subpath.
                         Example: -DataRoot V:\ollama
    -SkipModels          Install software only; pull models later with: ollama pull <tag>
    -ModelsOnly          Skip software installation; only pull/update models
    -EnableLAN           Set OLLAMA_HOST=0.0.0.0 so other machines can connect
    -SkipWslNetworking   Don't configure WSL2 mirrored networking (.wslconfig)
    -Force               Overwrite existing crush.json + Copilot mcp-config.json (skipped by default).
                         Backs each up to a timestamped .bak first. Use to refresh outdated client
                         config, e.g. after a provider/roster change.
    -Theme <Dark|Light>  Shortcut icon theme (default: Dark)
                         Dark  = white icons (for dark taskbar/Start Menu)
                         Light = dark icons (for light taskbar/Start Menu)
    -Help                Show this help text

  EXAMPLES:
    .\install-windows.ps1                                    # 5090 tier, full install
    .\install-windows.ps1 -OllamaModels 4090 -EnableLAN      # 4090 tier, LAN exposed
    .\install-windows.ps1 -Mode Client                      # Profile 2: squire-only client
    .\install-windows.ps1 -Install Full                                                  # 5090: Ollama server + client (local+server)
    .\install-windows.ps1 -Install Client -Providers local,server -DefaultProvider local  # client tools, both, default local
    .\install-windows.ps1 -Install Client -Providers local,server -DefaultProvider local -Force  # refresh client config on an existing box
    .\install-windows.ps1 -Install Client                                                # server-only client (pointed at vLLM)
    .\install-windows.ps1 -SkipModels                        # Software only, models later
    .\install-windows.ps1 -ModelsOnly                        # Resume interrupted model pull
    .\install-windows.ps1 -ModelPath D:\OllamaModels         # Custom storage location

  WHAT GETS INSTALLED:
    Component        Location                              Requires Admin
    ─────────        ────────                              ──────────────
    Ollama           System service (winget)               Yes
    ComfyUI Desktop  (removed — replaced by diffusers+FastAPI image gen service)
    Image Gen        <DataRoot>\ai-tools\imagegen           No
                     (default %LOCALAPPDATA%\ai-tools\imagegen)
    Crush            winget portable                       No
    uv + Python      %USERPROFILE%\.local\bin              No
    MCP venvs        <DataRoot>\ai-tools\mcp-*              No
                     (default %LOCALAPPDATA%\ai-tools\mcp-*)
    HF model cache   <DataRoot>\hf-cache (HF_HOME)          No
                     (default %USERPROFILE%\.cache\huggingface)
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

# ── Data root ────────────────────────────────────────────────────────────────
# When -DataRoot is set, large AI-stack artifacts live under it instead of the OS
# drive: Ollama models (<DataRoot>\models), image-gen repo+venv and MCP venvs
# (<DataRoot>\ai-tools), and the HuggingFace cache (<DataRoot>\hf-cache = HF_HOME).
# uv and its managed Python are intentionally EXCLUDED (standalone tool, not AI
# stack). When -DataRoot is omitted, everything falls back to the LocalAppData /
# default-cache behavior (backward compatible). Runtime consumers (imagegen server,
# MCP client, launch scripts) read the AI_TOOLS_DIR + HF_HOME env vars the installer
# sets below, with a LocalAppData fallback.
if (-not [string]::IsNullOrWhiteSpace($DataRoot)) {
    $AiToolsRoot = $DataRoot
    $HFCacheDir  = Join-Path $DataRoot "hf-cache"
    if ([string]::IsNullOrWhiteSpace($ModelPath)) {
        $ModelPath = Join-Path $DataRoot "models"
    }
} else {
    $AiToolsRoot = $LocalAppData
    $HFCacheDir  = $null
}
$AiToolsDir     = Join-Path $AiToolsRoot "ai-tools"
$CrushDir       = Join-Path $UserProfile ".config\crush"
# OPTIONAL override: if a user drops a `config\ollama-models.txt` in place (see the
# shipped .example), the installer pulls those tags instead of the profile's models.
# Absent by default, so the built-in profile roster is authoritative.
$CustomModelListPath = Join-Path $PSScriptRoot "..\config\ollama-models.txt"
$DefaultModelRoot = Join-Path $UserProfile ".ollama\models"
$script:Warnings = @()

# Known model descriptions for progress display
$KnownModelDescriptions = @{
    "hf.co/unsloth/Qwen3.6-27B-MTP-GGUF:Q4_K_M" = "Qwen3.6 27B (+MTP head) — heavy coding default (212k ctx), ~16 GB"
    "qwen3.6:35b"     = "Qwen3.6 35B-A3B MoE — heavy coding / multimodal (256k ctx), ~22 GB"
    "gemma4:31b"      = "Gemma 4 31B Dense — heavy coding / general (128k ctx), ~20 GB"
    "qwen3-coder:30b" = "Qwen3-Coder 30B-A3B MoE — light coding / review (144k ctx), ~18 GB"
    "glm-4.7-flash"   = "GLM-4.7-Flash MoE-lite — agentic / all MCP+tools (198k ctx), ~18 GB"
    "qwen3:8b"        = "Qwen3 8B Dense — image-gen companion (32k ctx), ~5 GB"
}

# Production roster — the six daily models exposed in config\crush.json + the launcher
# Tier-1 profiles. The default (non -TestProfiles) install pulls exactly these and builds
# the matching aliases (see $ProductionAliases below), so a generic install is coherent
# with crush.json. -TestProfiles is a SUPERSET that adds the bench/offload contenders.
$ProductionModels = [ordered]@{
    "hf.co/unsloth/Qwen3.6-27B-MTP-GGUF:Q4_K_M" = $KnownModelDescriptions["hf.co/unsloth/Qwen3.6-27B-MTP-GGUF:Q4_K_M"]
    "qwen3.6:35b"     = $KnownModelDescriptions["qwen3.6:35b"]
    "gemma4:31b"      = $KnownModelDescriptions["gemma4:31b"]
    "qwen3-coder:30b" = $KnownModelDescriptions["qwen3-coder:30b"]
    "glm-4.7-flash"   = $KnownModelDescriptions["glm-4.7-flash"]
    "qwen3:8b"        = $KnownModelDescriptions["qwen3:8b"]
}

$ProfileDefinitions = @{
    "5090" = @{
        Description = "RTX 5090 (32GB) — the six production models (coherent with crush.json + launchers)"
        RequiredGB = 100
        Models = $ProductionModels
    }
    "4090" = @{
        # The real model server is the CachyOS/vLLM box (install-cachyos.sh); this Windows
        # profile is a coherent fallback that mirrors the Desktop production roster. Contexts
        # are 32GB-calibrated, so on a 24GB card the larger-ctx aliases may spill to CPU.
        Description = "RTX 4090 (24GB) — production roster fallback (contexts tuned for 32GB; may spill on 24GB)"
        RequiredGB = 100
        Models = $ProductionModels
    }
    # 5090 side-by-side test profile (-TestProfiles). ~1TB model storage, so every
    # contender is installed at once and exposed through the launcher [H1]-[H5] bench.
    # NOTE: base pull tags below must be validated on the box — exact Ollama tags for
    # qwen3.6:35b / gemma4:31b / glm-4.7-flash may differ at install time.
    "Desktop5090Test" = @{
        Description = "RTX 5090 (32GB) — side-by-side model bench (~1TB model storage)"
        RequiredGB = 290
        Models = [ordered]@{
            # Qwen3.6 27B heavy-coding default — repointed to the unsloth MTP GGUF (multi-token-prediction
            # head). Same weights/quality as qwen3.6:27b dense; if Ollama's engine drives the MTP head it is
            # a free speculative speedup, otherwise it runs as the standard dense model. Verify on box.
            "hf.co/unsloth/Qwen3.6-27B-MTP-GGUF:Q4_K_M" = "Qwen3.6 27B (+MTP head) — heavy coding default (256k ctx), ~16 GB"
            "qwen3.6:35b"      = "Qwen3.6 35B-A3B MoE — heavy coding bench / multimodal (262k ctx), ~22 GB"
            "gemma4:31b"       = "Gemma 4 31B Dense — heavy coding bench / re-test (128k ctx), ~20 GB"
            "qwen3-coder:30b"  = "Qwen3-Coder 30B-A3B MoE — light coding / review (256k ctx), ~18 GB"
            "glm-4.7-flash"    = "GLM-4.7-Flash MoE-lite — agentic / all MCP+tools (198k ctx), ~18 GB"
            # New agentic-coding bench candidates (2026-06-27 research sweep, §K/§L). All fit VRAM-resident
            # at Q4 on the 32 GB 5090; pulled via Ollama's HF passthrough. North Mini Code = Cohere coding
            # specialist (cohere2moe, Apache 2.0). Nemotron Cascade 2 = NVIDIA reasoning+agentic MoE
            # (nemotron_h_moe, NVIDIA Open License) — verify the hybrid arch loads in Ollama's engine at
            # bring-up. Ornith-1.0-35B = MIT agentic-coding specialist (qwen35moe, reasoning + tool-calls).
            "hf.co/unsloth/North-Mini-Code-1.0-GGUF:UD-Q4_K_M" = "North Mini Code 1.0 (Cohere) — agentic-coding bench (256k ctx), ~18 GB"
            "hf.co/bartowski/nvidia_Nemotron-Cascade-2-30B-A3B-GGUF:Q4_K_M" = "Nemotron Cascade 2 30B-A3B (NVIDIA) — reasoning/agentic bench (256k ctx), ~23 GB"
            "hf.co/deepreinforce-ai/Ornith-1.0-35B-GGUF:Q4_K_M" = "Ornith-1.0-35B (MIT) — agentic-coding reasoning bench (256k ctx), ~20 GB"
            "qwen3:8b"         = "Qwen3 8B Dense — image-gen companion (32k ctx), ~5 GB"
            # Qwen3-Next-80B-A3B-Instruct offload bench. The official Ollama tag is 159 GB (full
            # precision) and does NOT fit 96 GB, but the official Qwen GGUF repo publishes a single-file
            # Q4_K_M (~45 GB) that does. Pulled directly via Ollama's HF passthrough; the offload alias
            # below is built FROM this tag. Alternate (quality-leaning): unsloth's UD-Q4_K_XL (~43 GB).
            "hf.co/Qwen/Qwen3-Next-80B-A3B-Instruct-GGUF:Q4_K_M" = "Qwen3-Next-80B-A3B-Instruct (Q4_K_M GGUF) — expert-offload bench, ~45 GB"
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

function Set-WslMirroredNetworking {
    # Enable WSL2 mirrored networking so distros (e.g. CachyOS) reach the host's
    # 127.0.0.1:11434 Ollama as localhost:11434 — no need to bind Ollama to 0.0.0.0.
    # Authoritative: MS Learn wsl-config — networkingMode=mirrored, requires Win11 22H2
    # (build 22621)+, config at %UserProfile%\.wslconfig. Idempotent; backs up existing.
    $build = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
    if ($build -lt 22621) {
        Add-NonFatalWarning "WSL mirrored networking needs Windows 11 22H2 (build 22621+); this is $build. Skipping."
        return
    }
    if (-not (Test-CommandExists "wsl")) {
        Write-Info "wsl.exe not found — skipping WSL mirrored networking (no WSL installed)."
        return
    }

    $wslConfig = Join-Path $env:USERPROFILE ".wslconfig"
    $needsMirror = $true
    if (Test-Path $wslConfig) {
        $content = Get-Content $wslConfig -Raw
        if ($content -match '(?im)^\s*networkingMode\s*=\s*mirrored\s*$') {
            Write-Info ".wslconfig already sets networkingMode=mirrored."
            $needsMirror = $false
        }
    }

    if ($needsMirror) {
        $lines = if (Test-Path $wslConfig) { @(Get-Content $wslConfig) } else { @() }
        if (Test-Path $wslConfig) {
            $backup = "$wslConfig.bak"
            Copy-Item $wslConfig $backup -Force
            Write-Info "Backed up existing .wslconfig to $backup"
        }
        # Drop any existing networkingMode line, then ensure a [wsl2] section carries mirrored.
        $lines = $lines | Where-Object { $_ -notmatch '(?i)^\s*networkingMode\s*=' }
        if ($lines -match '(?im)^\s*\[wsl2\]\s*$') {
            $out = New-Object System.Collections.Generic.List[string]
            foreach ($l in $lines) {
                $out.Add($l)
                if ($l -match '(?im)^\s*\[wsl2\]\s*$') { $out.Add("networkingMode=mirrored") }
            }
            $lines = $out
        } else {
            $lines = @("[wsl2]", "networkingMode=mirrored") + $lines
        }
        Set-Content -Path $wslConfig -Value $lines -Encoding UTF8
        Write-Success "Wrote networkingMode=mirrored to $wslConfig"
    }

    # Mirrored takes effect only after the WSL VM restarts; this kills ALL distros (incl. docker-desktop).
    Write-Warn "Applying needs 'wsl --shutdown', which stops ALL distros including docker-desktop."
    $ans = Read-Host "  Run 'wsl --shutdown' now to apply mirrored networking? [y/N]"
    if ($ans -match '^(y|yes)$') {
        wsl --shutdown
        Write-Success "WSL shut down — mirrored networking applies on next launch."
    } else {
        Write-Info "Run 'wsl --shutdown' when ready to apply (then relaunch your distro)."
    }
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
    $profileKey = if ($TestProfiles) { "Desktop5090Test" } else { $OllamaModels }
    $builtIn = $ProfileDefinitions[$profileKey]
    if ((-not $TestProfiles) -and (Test-Path $CustomModelListPath)) {
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
            Write-Warn "Custom model list at $CustomModelListPath is empty after stripping comments. Falling back to $OllamaModels tier."
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
        Label = $profileKey
        Message = "Using $profileKey profile models."
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

# Reconcile -Install (primary) with legacy -Mode (alias). -Install takes precedence.
$InstallClientTools = $true
if (-not [string]::IsNullOrWhiteSpace($Install)) {
    switch ($Install) {
        "Full"       { $IsFullMode = $true;  $IsClientMode = $false; $InstallClientTools = $true }
        "Client"     { $IsFullMode = $false; $IsClientMode = $true;  $InstallClientTools = $true }
        "OllamaOnly" { $IsFullMode = $true;  $IsClientMode = $false; $InstallClientTools = $false }
    }
} else {
    $Install = $Mode   # legacy -Mode path
}

# Provider selection (crush providers + launcher entries). Defaults depend on install type.
# 'server' is the canonical vLLM provider token; 'squire-server' is a deprecated input alias.
if ([string]::IsNullOrWhiteSpace($Providers)) {
    $Providers = if ($IsFullMode) { "local,server" } else { "server" }
}
$Providers = ($Providers -replace '\s', '').ToLower()
$Providers = ($Providers -split ',' | ForEach-Object { if ($_ -eq 'squire-server') { 'server' } else { $_ } }) -join ','
if ([string]::IsNullOrWhiteSpace($DefaultProvider)) {
    $DefaultProvider = if ($IsFullMode) { "local" } else { "server" }
}
if ($DefaultProvider -eq 'squire-server') { $DefaultProvider = 'server' }
foreach ($pv in ($Providers -split ',')) {
    if ($pv -notin @('local', 'server')) {
        Write-Fail "-Providers entries must be 'local' or 'server' (got '$pv')."; exit 1
    }
}
if (",$Providers," -notlike "*,$DefaultProvider,*") {
    Write-Fail "-DefaultProvider '$DefaultProvider' must be one of -Providers '$Providers'."; exit 1
}

$ShouldInstallSoftware = $IsClientMode -or (-not $ModelsOnly)
$ShouldPullModels = $IsFullMode -and (-not $SkipModels)
$EffectiveModelConfig = if ($IsFullMode) { Get-EffectiveModelConfig } else { $null }
$ModelTierLabel = if ($IsFullMode) { $EffectiveModelConfig.Label } else { "n/a (client mode)" }
$ResolvedModelRoot = if ($IsFullMode) { Get-ResolvedModelRoot } else { $null }
$ModelBlobsPath = if ($IsFullMode) { Join-Path $ResolvedModelRoot "blobs\*" } else { $null }

if ($IsClientMode -and -not [string]::IsNullOrWhiteSpace($OllamaHost)) {
    Write-Info "Client mode targets the vLLM server; -OllamaHost ('$OllamaHost') will be kept only as an optional extra remote-Ollama provider."
}

if ($IsClientMode) {
    if ($ModelsOnly) {
        Add-NonFatalWarning "ModelsOnly is ignored in client mode. Continuing with client installation."
        $ShouldInstallSoftware = $true
    }
    if ($SkipModels) {
        Add-NonFatalWarning "SkipModels is irrelevant in client mode because no local models are pulled."
    }
    if ($OllamaModels -ne "5090") {
        Add-NonFatalWarning "-OllamaModels is ignored in client mode because no local models are pulled (the client targets the vLLM server)."
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
            Write-Warn "Only $freeGB GB free on $driveLetter. Model pulls need ~$requiredGB GB for the $ModelTierLabel tier."
            Write-Warn "Consider using -SkipModels and freeing space first."
        } else {
            Write-Info "$freeGB GB free on $driveLetter — sufficient for ~$requiredGB GB of model downloads."
        }
    }
}

# ── Software Installation ────────────────────────────────────────────────────

if ($ShouldInstallSoftware) {

    # ── Step: Configure data-root storage ────────────────────────────────
    # Set AI_TOOLS_DIR + HF_HOME so this run (and future tools) place the image-gen
    # repo/venv, MCP venvs, and the HuggingFace cache under -DataRoot instead of C:.
    # Setting them here (before the image-gen step) ensures the in-run snapshot
    # download honors HF_HOME. uv/Python stay on the OS drive (excluded by design).
    if (-not [string]::IsNullOrWhiteSpace($DataRoot)) {
        Write-Step "Configure data-root storage ($DataRoot)"
        Write-Info "AI-stack artifacts (models, image-gen, MCP venvs, HF cache) will live under $DataRoot."
        Write-Info "uv and its managed Python stay on the OS drive (standalone tool, not part of the AI stack)."
        foreach ($d in @($AiToolsDir, $HFCacheDir)) {
            if ($d -and -not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        }
        Set-UserEnvironmentVariable -Name "AI_TOOLS_DIR" -Value $AiToolsDir
        Set-UserEnvironmentVariable -Name "HF_HOME" -Value $HFCacheDir
    }

    # ── Step: uv (Python toolchain manager) ──────────────────────────────

    Write-Step "Install uv (Python toolchain manager)"
    Write-Info "uv manages Python versions and virtual environments without touching system Python."
    Write-Info "Installed as a winget portable package (no admin required)."

    Install-WinGetPackage -Id "astral-sh.uv" -Name "uv" -Critical | Out-Null

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
            # Idempotent: if the exclusion is already set to this value, skip the write.
            # This avoids a spurious "could not set" warning on unelevated re-runs where
            # the value already exists (the HKLM write needs elevation, but isn't needed).
            $existingExcl = $null
            if (Test-Path $registryPath) {
                $existingExcl = (Get-ItemProperty -Path $registryPath -Name "OllamaModels" -ErrorAction SilentlyContinue).OllamaModels
            }
            if ($existingExcl -eq $ModelBlobsPath) {
                Write-Info "Backup exclusion already set: OllamaModels = $ModelBlobsPath"
            } else {
                if (-not (Test-Path $registryPath)) {
                    New-Item -Path $registryPath -Force | Out-Null
                }
                New-ItemProperty -Path $registryPath -Name "OllamaModels" -Value $ModelBlobsPath -PropertyType String -Force | Out-Null
                Write-Success "Set backup exclusion: OllamaModels = $ModelBlobsPath"
            }
        } catch {
            Add-NonFatalWarning "Could not set Macrium Reflect backup exclusion for $ModelBlobsPath. Re-run elevated if you want this exclusion."
        }

        # ── Step: WSL mirrored networking ────────────────────────────────

        if ($SkipWslNetworking) {
            Write-Info "Skipping WSL mirrored networking (-SkipWslNetworking)."
        } else {
            Write-Step "Configure WSL mirrored networking"
            Write-Info "Mirrored mode lets WSL distros reach the host's Ollama via localhost:11434 (no LAN bind)."
            Set-WslMirroredNetworking
        }
    }

    # ── Step: Crush (CLI agent) ──────────────────────────────────────────

    if ($InstallClientTools) {
    Write-Step "Install Crush (CLI agent, formerly OpenCode)"
    Write-Info "Crush is the terminal-based AI agent with MCP support, LSP context, and multi-provider."
    Write-Info "Installed as a winget portable package (no admin required)."

    Install-WinGetPackage -Id "charmbracelet.crush" -Name "Crush" -Critical | Out-Null

    if ($IsClientMode) {
        Write-Info "Client (server-only) mode: Crush defaults to the vLLM server at http://${SquireServerIP}:8000/v1."
        Write-Info "Switch server models with 'copilot-local' or the browser page http://${SquireServerIP}:4090/ ."
        if (-not [string]::IsNullOrWhiteSpace($OllamaHost)) {
            Write-Info "Optional remote Ollama provider available at $OllamaHost."
        }
    }

    # ── Step: csharp-ls (C# language server for Crush's LSP) ─────────────
    Write-Step "Install csharp-ls (C# language server for Crush LSP)"
    Write-Info "crush.json declares a csharp-ls LSP; it is a .NET global tool (not a winget package)."

    # Resolve a dotnet executable. 'dotnet tool install' needs an SDK (not just a runtime).
    $dotnetExe = $null
    $dotnetCmd = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($dotnetCmd) { $dotnetExe = $dotnetCmd.Source }
    elseif (Test-Path "$env:ProgramFiles\dotnet\dotnet.exe") { $dotnetExe = "$env:ProgramFiles\dotnet\dotnet.exe" }

    $hasSdk = $false
    if ($dotnetExe) { $hasSdk = [bool]((& $dotnetExe --list-sdks 2>$null) | Where-Object { $_ -match '^\d' }) }

    if (-not $hasSdk) {
        Write-Info ".NET SDK not found — installing Microsoft.DotNet.SDK.10 (required for csharp-ls)."
        Install-WinGetPackage -Id "Microsoft.DotNet.SDK.10" -Name ".NET SDK 10" | Out-Null
        # winget PATH changes are not live in this session — re-resolve, falling back to the install path.
        $dotnetCmd = Get-Command dotnet -ErrorAction SilentlyContinue
        if ($dotnetCmd) { $dotnetExe = $dotnetCmd.Source }
        elseif (Test-Path "$env:ProgramFiles\dotnet\dotnet.exe") { $dotnetExe = "$env:ProgramFiles\dotnet\dotnet.exe" }
        if ($dotnetExe) { $hasSdk = [bool]((& $dotnetExe --list-sdks 2>$null) | Where-Object { $_ -match '^\d' }) }
    }

    if ($hasSdk) {
        $globalTools = & $dotnetExe tool list --global 2>$null
        if ($globalTools -match '(?im)^\s*csharp-ls\s') {
            Write-Info "csharp-ls already installed — skipping."
        } else {
            Write-Host "  Installing csharp-ls (dotnet global tool)..." -ForegroundColor White
            $csOut = & $dotnetExe tool install --global csharp-ls 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Success "csharp-ls installed."
            } else {
                $csTail = (($csOut | Select-Object -Last 3) -join " | ").Trim()
                Write-Warn "csharp-ls install failed: $csTail"
                $script:Failures += "csharp-ls ($csTail)"
            }
        }

        # Ensure the dotnet global-tools dir is on the user PATH so Crush can launch csharp-ls.
        $csToolsDir = Join-Path $env:USERPROFILE ".dotnet\tools"
        $csUserPath = [Environment]::GetEnvironmentVariable("Path", "User")
        if ($csUserPath -notlike "*$csToolsDir*") {
            [Environment]::SetEnvironmentVariable("Path", "$csUserPath;$csToolsDir", "User")
            Write-Success "Added $csToolsDir to user PATH."
        }
        if ($env:Path -notlike "*$csToolsDir*") { $env:Path = "$env:Path;$csToolsDir" }

        # Verify the tool actually runs (catches a .NET runtime mismatch).
        $csExe = Join-Path $csToolsDir "csharp-ls.exe"
        if (Test-Path $csExe) {
            $csVer = (& $csExe --version 2>&1 | Select-Object -First 1)
            if ($LASTEXITCODE -eq 0) { Write-Info "csharp-ls verified: $csVer" }
            else { Write-Warn "csharp-ls installed but did not run cleanly (may need a specific .NET runtime)." }
        }
    } else {
        Write-Warn "No .NET SDK available — skipping csharp-ls (Crush works without it; C# LSP disabled)."
        $script:Failures += "csharp-ls (no .NET SDK)"
    }

    # ── Step: Warm office authoring libraries (uv cache) ────────────────

    Write-Step "Warm office authoring libraries (uv cache)"
    Write-Info "Office authoring uses the 'office' skill: the model writes python-docx/python-pptx/openpyxl code"
    Write-Info "and runs it via 'uv run --with ...' — no always-on MCP tool schemas. Priming the uv cache now"
    Write-Info "so document authoring works offline afterward."

    $officeLibs = @("python-docx", "python-pptx", "openpyxl")
    try {
        $warmArgs = @("run", "--python", "3.12")
        foreach ($lib in $officeLibs) { $warmArgs += @("--with", $lib) }
        $warmArgs += @("python", "-c", "import docx, pptx, openpyxl")
        $warmOutput = uv @warmArgs 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Office libraries cached ($($officeLibs -join ', '))."
        } else {
            $errTail = (($warmOutput | Select-Object -Last 3) -join " | ").Trim()
            Write-Warn "Office library warm-up failed: $errTail (will resolve on first use)."
            $script:Failures += "Office libs warm-up ($errTail)"
        }
    } catch {
        Write-Warn "Office library warm-up skipped: $_"
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
        if ((Test-Path $crushConfigDest) -and -not $Force) {
            Write-Info "Crush config already exists at $crushConfigDest — skipping (won't overwrite; use -Force to refresh)."
        } else {
            if (Test-Path $crushConfigDest) {
                $crushBak = "$crushConfigDest.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
                Copy-Item $crushConfigDest $crushBak -Force
                Write-Info "-Force: backed up existing crush.json to $crushBak"
            }
            # Expand template placeholders for this platform
            $crushContent = Get-Content $crushConfigSource -Raw
            $expandedLocalAppData = ($AiToolsRoot -replace '\\', '/') # ai-tools root (DataRoot or LocalAppData), fwd slashes for JSON
            $expandedConfigDir = ($CrushDir -replace '\\', '/')
            $crushContent = $crushContent -replace '__LOCALAPPDATA__', $expandedLocalAppData
            $crushContent = $crushContent -replace '__VENV_BIN__', '.venv/Scripts'
            $crushContent = $crushContent -replace '__EXE_SUFFIX__', '.exe'
            $crushContent = $crushContent -replace '__EXE__', '.exe'
            $crushContent = $crushContent -replace '__CONFIG_DIR__', $expandedConfigDir
            $crushContent = $crushContent -replace '__IMAGEGEN_HOST__', '127.0.0.1'
            $crushContent = $crushContent -replace '__SQUIRE_SERVER_IP__', $SquireServerIP

            # Prune crush providers + set the default per -Providers / -DefaultProvider.
            # 'local' -> the localhost Ollama provider ('ollama'); 'server' -> the vLLM server.
            # Cloud providers (mistral/google/groq/openrouter) are always kept.
            try {
                $cfg = $crushContent | ConvertFrom-Json
                $provList = $Providers -split ','
                if ($provList -notcontains 'local' -and $cfg.providers.PSObject.Properties.Name -contains 'ollama') {
                    $cfg.providers.PSObject.Properties.Remove('ollama')
                }
                if ($provList -notcontains 'server' -and $cfg.providers.PSObject.Properties.Name -contains 'server') {
                    $cfg.providers.PSObject.Properties.Remove('server')
                }
                if ($DefaultProvider -eq 'local') {
                    $cfg.default_provider = 'ollama'   # template models.large/small are already the Ollama defaults
                } else {
                    $cfg.default_provider = 'server'
                    $cfg.models.large = [PSCustomObject]@{ model = 'active-model'; provider = 'server'; max_tokens = 8192 }
                    $cfg.models.small = [PSCustomObject]@{ model = 'active-model'; provider = 'server'; max_tokens = 8192 }
                }
                $crushContent = $cfg | ConvertTo-Json -Depth 100
                Write-Info "Crush providers=$Providers, default=$DefaultProvider."
            } catch {
                Add-NonFatalWarning "Could not apply crush provider selection: $($_.Exception.Message)"
            }

            Set-Content -Path $crushConfigDest -Value $crushContent -Encoding UTF8
            Write-Success "Deployed crush.json to $crushConfigDest"
            if ($IsClientMode) {
                Write-Info "server (vLLM, active-model = whatever is loaded) is the default provider. Mistral, Google AI Studio, Groq, and OpenRouter available as fallbacks."
            } else {
                Write-Info "Local Ollama is the default provider. server (vLLM), Mistral, Google AI Studio, Groq, and OpenRouter available as fallbacks."
            }
            Write-Info "Set MISTRAL_API_KEY, GEMINI_API_KEY, GROQ_API_KEY, and/or OPENROUTER_API_KEY to enable cloud providers."
            Write-Info "Office authoring (Word/PowerPoint/Excel) uses the 'office' skill — the model writes python-docx/python-pptx/openpyxl code and runs it via 'uv run'. The imagegen-mcp server is the only MCP enabled."
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

    # Deploy local skills from dotFiles (includes the vendored 'office' authoring skill)
    $skillsSourceDir = Join-Path $PSScriptRoot "..\config\skills"
    $skillsDestDir = Join-Path $CrushDir "skills"
    if (Test-Path $skillsSourceDir) {
        New-Item -ItemType Directory -Path $skillsDestDir -Force | Out-Null
        Copy-Item "$skillsSourceDir\*" $skillsDestDir -Recurse -Force
        Write-Success "Deployed local skills (git-safety, office) to $skillsDestDir"
    }

    # ── Step: Deploy Copilot CLI MCP configuration ────────────────────

    Write-Step "Deploy Copilot CLI MCP configuration"
    $copilotMcpSource = Join-Path $PSScriptRoot "..\config\copilot-mcp-config.json"
    $copilotDir = Join-Path $env:USERPROFILE ".copilot"
    $copilotMcpDest = Join-Path $copilotDir "mcp-config.json"

    if (Test-Path $copilotMcpSource) {
        if (-not (Test-Path $copilotDir)) { New-Item -ItemType Directory -Path $copilotDir -Force | Out-Null }
        if ((Test-Path $copilotMcpDest) -and -not $Force) {
            Write-Info "Copilot MCP config already exists at $copilotMcpDest — skipping (won't overwrite; use -Force to refresh)."
        } else {
            if (Test-Path $copilotMcpDest) {
                $mcpBak = "$copilotMcpDest.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
                Copy-Item $copilotMcpDest $mcpBak -Force
                Write-Info "-Force: backed up existing mcp-config.json to $mcpBak"
            }
            $mcpContent = Get-Content $copilotMcpSource -Raw
            $expandedLocalAppData = ($AiToolsRoot -replace '\\', '/') # ai-tools root (DataRoot or LocalAppData)
            $expandedConfigDir = ($CrushDir -replace '\\', '/')
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
        $imagegenDir = Join-Path $AiToolsDir "imagegen"
        $imagegenVenv = Join-Path $imagegenDir ".venv"
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

        # Make flash-attention optional in the cloned pipeline (idempotent). Upstream
        # pipeline.py hardcodes use_flash_attn=True, which hard-asserts flash_attn is
        # installed (qwen3_vl_transformers.py). flash_attn has no practical Windows build
        # for Blackwell/torch-cu128, so patch the fresh clone to fall back to the standard
        # SDPA attention path. Re-applied on every clone (the patch lives only in the
        # working copy, never upstream). On Linux/CachyOS flash_attn IS installed, so the
        # same conditional simply keeps using flash attention.
        $pipelineFile = "$imagegenRepoDir\models\pipeline.py"
        if (Test-Path $pipelineFile) {
            $pipelineSrc = [System.IO.File]::ReadAllText($pipelineFile)
            if ($pipelineSrc -notmatch '_FLASH_ATTN_AVAILABLE') {
                $detect = @'
# Patched by dotFiles local-llm installer: make flash-attention optional.
# Upstream hardcodes use_flash_attn=True, which hard-asserts flash_attn is installed
# (qwen3_vl_transformers.py). On platforms without flash_attn (e.g. Windows), fall
# back to the standard SDPA attention path instead of crashing.
try:
    from .qwen3_vl_transformers import _flash_attn_func as _FAF
    _FLASH_ATTN_AVAILABLE = _FAF is not None
except Exception:
    _FLASH_ATTN_AVAILABLE = False

TIMESTEP_TOKEN_NUM = 1
'@
                $pipelineSrc = $pipelineSrc -replace '(?m)^TIMESTEP_TOKEN_NUM = 1\r?$', ($detect -replace "`r`n", "`n")
                $pipelineSrc = $pipelineSrc -replace '"use_flash_attn": True,', '"use_flash_attn": _FLASH_ATTN_AVAILABLE,'
                [System.IO.File]::WriteAllText($pipelineFile, $pipelineSrc, (New-Object System.Text.UTF8Encoding $false))
                Write-Info "Patched pipeline.py: flash-attention is now optional (SDPA fallback when flash_attn is absent)."
            } else {
                Write-Info "pipeline.py flash-attention patch already applied."
            }
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

        # Download model weights if not cached (idempotent: skip if the snapshot
        # already exists, so re-runs don't re-verify ~35 GB). Progress is shown
        # (no 2>$null) so a real download doesn't look stalled.
        $hfHubRoot = if ($HFCacheDir) { Join-Path $HFCacheDir "hub" } else { Join-Path $env:USERPROFILE ".cache\huggingface\hub" }
        $hidreamSnapshots = Join-Path $hfHubRoot "models--HiDream-ai--HiDream-O1-Image-Dev\snapshots"
        if ((Test-Path $hidreamSnapshots) -and (Get-ChildItem $hidreamSnapshots -ErrorAction SilentlyContinue | Select-Object -First 1)) {
            Write-Info "HiDream-O1-Image-Dev already cached — skipping download."
        } else {
            Write-Info "Ensuring HiDream-O1-Image-Dev model is cached (35GB, may take a few minutes)..."
            & "$imagegenVenv\Scripts\python.exe" -c "from huggingface_hub import snapshot_download; snapshot_download('HiDream-ai/HiDream-O1-Image-Dev')"
            Write-Info "Model cached."
        }

        # Copy server script and start script to ai-tools directory
        Copy-Item $imagegenScript "$imagegenDir\imagegen-server.py" -Force -ErrorAction SilentlyContinue
        Copy-Item $imagegenStart "$imagegenDir\imagegen-start.cmd" -Force -ErrorAction SilentlyContinue
        Write-Info "Start with: copilot-local (option 7) or imagegen-start.cmd"
        Write-Info "API: POST http://localhost:8001/v1/images/generations"
    }

    # ── Step: Set up imagegen MCP client (fastmcp wrapper) ────────────────

    Write-Step "Set up imagegen MCP client"
    $mcpImagegenDir = Join-Path $AiToolsDir "mcp-imagegen"
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
        # Substitute the Squire Server placeholders so the Remote [S]/[C]/[V]/[I] options work.
        # BOM-free write — a UTF-8 BOM at the top of a .cmd makes cmd.exe choke on the first line.
        $launcherContent = Get-Content $launcherSource -Raw
        $launcherContent = $launcherContent -replace '__SQUIRE_SERVER_IP__', $SquireServerIP
        $launcherContent = $launcherContent -replace '__SQUIRE_SSH_TARGET__', $SquireSSHTarget
        $launcherContent = $launcherContent -replace '__LL_PROVIDERS__', $Providers
        [System.IO.File]::WriteAllText($launcherDest, $launcherContent, (New-Object System.Text.UTF8Encoding($false)))
        Write-Success "Deployed copilot-local.cmd to $launcherDest (server IP $SquireServerIP, ssh $SquireSSHTarget)"

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
        # Substitute the provider gating + Squire Server placeholders so the Remote [S/G/C/D/I]
        # server group works. BOM-free UTF-8 write for consistency with the other launchers.
        $crushContent = Get-Content $crushSource -Raw
        $crushContent = $crushContent -replace '__LL_PROVIDERS__', $Providers
        $crushContent = $crushContent -replace '__SQUIRE_SERVER_IP__', $SquireServerIP
        [System.IO.File]::WriteAllText($crushDest, $crushContent, (New-Object System.Text.UTF8Encoding($false)))
        Write-Success "Deployed crush-task.ps1 to $crushDest (providers $Providers, server IP $SquireServerIP)"
    } else {
        Write-Warn "Crush task script not found at $crushSource — skipping."
    }

    # ── Step: Deploy offload-serve helper ─────────────────────────────────
    # Both copilot-local.cmd (O1/O2 offload profiles) and crush-task.ps1 invoke this helper from
    # their own directory (%~dp0 / $PSScriptRoot = Documents\CLI), so it must be deployed alongside
    # them or the offload profiles fail with a missing-file error.

    Write-Step "Deploy offload-serve helper"
    $offloadSource = Join-Path $PSScriptRoot "..\scripts\offload-serve.ps1"
    $offloadDest = Join-Path $UserProfile "Documents\CLI\offload-serve.ps1"

    if (Test-Path $offloadSource) {
        $cliDir = Split-Path $offloadDest
        if (-not (Test-Path $cliDir)) {
            New-Item -ItemType Directory -Path $cliDir -Force | Out-Null
        }
        Copy-Item -Path $offloadSource -Destination $offloadDest -Force
        Write-Success "Deployed offload-serve.ps1 to $offloadDest"
    } else {
        Write-Warn "Offload helper not found at $offloadSource — skipping."
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
    } # end if ($InstallClientTools)

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
                # Idempotent: skip if the model is already present (avoids re-pulling
                # the full set on every run — pulls only what is actually missing).
                ollama show $tag *> $null
                if ($LASTEXITCODE -eq 0) {
                    Write-Info "$tag already present — skipping pull."
                    continue
                }
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
            # Production base-tag contexts (shared by default + -TestProfiles). These set
            # num_ctx on the raw library base tags; the launcher aliases below re-affirm it.
            # qwen3.6:27b base tag is intentionally absent — the Models map repoints it to the
            # MTP hf.co tag, so the library base is never pulled; its ctx is set on the alias.
            $numCtxSettings = @{
                "qwen3.6:35b"     = 262144
                "gemma4:31b"      = 131072
                "qwen3-coder:30b" = 147456
                "glm-4.7-flash"   = 202752
                "qwen3:8b"        = 32768
            }
            if ($TestProfiles) {
                # Offload bench base num_ctx handled per-alias below.
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
            # Explicit ChatML template for the Qwen3-Next offload alias (its GGUF-embedded template
            # renders to an immediate-EOS empty reply under Ollama 0.30.8 — verified on-box).
            $qwen3nextChatML = @"
{{- range `$i, `$_ := .Messages }}<|im_start|>{{ .Role }}
{{ .Content }}<|im_end|>
{{ end }}<|im_start|>assistant

"@
            # Production launcher aliases (the six daily models in crush.json + the Tier-1
            # menus). Built on EVERY install — default AND -TestProfiles — so a generic
            # install is coherent with crush.json. Coders get lower temp; GLM slightly higher.
            $aliasModels = @{
                # Calibrated on-box 2026-06-27 (5090, q8 KV): this dense Qwen3.6-27B-MTP has heavy KV.
                # 256k=29.24GB (only 2.6GB free); user chose 212k (217088) = ~27.9GB (~3.9GB free on the
                # live 3x4K rig) as the always-on default. Alias suffix matches the real context.
                "qwen36-27b-212k"  = @{ From = "hf.co/unsloth/Qwen3.6-27B-MTP-GGUF:Q4_K_M"; Ctx = 217088; Temp = 0.25 }
                "qwen36-35b-256k"  = @{ From = "qwen3.6:35b";     Ctx = 262144; Temp = 0.25 }
                "gemma4-31b-128k"  = @{ From = "gemma4:31b";      Ctx = 131072 }
                # Calibrated on-box 2026-06-27 (5090, q8 KV): qwen3-coder:30b is 48-layer full-attention
                # (heaviest KV) — 256k=31.39GB spills (~0.1GB free). User chose 144k (147456) = ~28.8GB
                # (~3.1GB free). Alias suffix matches the real context.
                "qwen3coder-144k"  = @{ From = "qwen3-coder:30b"; Ctx = 147456; Temp = 0.25 }
                "glm47-flash-198k" = @{ From = "glm-4.7-flash";   Ctx = 202752; Temp = 0.30 }
            }
            if ($TestProfiles) {
                # -TestProfiles SUPERSET: heavy-coding bench ([H6]-[H8]) + expert-offload bench
                # ([O2]). Native context is larger (North 500k, Nemotron 1M, Ornith 256k) but
                # capped at 256k here for a controlled bench + KV sanity on 32 GB VRAM. North Mini Code
                # is an instruct coder (low temp); Nemotron Cascade 2 and Ornith are reasoning models
                # (<think>) tuned warmer per their cards. Offload aliases set num_gpu 99 (non-expert
                # layers on GPU; the launcher's offload mode sets LLAMA_ARG_N_CPU_MOE to spill experts
                # to RAM). Qwen3-Next needs an explicit ChatML TEMPLATE — its GGUF-embedded template
                # renders to an immediate-EOS empty reply under Ollama's engine (verified on-box).
                $aliasModels["northmini-code-256k"]   = @{ From = "hf.co/unsloth/North-Mini-Code-1.0-GGUF:UD-Q4_K_M"; Ctx = 262144; Temp = 0.25 }
                $aliasModels["nemotron-c2-256k"]      = @{ From = "hf.co/bartowski/nvidia_Nemotron-Cascade-2-30B-A3B-GGUF:Q4_K_M"; Ctx = 262144; Temp = 0.6 }
                $aliasModels["ornith-35b-256k"]       = @{ From = "hf.co/deepreinforce-ai/Ornith-1.0-35B-GGUF:Q4_K_M"; Ctx = 262144; Temp = 0.6 }
                $aliasModels["qwen3next-80b-offload"] = @{ From = "hf.co/Qwen/Qwen3-Next-80B-A3B-Instruct-GGUF:Q4_K_M"; Ctx = 131072; Temp = 0.25; Gpu = 99; Template = $qwen3nextChatML }
            }
            foreach ($entry in $aliasModels.GetEnumerator()) {
                $alias = $entry.Key
                $cfg   = $entry.Value
                $modelfilePath = Join-Path $env:TEMP "Modelfile-$alias"
                $modelfileBody = "FROM $($cfg.From)`nPARAMETER num_ctx $($cfg.Ctx)`n"
                if ($cfg.ContainsKey("Temp")) {
                    $modelfileBody += "PARAMETER temperature $($cfg.Temp)`n"
                }
                if ($cfg.ContainsKey("Gpu")) {
                    $modelfileBody += "PARAMETER num_gpu $($cfg.Gpu)`n"
                }
                if ($cfg.ContainsKey("Template")) {
                    $modelfileBody += "TEMPLATE """"""$($cfg.Template)""""""`n"
                }
                $modelfileBody | Set-Content $modelfilePath
                ollama create $alias -f $modelfilePath 2>$null
                if ($LASTEXITCODE -eq 0) {
                    $tempNote = if ($cfg.ContainsKey("Temp")) { " temp $($cfg.Temp)" } else { "" }
                    $gpuNote  = if ($cfg.ContainsKey("Gpu"))  { " num_gpu $($cfg.Gpu)" } else { "" }
                    Write-Info "  $alias → $($cfg.From) @ num_ctx $($cfg.Ctx)$tempNote$gpuNote"
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
Write-Host "  Model tier:" -ForegroundColor White
Write-Host "    • $ModelTierLabel" -ForegroundColor Gray
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
    Write-Host "    2. Crush defaults to the vLLM server (http://${SquireServerIP}:8000/v1); switch models via copilot-local" -ForegroundColor Yellow
    Write-Host "    3. Test remote inference:  crush" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  See README.md for 'How to Test' and 'How to Get Started' guides." -ForegroundColor Gray
Write-Host ""

if ($script:Failures.Count -gt 0) {
    exit 1
}
