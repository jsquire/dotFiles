# Shared helpers for the PowerShell-side test suites: asserts + a sandboxed .ps1 launcher runner.
# Isolation mirrors the bash lib: temp USERPROFILE seeded with canonical rosters and
# copilot/Clear-Host/Read-Host/Invoke-RestMethod overridden (no network, no real launch).
# Shared launcher semantics come from tests/semantic_oracle.py.

$PS_TESTS_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$PS_REPO      = Split-Path -Parent $PS_TESTS_DIR

$script:PS_PASS = 0
$script:PS_FAIL = 0
$script:PS_LAST_OUT = ""

function Assert-Eq($name, $expected, $actual) {
    if ($expected -ceq $actual) {
        $script:PS_PASS++
    } else {
        $script:PS_FAIL++
        Write-Host "  FAIL: $name"
        Write-Host "        expected: [$expected]"
        Write-Host "        actual:   [$actual]"
    }
}

function PS-Summary($name) {
    Write-Host ""
    Write-Host ("{0,-28} {1} passed, {2} failed" -f "${name}:", $script:PS_PASS, $script:PS_FAIL)
    return ($script:PS_FAIL -eq 0)
}

# JSON normalisation runs through Python so the output matches the bash side byte for byte. Prefer a
# native Windows python3; fall back to `wsl python3` only when there isn't one. The WSL round trip was
# the sole reason these suites needed a working WSL install, and a wedged WSL hangs them indefinitely.
$script:PS_PY = $null
foreach ($_c in @('python', 'python3')) {
    $_cmd = Get-Command $_c -ErrorAction SilentlyContinue
    if ($_cmd) {
        if ($_cmd.Source -like "*\WindowsApps\*") { continue }
        & $_cmd.Source -c "import sys; sys.exit(0)" 2>$null
        if ($LASTEXITCODE -eq 0) { $script:PS_PY = $_cmd.Source; break }
    }
}
function Invoke-PyJson([string]$code, [string]$stdin) {
    if ($script:PS_PY) { $stdin | & $script:PS_PY -c $code }
    else { $stdin | wsl python3 -c $code }
}
function Invoke-PyFile([string]$path, [string]$stdin) {
    if ($script:PS_PY) {
        $stdin | & $script:PS_PY $path
    } else {
        $drive = $path.Substring(0, 1).ToLowerInvariant()
        $rest = $path.Substring(2).Replace('\', '/')
        $wslPath = "/mnt/$drive$rest"
        $expectedPath = $env:ORACLE_EXPECTED
        if ($expectedPath -match '^[A-Za-z]:') {
            $expectedDrive = $expectedPath.Substring(0, 1).ToLowerInvariant()
            $expectedRest = $expectedPath.Substring(2).Replace('\', '/')
            $expectedPath = "/mnt/$expectedDrive$expectedRest"
        }
        $stdin | wsl env `
            "ORACLE_KIND=$($env:ORACLE_KIND)" `
            "ORACLE_PLATFORM=$($env:ORACLE_PLATFORM)" `
            "ORACLE_SERVER_IP=$($env:ORACLE_SERVER_IP)" `
            "ORACLE_EXPECTED=$expectedPath" `
            python3 $wslPath
    }
}

# Normalise a JSON file identically to the bash side (python sort_keys/compact) so goldens match.
function Norm-Json($path) {
    if (-not $path -or -not (Test-Path $path)) { return "NONE" }
    Invoke-PyJson "import json,sys;print(json.dumps(json.load(sys.stdin),sort_keys=True,separators=(',',':')))" (Get-Content $path -Raw)
}

$script:PS_WRAPPER_TMPL = @'
$env:USERPROFILE = '__SB__'
$env:LL_TEST = '1'
$env:LL_STUB_SERVER_JSON = '__SERVER_JSON__'
$env:LL_STUB_SWITCH_MODE = '__SWITCH_MODE__'
$env:LL_STUB_SWITCH_LOG = '__SWITCH_LOG__'
$env:LL_SWITCH_POLL_ATTEMPTS = '2'
$env:LL_SWITCH_POLL_DELAY = '0'
function Clear-Host {}
function copilot {
    $capturedArgs = @($args)
    $ig = if ("$args" -match 'disable-mcp-server imagegen-mcp') { 'off' } else { 'on' }
    $of = if ($env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS) { 'yes' } else { 'no' }
    $sep = if ($args -contains '--') { 'yes' } else { 'no' }
    Write-Host ("CAPTURE model=" + $env:COPILOT_MODEL + " base=" + $env:COPILOT_PROVIDER_BASE_URL + " prompt=" + $env:COPILOT_PROVIDER_MAX_PROMPT_TOKENS + " out=" + $env:COPILOT_PROVIDER_MAX_OUTPUT_TOKENS + " imagegen=" + $ig + " office=" + $of)
    Write-Host ("IMAGEGEN_HOST=" + $env:COPILOT_MCP_IMAGEGEN_HOST)
    Write-Host ("IMAGEGEN_PORT=" + $env:COPILOT_MCP_IMAGEGEN_PORT)
    Write-Host ("IMAGEGEN_BACKEND=" + $env:COPILOT_MCP_IMAGEGEN_BACKEND)
    Write-Host ("ARGV_HAS_SEP=" + $sep)
    $jsonArgs = @($capturedArgs | ForEach-Object { ConvertTo-Json -Compress -InputObject ([string]$_) })
    Write-Host ("ARGV_JSON=[" + ($jsonArgs -join ',') + "]")
    foreach ($arg in $capturedArgs) { Write-Host ("ARGV_ITEM=" + $arg) }
}
$script:__switchMode = ""
function Invoke-RestMethod {
    param($Uri, $Method, $ContentType, $Body, $TimeoutSec, $ErrorAction)
    if ($Uri -like '*/models') {
        return (Get-Content $env:LL_STUB_SERVER_JSON -Raw | ConvertFrom-Json)
    }
    if ($Uri -like '*/switch') {
        if ($env:LL_STUB_SWITCH_LOG) {
            Add-Content $env:LL_STUB_SWITCH_LOG "SWITCH_URL=$Uri"
            Add-Content $env:LL_STUB_SWITCH_LOG "SWITCH_BODY=$Body"
        }
        if ($env:LL_STUB_SWITCH_MODE -eq 'failure') { throw "stubbed switch failure" }
        $script:__switchMode = (ConvertFrom-Json $Body).mode
        return [pscustomobject]@{ ok = $true; mode = $script:__switchMode }
    }
    if ($Uri -like '*/status') {
        if ($env:LL_STUB_SWITCH_LOG) { Add-Content $env:LL_STUB_SWITCH_LOG "STATUS_URL=$Uri" }
        return [pscustomobject]@{
            mode = $script:__switchMode
            api_up = ($env:LL_STUB_SWITCH_MODE -eq 'success')
        }
    }
    throw "test double refused URL: $Uri"
}
$script:__in = @(__INPUTS__); $script:__i = 0
function Read-Host { param($p) $v = $script:__in[$script:__i]; $script:__i++; $v }
Set-Location (Join-Path '__SB__' 'work')
. (Join-Path '__SB__' 'launcher.ps1') __LARGS__
'@

# Run a .ps1 launcher headless. Sets $script:PS_LAST_OUT.
function Invoke-LauncherPs1 {
    param(
        [string]$Src,
        [string]$Providers,
        [string[]]$Inputs,
        [string]$ModelArg,
        [string]$LocalRoster,
        [string]$SwitchMode = "failure",
        [string]$SwitchLog = ""
    )
    $sb = Join-Path $env:TEMP ("llt_" + [guid]::NewGuid().ToString("N").Substring(0, 10))
    New-Item -ItemType Directory -Force -Path (Join-Path $sb ".config\local-llm"), (Join-Path $sb "work") | Out-Null
    $roster = if ($LocalRoster) { $LocalRoster } else { Join-Path $PS_REPO "scripts\local-models.json" }
    Copy-Item $roster (Join-Path $sb ".config\local-llm\local-models.json")
    $serverRoster = Join-Path $PS_REPO "cachyos\server-models.json"
    Copy-Item $serverRoster (Join-Path $sb ".config\local-llm\server-models.json")
    $bomless = New-Object System.Text.UTF8Encoding($false)
    # PS 5.1's script loader mis-decodes some UTF-8-no-BOM files at load time (not at static parse),
    # so write the sandbox copies WITH a BOM to force correct UTF-8 loading (e.g. the pre-refactor
    # baseline, which still contains em-dashes that would otherwise inject a stray quote).
    $withBom = New-Object System.Text.UTF8Encoding($true)
    $c = [System.IO.File]::ReadAllText($Src, [System.Text.Encoding]::UTF8)
    $squireIp = if ($env:LL_TEST_SQUIRE_IP) { $env:LL_TEST_SQUIRE_IP } else { '127.0.0.1' }
    $c = $c -replace '__SQUIRE_SERVER_IP__', $squireIp -replace '__SQUIRE_SSH_TARGET__', 'test@127.0.0.1' -replace '__LL_PROVIDERS__', $Providers
    [System.IO.File]::WriteAllText((Join-Path $sb "launcher.ps1"), $c, $withBom)

    $inLit = ($Inputs | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ','
    $largs = ""
    if ($ModelArg) { $largs = "-Model '$ModelArg'" }
    $wrapper = $script:PS_WRAPPER_TMPL.Replace('__SB__', $sb).
        Replace('__SERVER_JSON__', (Join-Path $sb ".config\local-llm\server-models.json")).
        Replace('__SWITCH_MODE__', $SwitchMode).
        Replace('__SWITCH_LOG__', $SwitchLog).
        Replace('__INPUTS__', $inLit).
        Replace('__LARGS__', $largs)
    [System.IO.File]::WriteAllText((Join-Path $sb "wrapper.ps1"), $wrapper, $withBom)

    $raw = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sb "wrapper.ps1") 2>&1 |
        ForEach-Object { ($_ | Out-String).TrimEnd("`r", "`n") -replace "$([char]27)\[[0-9;]*m", "" }
    $script:PS_LAST_OUT = ($raw -join "`n")

    Remove-Item -Recurse -Force $sb
}
