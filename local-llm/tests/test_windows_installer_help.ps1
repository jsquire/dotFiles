. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "lib.ps1")

$installer = Join-Path $PS_REPO "windows\install-windows.ps1"

function Invoke-InstallerHelp([string]$argument) {
    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $installer $argument 2>&1 | Out-String
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = $output
    }
}

foreach ($argument in @("-Help", "-h", "--help")) {
    $result = Invoke-InstallerHelp $argument
    Assert-Eq "$argument exits successfully" 0 $result.ExitCode
    Assert-Eq "$argument prints usage" $true ($result.Output -like "*LOCAL LLM INSTALLER*USAGE:*")
    Assert-Eq "$argument performs no install step" $false ($result.Output -like "*Step 1:*")
}

if (PS-Summary "windows-installer-help") { exit 0 } else { exit 1 }
