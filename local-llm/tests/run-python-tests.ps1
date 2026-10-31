# Runs the Python suites in an isolated uv environment.
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$uv = Get-Command uv -ErrorAction SilentlyContinue
if (-not $uv) {
    Write-Host "ERROR: uv is required for Python tests."
    exit 1
}
& $uv.Source run --no-project `
    --with fastmcp `
    --with httpx `
    --with fastapi `
    --with pillow `
    --with python-multipart `
    python -m unittest discover -s $dir -p "test_*image*.py"
exit $LASTEXITCODE
