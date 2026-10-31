# Orchestrator for the PowerShell suites with recursive protected-root isolation validation.
$dir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent $dir
$fail = 0

function Get-ProtectedSnapshot {
    $roots = @(
        (Join-Path $env:USERPROFILE ".config\local-llm"),
        (Join-Path $env:USERPROFILE ".copilot\mcp-config.json"),
        (Join-Path $env:USERPROFILE ".copilot\skills\office")
    )
    $rows = foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) {
            [pscustomobject]@{ path = $root; type = "missing"; size = 0; sha256 = "" }
            continue
        }
        $items = @((Get-Item -LiteralPath $root -Force))
        if ((Get-Item -LiteralPath $root -Force).PSIsContainer) {
            $items += @(Get-ChildItem -LiteralPath $root -Recurse -Force)
        }
        foreach ($item in $items) {
            $type = if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                "link"
            } elseif ($item.PSIsContainer) {
                "directory"
            } else {
                "file"
            }
            $hash = if ($type -eq "file") {
                (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
            } elseif ($type -eq "link") {
                $bytes = [Text.Encoding]::UTF8.GetBytes([string]$item.Target)
                $sha = [Security.Cryptography.SHA256]::Create()
                ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "")
            } else {
                ""
            }
            [pscustomobject]@{
                path = $item.FullName
                type = $type
                size = if ($item.PSIsContainer) { 0 } else { $item.Length }
                sha256 = $hash
            }
        }
    }
    @($rows | Sort-Object path) | ConvertTo-Json -Compress -Depth 4
}

$before = Get-ProtectedSnapshot

Write-Host "########## schema (PowerShell ConvertFrom-Json) ##########"
foreach ($f in @("$repo\scripts\local-models.json", "$repo\cachyos\server-models.json")) {
    try {
        Get-Content $f -Raw | ConvertFrom-Json | Out-Null
        Write-Host "  OK: $(Split-Path $f -Leaf) parses under ConvertFrom-Json"
    } catch {
        Write-Host "  FAIL: $f -> $($_.Exception.Message)"; $fail = 1
    }
}

foreach ($suite in @(
    "test_launchers_parity.ps1",
    "test_launcher_switch.ps1",
    "test_imagegen_context.ps1",
    "test_token_budgets.ps1",
    "test_windows_remove_symmetry.ps1",
    "run-python-tests.ps1"
)) {
    Write-Host ""
    Write-Host "########## $suite ##########"
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir $suite)
    if ($LASTEXITCODE -ne 0) { $fail = 1 }
}

$after = Get-ProtectedSnapshot
if ($before -cne $after) {
    Write-Host ""
    Write-Host "!! ISOLATION VIOLATION: a protected configuration root changed during the run"
    $fail = 1
} else {
    Write-Host ""
    Write-Host "isolation OK: protected configuration roots unchanged"
}

Write-Host ""
if ($fail -eq 0) { Write-Host "==== ALL POWERSHELL SUITES PASSED ===="; exit 0 }
Write-Host "==== POWERSHELL SUITE FAILURES ===="
exit 1
