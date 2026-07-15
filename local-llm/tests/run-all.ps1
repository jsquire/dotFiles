# Orchestrator for the PowerShell-side suites: JSON parses under ConvertFrom-Json + launcher parity.
$dir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent $dir
$fail = 0

Write-Host "########## schema (PowerShell ConvertFrom-Json) ##########"
foreach ($f in @("$repo\scripts\local-models.json", "$repo\cachyos\server-models.json")) {
    try {
        Get-Content $f -Raw | ConvertFrom-Json | Out-Null
        Write-Host "  OK: $(Split-Path $f -Leaf) parses under ConvertFrom-Json"
    } catch {
        Write-Host "  FAIL: $f -> $($_.Exception.Message)"; $fail = 1
    }
}
Write-Host ""

Write-Host "########## test_launchers_parity.ps1 ##########"
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir "test_launchers_parity.ps1")
if ($LASTEXITCODE -ne 0) { $fail = 1 }

Write-Host ""
if ($fail -eq 0) { Write-Host "==== ALL POWERSHELL SUITES PASSED ===="; exit 0 }
else { Write-Host "==== POWERSHELL SUITE FAILURES ===="; exit 1 }
