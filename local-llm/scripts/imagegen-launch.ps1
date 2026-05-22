# imagegen-launch.ps1 — Start imagegen server, wait for ready, launch Copilot, cleanup on exit
param(
    [string]$Model = "gemma4-65k",
    [int]$Port = 8001
)

$env:COPILOT_PROVIDER_BASE_URL = "http://localhost:11434/v1"
$env:COPILOT_PROVIDER_MAX_PROMPT_TOKENS = "14000"
$env:COPILOT_PROVIDER_MAX_OUTPUT_TOKENS = "8000"
$env:COPILOT_MODEL = $Model

$py     = "$env:LOCALAPPDATA\ai-tools\imagegen\.venv\Scripts\python.exe"
$script = "$env:LOCALAPPDATA\ai-tools\imagegen\imagegen-server.py"

if (-not (Test-Path $py)) {
    Write-Host "  ERROR: Python venv not found at $py"
    Write-Host "  Run install-windows.ps1 first."
    exit 1
}

$psi = [System.Diagnostics.ProcessStartInfo]::new($py)
$psi.Arguments = "`"$script`" --port $Port"
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true

$srv = [System.Diagnostics.Process]::new()
$srv.StartInfo = $psi
$srv.Start() | Out-Null

Write-Host "  ImageGen server PID: $($srv.Id)"
Write-Host "  Waiting for model to load..."

$ready = $false
while (-not $ready -and -not $srv.HasExited) {
    $line = $srv.StandardError.ReadLine()
    if ($line) {
        if ($line -match 'Model loaded') {
            Write-Host "  $line"
            $ready = $true
        } elseif ($line -match 'Loading|Fetching|checkpoint') {
            Write-Host "  $line"
        }
    }
}

if (-not $ready) {
    Write-Host "  ERROR: Server failed to start."
    if (-not $srv.HasExited) { Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue }
    exit 1
}

Write-Host ""
Write-Host "  Image server ready. Starting Copilot..."
Write-Host "  API: http://localhost:${Port}/v1/images/generations"
Write-Host "  Using model: $Model"
Write-Host ""

try {
    $c = Start-Process -FilePath "copilot" -NoNewWindow -PassThru -Wait
} finally {
    if (-not $srv.HasExited) {
        Write-Host "  Stopping image generation server..."
        Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue
    }
}
