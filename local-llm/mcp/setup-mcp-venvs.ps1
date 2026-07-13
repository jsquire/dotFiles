# Office authoring library warm-up — Windows
#
# Office authoring no longer uses always-on MCP servers (their tool schemas cost
# ~37K tokens per request, exceeding most served context windows). Instead, the
# vendored 'office' skill instructs the model to write python-docx / python-pptx /
# openpyxl code and run it via 'uv run --with ...'.
#
# This script primes the uv cache so document authoring works offline afterward.
# Run AFTER install-windows.ps1 has installed uv and Python.
#
# Usage:
#   .\setup-mcp-venvs.ps1

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$OfficeLibs = @("python-docx", "python-pptx", "openpyxl")

Write-Host "`n── Warming office authoring libraries ($($OfficeLibs -join ', ')) ──" -ForegroundColor Cyan

$warmArgs = @("run", "--python", "3.12")
foreach ($lib in $OfficeLibs) { $warmArgs += @("--with", $lib) }
$warmArgs += @("python", "-c", "import docx, pptx, openpyxl")

& uv @warmArgs

if ($LASTEXITCODE -eq 0) {
    Write-Host "  ✓ Office libraries cached" -ForegroundColor Green
} else {
    Write-Host "  ✗ Warm-up failed — libraries will resolve on first use via 'uv run --with ...'" -ForegroundColor Red
}

Write-Host "`n── Done ──" -ForegroundColor Cyan
Write-Host "Office authoring runs via the 'office' skill: 'uv run --with python-docx --with python-pptx --with openpyxl script.py'."
