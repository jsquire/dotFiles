# PowerShell launcher parity: current .ps1 launchers vs a frozen PS-specific golden generated from the
# PRE-REFACTOR PowerShell baseline (git cf852ee^). Proves the data-drive refactor changed no functional
# resolution on Windows. (bash and PowerShell have two documented pre-existing behavioural differences —
# the office-skill file guard and the direct-model MCP handling — so each platform has its own golden.)
#
#   test_launchers_parity.ps1                 # check current vs frozen golden
#   test_launchers_parity.ps1 -RebuildGolden  # regenerate golden from the baseline
param([switch]$RebuildGolden, [string]$BaselineRef = "cf852ee^")

. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "lib.ps1")

$GIT_ROOT = Split-Path -Parent $PS_REPO
$goldenC = Join-Path $PS_FIX "golden-copilot-ps.tsv"
$goldenK = Join-Path $PS_FIX "golden-crush-ps.tsv"

function Copilot-Tuple($src, $providers, $inputs, $modelArg) {
    Invoke-LauncherPs1 -Src $src -Providers $providers -Inputs $inputs -ModelArg $modelArg
    $cap = ($script:PS_LAST_OUT -split "`n" | Where-Object { $_ -like 'CAPTURE model=*' } | Select-Object -First 1)
    $cap = $cap -replace '^CAPTURE ', ''
    "$cap"
}
function Crush-Tuple($src, $providers, $inputs, $taskArg) {
    Invoke-LauncherPs1 -Src $src -Providers $providers -Inputs $inputs -TaskArg $taskArg
    $js = if ($script:PS_CRUSH) { Norm-CrushJson $script:PS_CRUSH } else { "NONE" }
    "json=$js"
}
function Golden-Lookup($file, $name) {
    $line = Get-Content $file | Where-Object { $_ -like ($name + "`t*") } | Select-Object -First 1
    if ($line) { ($line -split "`t", 2)[1] } else { "<no-golden:$name>" }
}

$script:GoldRows = @()
function Do-Copilot($mode, $name, $src, $prov, $inputs, $modelArg) {
    $t = Copilot-Tuple $src $prov $inputs $modelArg
    if ($mode -eq 'golden') { $script:GoldRows += ("$name`t$t") }
    else { Assert-Eq "copilot/$name" (Golden-Lookup $goldenC $name) $t }
}
function Do-Crush($mode, $name, $src, $prov, $inputs, $taskArg) {
    $t = Crush-Tuple $src $prov $inputs $taskArg
    if ($mode -eq 'golden') { $script:GoldRows += ("$name`t$t") }
    else { Assert-Eq "crush/$name" (Golden-Lookup $goldenK $name) $t }
}
function Run-CopilotMatrix($mode, $src) {
    $script:GoldRows = @()
    foreach ($k in 1..7)  { Do-Copilot $mode "cl-$k" $src "local,server" @("1", "$k") "" }
    foreach ($k in 1..9)  { Do-Copilot $mode "ce-$k" $src "local,server" @("2", "$k") "" }
    foreach ($k in 1..5)  { Do-Copilot $mode "cs-$k" $src "local,server" @("3", "$k") "" }
    Do-Copilot $mode "cdirect" $src "local,server" @() "qwen3:8b"
    if ($mode -eq 'golden') { Set-Content $goldenC ($script:GoldRows -join "`n") -Encoding ASCII }
}
function Run-CrushMatrix($mode, $src) {
    $script:GoldRows = @()
    foreach ($k in 1..5)  { Do-Crush $mode "kl-$k" $src "local,server" @("1", "$k") "" }
    foreach ($k in 1..9)  { Do-Crush $mode "ke-$k" $src "local,server" @("2", "$k") "" }
    foreach ($k in 1..5)  { Do-Crush $mode "ks-$k" $src "local,server" @("3", "$k") "" }
    foreach ($t in 'coding', 'review', 'docs', 'image') { Do-Crush $mode "karg-$t" $src "local,server" @() $t }
    if ($mode -eq 'golden') { Set-Content $goldenK ($script:GoldRows -join "`n") -Encoding ASCII }
}
function Extract-Baseline($name) {
    $tmp = Join-Path $env:TEMP ("bl_" + [guid]::NewGuid().ToString("N").Substring(0, 8) + ".ps1")
    # Use cmd redirection (byte-preserving) so git's UTF-8 output isn't re-encoded to UTF-16 by PS `>`.
    $cmd = "git -C `"$GIT_ROOT`" show `"${BaselineRef}:local-llm/scripts/$name`" > `"$tmp`""
    cmd /c $cmd 2>$null | Out-Null
    if ((Test-Path $tmp) -and (Get-Item $tmp).Length -gt 0) { $tmp } else { "" }
}

if ($RebuildGolden) {
    Write-Host "Rebuilding PowerShell golden from baseline: $BaselineRef"
    $cop = Extract-Baseline "copilot-local.ps1"
    $cru = Extract-Baseline "crush-task.ps1"
    if (-not $cop -or -not $cru) { Write-Host "ERROR: could not extract PS baseline at $BaselineRef"; exit 1 }
    Run-CopilotMatrix 'golden' $cop
    Run-CrushMatrix   'golden' $cru
    Remove-Item $cop, $cru -ErrorAction SilentlyContinue
    Write-Host "Golden written: $((Get-Content $goldenC).Count) copilot + $((Get-Content $goldenK).Count) crush selections."
    exit 0
}

if (-not (Test-Path $goldenC) -or -not (Test-Path $goldenK)) {
    Write-Host "  golden missing - run: test_launchers_parity.ps1 -RebuildGolden"; exit 1
}
Run-CopilotMatrix 'check' (Join-Path $PS_REPO "scripts\copilot-local.ps1")
Run-CrushMatrix   'check' (Join-Path $PS_REPO "scripts\crush-task.ps1")
if (PS-Summary "launcher-parity-ps") { exit 0 } else { exit 1 }
