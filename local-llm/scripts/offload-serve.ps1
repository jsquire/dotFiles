<#
.SYNOPSIS
    Swap the managed Ollama server for one with MoE expert CPU-offload enabled (and back).

.DESCRIPTION
    Expert CPU offload (llama.cpp's --cpu-moe / LLAMA_ARG_CPU_MOE) pushes a MoE model's
    expert FFN weights to system RAM while attention/shared tensors + KV cache stay on the
    GPU. This lets the box run models that do NOT fit fully in VRAM (e.g. Qwen3-Next-80B),
    and frees VRAM for larger context, at a generation-speed cost.

    The env var is GLOBAL to an `ollama serve` process, so it must NOT be set on the
    everyday managed server (it would slow down models that already fit). This script
    stops the managed Ollama desktop server, starts a dedicated `ollama serve` with the
    offload env vars set, and on -Action stop restores the normal managed server.

    Verified on RTX 4090 + DDR5-4800, Ollama 0.30.7: Ollama's bundled runner is upstream
    llama-server, which honors LLAMA_ARG_CPU_MOE inherited from the serve environment.
    Measured (qwen3-coder:30b, 32K ctx): model VRAM 20GB -> 2.8GB; eval 190 -> 25 tok/s.
    Only use offload for models that don't fit fully in VRAM.

.PARAMETER Action
    start — stop the managed server, launch the offload serve, wait until the API is ready.
    stop  — stop the offload serve, relaunch the managed Ollama desktop app.

.PARAMETER NCpuMoe
    0 (default) = offload ALL experts to CPU (LLAMA_ARG_CPU_MOE=1).
    >0          = offload only the first N layers' experts (LLAMA_ARG_N_CPU_MOE=N), the
                  partial-offload tuning knob to claw back speed once a model almost fits.

.PARAMETER RequiredFreeGB
    Minimum free physical RAM (GB) required before an offload serve will start. The experts
    that spill to RAM must fit alongside everything already in use; on a 64 GB box with an IDE
    open, full offload (~45-55 GB) does not fit and would thrash swap. Guards against that.
    Default 15 (sized for [O2] partial offload ~13 GB spill). Use -Force to override.

.PARAMETER Force
    Skip the RAM-headroom guard and start the offload serve regardless of free RAM.
#>
param(
    [Parameter(Mandatory)][ValidateSet("start", "stop")]
    [string]$Action,
    [int]$NCpuMoe = 0,
    [int]$RequiredFreeGB = 15,
    [switch]$Force
)

$ErrorActionPreference = "SilentlyContinue"

$OllamaDir = Join-Path $env:LOCALAPPDATA "Programs\Ollama"
$OllamaApp = Join-Path $OllamaDir "ollama app.exe"
$OllamaExe = Join-Path $OllamaDir "ollama.exe"
$ApiBase   = "http://127.0.0.1:11434"

function Stop-OllamaProcesses {
    # Kill the app, the serve process, AND the llama-server runner child — killing only the
    # parent leaves the runner orphaned, holding VRAM. Names: "ollama app", "ollama",
    # "llama-server" (the bundled upstream runner that actually loads the model).
    foreach ($p in Get-Process 'ollama app', 'ollama', 'llama-server' -ErrorAction SilentlyContinue) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2
}

function Wait-OllamaApi {
    param([int]$Seconds = 30)
    for ($i = 0; $i -lt $Seconds; $i++) {
        try {
            Invoke-RestMethod -Uri "$ApiBase/api/version" -TimeoutSec 2 -ErrorAction Stop | Out-Null
            return $true
        } catch { Start-Sleep -Seconds 1 }
    }
    return $false
}

function Resolve-OllamaModelsEnv {
    # The bare `ollama serve` (NOT the tray app) finds its model store via the OLLAMA_MODELS
    # environment variable; the tray app's GUI "Model location" setting does NOT propagate to a
    # non-tray serve. If the ambient env doesn't already carry OLLAMA_MODELS (e.g. this script was
    # launched from a process that started before the var was persisted), resolve it from the
    # persisted User (then Machine) value so the offload/restored serve serves the same models as
    # the managed server. (Caveat: if the model location was set ONLY via the tray GUI and never as
    # an env var, there is no env-accessible source and Ollama's default path is used.)
    if (-not $env:OLLAMA_MODELS) {
        $persisted = [Environment]::GetEnvironmentVariable('OLLAMA_MODELS', 'User')
        if (-not $persisted) { $persisted = [Environment]::GetEnvironmentVariable('OLLAMA_MODELS', 'Machine') }
        if ($persisted) {
            $env:OLLAMA_MODELS = $persisted
            Write-Host "  [offload] Resolved OLLAMA_MODELS from persisted env: $persisted" -ForegroundColor DarkGray
        }
    }
}

if ($Action -eq "start") {
    # RAM-headroom guard: the experts spill to system RAM; if there isn't enough free, the
    # offload serve thrashes the pagefile. Abort early with a clear message instead. (-Force skips.)
    if (-not $Force) {
        $os = Get-CimInstance Win32_OperatingSystem
        $freeGB = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
        if ($freeGB -lt $RequiredFreeGB) {
            Write-Host "  [offload] ABORT: only $freeGB GB RAM free; need >= $RequiredFreeGB GB for offload." -ForegroundColor Red
            Write-Host "  [offload] Close heavy apps (IDE/browser) and retry, or pass -Force to override." -ForegroundColor Red
            exit 1
        }
        Write-Host "  [offload] RAM check OK: $freeGB GB free (>= $RequiredFreeGB GB)." -ForegroundColor DarkGray
    }

    Write-Host "  [offload] Stopping managed Ollama server..." -ForegroundColor DarkYellow
    Stop-OllamaProcesses

    # Standard Ollama tuning carried over from the managed server.
    $env:OLLAMA_HOST            = "127.0.0.1"
    $env:OLLAMA_FLASH_ATTENTION = "1"
    $env:OLLAMA_KV_CACHE_TYPE   = "q8_0"
    $env:OLLAMA_KEEP_ALIVE      = "5m"
    # Ensure the dedicated offload serve finds the model store (see Resolve-OllamaModelsEnv).
    Resolve-OllamaModelsEnv
    # Required for offload: avoid CUDA trying to pin the large CPU-resident expert tensors.
    $env:GGML_CUDA_NO_PINNED    = "1"

    if ($NCpuMoe -gt 0) {
        $env:LLAMA_ARG_N_CPU_MOE = "$NCpuMoe"
        Remove-Item Env:LLAMA_ARG_CPU_MOE -ErrorAction SilentlyContinue
        Write-Host "  [offload] Partial offload: first $NCpuMoe layers' experts -> CPU RAM" -ForegroundColor DarkYellow
    } else {
        $env:LLAMA_ARG_CPU_MOE = "1"
        Remove-Item Env:LLAMA_ARG_N_CPU_MOE -ErrorAction SilentlyContinue
        Write-Host "  [offload] Full offload: all experts -> CPU RAM" -ForegroundColor DarkYellow
    }

    # Start-Process inherits this session's environment (incl. the LLAMA_ARG_* vars) and
    # survives this script exiting, so the offload serve keeps running for the launcher.
    Start-Process -FilePath $OllamaExe -ArgumentList "serve" -WindowStyle Hidden

    if (Wait-OllamaApi -Seconds 30) {
        Write-Host "  [offload] Offload server ready (LLAMA_ARG_CPU_MOE active)." -ForegroundColor Green
    } else {
        Write-Host "  [offload] WARNING: offload server did not become ready in time." -ForegroundColor Red
    }
}
elseif ($Action -eq "stop") {
    Write-Host "  [offload] Stopping offload server, restoring managed Ollama..." -ForegroundColor DarkYellow
    Stop-OllamaProcesses

    # Clear the offload-only env so the restored serve runs as the normal (fully-on-GPU) server.
    Remove-Item Env:LLAMA_ARG_CPU_MOE   -ErrorAction SilentlyContinue
    Remove-Item Env:LLAMA_ARG_N_CPU_MOE -ErrorAction SilentlyContinue
    Remove-Item Env:GGML_CUDA_NO_PINNED -ErrorAction SilentlyContinue

    # Restore the standard managed tuning + model store for whichever serve comes up next.
    $env:OLLAMA_HOST            = "127.0.0.1"
    $env:OLLAMA_FLASH_ATTENTION = "1"
    $env:OLLAMA_KV_CACHE_TYPE   = "q8_0"
    $env:OLLAMA_KEEP_ALIVE      = "5m"
    Resolve-OllamaModelsEnv

    # Prefer the desktop app (it owns the tray/GUI), but it does NOT reliably re-spawn the serve
    # subprocess when launched this way, which can leave Ollama down after an offload session. So
    # verify the API actually comes up and fall back to starting `ollama serve` directly.
    if (Test-Path $OllamaApp) { Start-Process -FilePath $OllamaApp }
    if (Wait-OllamaApi -Seconds 20) {
        Write-Host "  [offload] Managed Ollama restarted." -ForegroundColor Green
    } else {
        Write-Host "  [offload] Tray did not bring up the serve; starting 'ollama serve' directly..." -ForegroundColor DarkYellow
        Start-Process -FilePath $OllamaExe -ArgumentList "serve" -WindowStyle Hidden
        if (Wait-OllamaApi -Seconds 20) {
            Write-Host "  [offload] Managed Ollama restored (direct serve)." -ForegroundColor Green
        } else {
            Write-Host "  [offload] WARNING: Ollama did not come back up; start it manually." -ForegroundColor Red
        }
    }
}
