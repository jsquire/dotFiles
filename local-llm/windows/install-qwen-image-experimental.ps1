#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AiToolsDir,
    [Parameter(Mandatory)][string]$HFCacheDir
)

$ErrorActionPreference = "Stop"
$target = Join-Path $AiToolsDir "imagegen-qwen"
$venv = Join-Path $target ".venv"
$python = Join-Path $venv "Scripts\python.exe"
$revision = "d65dbc9a7e8f6b5479e33dee6030eaab2a906509"
$model = Join-Path $HFCacheDir "hub\models--Qwen--Qwen-Image-2.1-Turbo\snapshots\$revision"
New-Item -ItemType Directory -Path $target, $HFCacheDir -Force | Out-Null
if (-not (Test-Path $python)) {
    & uv venv $venv --python 3.12 --quiet
    if ($LASTEXITCODE -ne 0) { throw "Failed to create Qwen image venv" }
}
& uv pip install --python $python "torch==2.11.0" "torchvision==0.26.0" --index-url https://download.pytorch.org/whl/cu128 --quiet
if ($LASTEXITCODE -ne 0) { throw "Failed to install CUDA PyTorch for Qwen Image" }
& uv pip install --python $python "transformers==5.17.0" accelerate fastapi uvicorn python-multipart pillow `
    "https://github.com/huggingface/diffusers/archive/4295ee3ec58efa6577bc459e9b84ca3f63aa9a96.zip" --quiet
if ($LASTEXITCODE -ne 0) { throw "Failed to install Qwen Image pipeline dependencies" }
$env:HF_HOME = $HFCacheDir
if (-not (Test-Path (Join-Path $model "model_index.json"))) {
    & $python -c "from huggingface_hub import snapshot_download; snapshot_download('Qwen/Qwen-Image-2.1-Turbo', revision='$revision')"
    if ($LASTEXITCODE -ne 0) { throw "Failed to download Qwen-Image-2.1-Turbo" }
}
Copy-Item (Join-Path $PSScriptRoot "qwen-imagegen-server.py") (Join-Path $target "qwen-imagegen-server.py") -Force
Write-Host "Qwen Image Turbo experimental backend installed at $target (localhost:8002, on demand)"
