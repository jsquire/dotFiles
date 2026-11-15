# Verifies the imagegen MCP target follows the local/server selection (PowerShell launchers).
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "lib.ps1")
$env:LL_TEST_SQUIRE_IP = "10.9.9.9"

$cop = Join-Path $PS_REPO "scripts\copilot-local.ps1"

$roster = Join-Path $PS_REPO "scripts\local-models.json"
Invoke-LauncherPs1 -Src $cop -Providers "local,server" -Inputs @("2", "11") -LocalRoster $roster
Assert-Eq "copilot experimental model" $true ($script:PS_LAST_OUT -like "*CAPTURE model=qwen3:8b*imagegen=on*")
Assert-Eq "copilot experimental port" $true ($script:PS_LAST_OUT -like "*IMAGEGEN_PORT=8002*")
Assert-Eq "copilot experimental backend" $true ($script:PS_LAST_OUT -like "*IMAGEGEN_BACKEND=qwen-image-2.1-turbo*")
Invoke-LauncherPs1 -Src $cop -Providers "local,server" -Inputs @("1", "7") -LocalRoster $roster
Assert-Eq "copilot production port" $true ($script:PS_LAST_OUT -like "*IMAGEGEN_PORT=8001*")
Assert-Eq "copilot production backend" $true ($script:PS_LAST_OUT -like "*IMAGEGEN_BACKEND=hidream-o1*")
Invoke-LauncherPs1 -Src $cop -Providers "local,server" -Inputs @("3", "5") -LocalRoster $roster
Assert-Eq "copilot server port" $true ($script:PS_LAST_OUT -like "*IMAGEGEN_PORT=8001*")
if (PS-Summary "imagegen-context-ps") { exit 0 } else { exit 1 }
