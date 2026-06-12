<#
.SYNOPSIS
    Swap the managed Ollama server for one with MoE expert CPU-offload enabled (and back).

.DESCRIPTION
    Expert CPU offload (llama.cpp's --cpu-moe / LLAMA_ARG_CPU_MOE) pushes a MoE model's
    expert FFN weights to system RAM while attention/shared tensors + KV cache stay on the
    GPU. This lets the box run models that do NOT fit fully in VRAM (e.g. gpt-oss-120b),
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
#>
param(
    [Parameter(Mandatory)][ValidateSet("start", "stop")]
    [string]$Action,
    [int]$NCpuMoe = 0
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

if ($Action -eq "start") {
    Write-Host "  [offload] Stopping managed Ollama server..." -ForegroundColor DarkYellow
    Stop-OllamaProcesses

    # Standard Ollama tuning carried over from the managed server.
    $env:OLLAMA_HOST            = "127.0.0.1"
    $env:OLLAMA_FLASH_ATTENTION = "1"
    $env:OLLAMA_KV_CACHE_TYPE   = "q8_0"
    $env:OLLAMA_KEEP_ALIVE      = "5m"
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
    if (Test-Path $OllamaApp) {
        Start-Process -FilePath $OllamaApp
    } else {
        Start-Process -FilePath $OllamaExe -ArgumentList "serve" -WindowStyle Hidden
    }
    Write-Host "  [offload] Managed Ollama restarted." -ForegroundColor Green
}
