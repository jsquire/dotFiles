# Exercises every canonical Windows launcher row against the shared semantic oracle.
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "lib.ps1")

$cop = Join-Path $PS_REPO "scripts\copilot-local.ps1"
$localRoster = Join-Path $PS_REPO "scripts\local-models.json"
$serverRoster = Join-Path $PS_REPO "cachyos\server-models.json"
$oraclePath = Join-Path $PS_TESTS_DIR "semantic_oracle.py"
$env:ORACLE_EXPECTED = Join-Path $PS_TESTS_DIR "expected-launcher-semantics.json"
$env:LL_TEST_SQUIRE_IP = "10.9.9.9"

$requiredSafety = @(
    '--deny-tool=shell(git add)',
    '--deny-tool=shell(git commit)',
    '--deny-tool=shell(git push)',
    '--deny-tool=shell(git merge)',
    '--deny-tool=shell(git rebase)',
    '--deny-tool=shell(git reset)',
    '--deny-tool=shell(git stash)',
    '--deny-tool=shell(git cherry-pick)',
    '--deny-tool=shell(git revert)',
    '--deny-tool=shell(git tag)'
)

function Assert-Argv($name, $model, $imagegen) {
    $argv = @($script:PS_LAST_OUT -split "`n" |
        Where-Object { $_ -like 'ARGV_ITEM=*' } |
        ForEach-Object { $_ -replace '^ARGV_ITEM=', '' })
    Assert-Eq "$name has no separator" $false ($argv -contains '--')
    $modelIndex = [array]::IndexOf($argv, '--model')
    Assert-Eq "$name model argument" $model $argv[$modelIndex + 1]
    foreach ($flag in $requiredSafety) {
        Assert-Eq "$name safety $flag" $true ($argv -contains $flag)
    }
    $disabled = $false
    for ($i = 0; $i -lt ($argv.Count - 1); $i++) {
        if ($argv[$i] -eq '--disable-mcp-server' -and $argv[$i + 1] -eq 'imagegen-mcp') {
            $disabled = $true
        }
    }
    Assert-Eq "$name imagegen argument" ($imagegen -eq 'off') $disabled
}

function Check-Row($fields) {
    $name, $first, $second, $model, $base, $prompt, $out, $imagegen, $targetHost = $fields
    Invoke-LauncherPs1 -Src $cop -Providers "local,server" -Inputs @($first, $second) -LocalRoster $localRoster
    $capture = ($script:PS_LAST_OUT -split "`n" | Where-Object { $_ -like 'CAPTURE model=*' } | Select-Object -First 1)
    Assert-Eq "$name semantics" "CAPTURE model=$model base=$base prompt=$prompt out=$out imagegen=$imagegen office=no" $capture
    $hostLine = ($script:PS_LAST_OUT -split "`n" | Where-Object { $_ -like 'IMAGEGEN_HOST=*' } | Select-Object -First 1)
    Assert-Eq "$name image host" $targetHost ($hostLine -replace '^IMAGEGEN_HOST=', '')
    Assert-Argv $name $model $imagegen
}

$env:ORACLE_KIND = "local"
$env:ORACLE_PLATFORM = "windows"
$localRows = Invoke-PyFile $oraclePath (Get-Content $localRoster -Raw)
foreach ($line in @($localRows)) {
    if ($line) { Check-Row ($line -split "`t") }
}

$env:ORACLE_KIND = "server"
$env:ORACLE_SERVER_IP = "10.9.9.9"
$serverRows = Invoke-PyFile $oraclePath (Get-Content $serverRoster -Raw)
foreach ($line in @($serverRows)) {
    if ($line) { Check-Row ($line -split "`t") }
}

Invoke-LauncherPs1 -Src $cop -Providers "local,server" -Inputs @() -ModelArg "qwen3:8b" -LocalRoster $localRoster
$direct = ($script:PS_LAST_OUT -split "`n" | Where-Object { $_ -like 'CAPTURE model=*' } | Select-Object -First 1)
Assert-Eq "direct semantics" `
    "CAPTURE model=qwen3:8b base=http://localhost:11435/v1 prompt=24576 out=8192 imagegen=off office=no" `
    $direct
Assert-Argv "direct" "qwen3:8b" "off"

if (PS-Summary "launcher-semantics-ps") { exit 0 } else { exit 1 }
