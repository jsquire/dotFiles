# Proves the PowerShell launcher sends the correct switch request and handles success, failure, and timeout.
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "lib.ps1")

$cop = Join-Path $PS_REPO "scripts\copilot-local.ps1"
$env:LL_TEST_SQUIRE_IP = "10.9.9.9"
$log = Join-Path $env:TEMP ("switch_" + [guid]::NewGuid().ToString("N") + ".log")

function Run-SwitchCase($mode) {
    Remove-Item $log -ErrorAction SilentlyContinue
    Invoke-LauncherPs1 -Src $cop -Providers "local,server" -Inputs @("3", "1") `
        -SwitchMode $mode -SwitchLog $log
}

Run-SwitchCase "success"
$logged = Get-Content $log -Raw
Assert-Eq "success switch URL" $true ($logged -like "*SWITCH_URL=http://10.9.9.9:4090/switch*")
Assert-Eq "success switch body" $true ($logged -like '*SWITCH_BODY={"mode":"mistral"}*')
Assert-Eq "success polls status" $true ($logged -like "*STATUS_URL=http://10.9.9.9:4090/status*")
Assert-Eq "success reports ready" $true ($script:PS_LAST_OUT -like "*ready.*")

Run-SwitchCase "failure"
$logged = Get-Content $log -Raw
Assert-Eq "failure reports unreachable" $true ($script:PS_LAST_OUT -like "*could not reach the model-switch service*")
Assert-Eq "failure does not poll" $false ($logged -like "*STATUS_URL=*")

Run-SwitchCase "timeout"
$logged = Get-Content $log
Assert-Eq "timeout performs bounded polls" 2 @($logged | Where-Object { $_ -like "STATUS_URL=*" }).Count
Assert-Eq "timeout reports loading" $true ($script:PS_LAST_OUT -like "*still loading*")

Remove-Item $log -ErrorAction SilentlyContinue
if (PS-Summary "launcher-switch-ps") { exit 0 } else { exit 1 }
