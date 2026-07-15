# Verifies the imagegen MCP target follows the local/server selection (PowerShell launchers).
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "lib.ps1")
$env:LL_TEST_SQUIRE_IP = "10.9.9.9"

$cop = Join-Path $PS_REPO "scripts\copilot-local.ps1"
$cru = Join-Path $PS_REPO "scripts\crush-task.ps1"

function Crush-Url($inputs) {
    Invoke-LauncherPs1 -Src $cru -Providers "local,server" -Inputs $inputs
    if ($script:PS_CRUSH) { (Get-Content $script:PS_CRUSH -Raw | ConvertFrom-Json).mcp.'imagegen-mcp'.env.IMAGEGEN_URL } else { "NONE" }
}
function Copilot-Host($inputs) {
    Invoke-LauncherPs1 -Src $cop -Providers "local,server" -Inputs $inputs
    $line = ($script:PS_LAST_OUT -split "`n" | Where-Object { $_ -like 'IMAGEGEN_HOST=*' } | Select-Object -First 1)
    if ($line) { ($line -split '=', 2)[1] } else { "" }
}
function Copilot-Sep($inputs) {
    Invoke-LauncherPs1 -Src $cop -Providers "local,server" -Inputs $inputs
    $line = ($script:PS_LAST_OUT -split "`n" | Where-Object { $_ -like 'ARGV_HAS_SEP=*' } | Select-Object -First 1)
    if ($line) { ($line -split '=', 2)[1] } else { "" }
}

Assert-Eq "crush local image url"   "http://127.0.0.1:8001" (Crush-Url @("1", "5"))
Assert-Eq "crush server image url"  "http://10.9.9.9:8001"  (Crush-Url @("3", "5"))
Assert-Eq "crush local coding url"  "http://127.0.0.1:8001" (Crush-Url @("1", "1"))
Assert-Eq "crush server coding url" "http://10.9.9.9:8001"  (Crush-Url @("3", "1"))
Assert-Eq "copilot local image host"  "127.0.0.1" (Copilot-Host @("1", "7"))
Assert-Eq "copilot server image host" "10.9.9.9"  (Copilot-Host @("3", "5"))
Assert-Eq "copilot local no -- separator"  "no" (Copilot-Sep @("1", "1"))
Assert-Eq "copilot server no -- separator" "no" (Copilot-Sep @("3", "1"))

if (PS-Summary "imagegen-context-ps") { exit 0 } else { exit 1 }
