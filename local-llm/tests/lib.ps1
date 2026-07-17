# Shared helpers for the PowerShell-side test suites: asserts + a sandboxed .ps1 launcher runner.
# Isolation mirrors the bash lib: temp USERPROFILE seeded with fixtures, temp CWD for .crush.json,
# copilot/crush/Clear-Host/Read-Host/Invoke-RestMethod overridden (no network, no real launch).
# Reuses the SAME golden as the bash parity suite, so a pass also proves bash/PowerShell equivalence.

$PS_TESTS_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$PS_REPO      = Split-Path -Parent $PS_TESTS_DIR
$PS_FIX       = Join-Path $PS_TESTS_DIR "fixtures"

$script:PS_PASS = 0
$script:PS_FAIL = 0
$script:PS_LAST_OUT = ""
$script:PS_CRUSH = ""

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

# Normalise a JSON file identically to the bash side (python sort_keys/compact) so goldens match.
function Norm-Json($path) {
    if (-not $path -or -not (Test-Path $path)) { return "NONE" }
    (Get-Content $path -Raw) | wsl python3 -c "import json,sys;print(json.dumps(json.load(sys.stdin),sort_keys=True,separators=(',',':')))"
}

# Like Norm-Json but drops the imagegen-mcp env (covered by the imagegen-context suite, not parity).
function Norm-CrushJson($path) {
    if (-not $path -or -not (Test-Path $path)) { return "NONE" }
    (Get-Content $path -Raw) | wsl python3 -c "import json,sys;d=json.load(sys.stdin);d.get('mcp',{}).get('imagegen-mcp',{}).pop('env',None);print(json.dumps(d,sort_keys=True,separators=(',',':')))"
}

$script:PS_WRAPPER_TMPL = @'
$env:USERPROFILE = '__SB__'
function Clear-Host {}
function copilot {
    $ig = if ("$args" -match 'disable-mcp-server imagegen-mcp') { 'off' } else { 'on' }
    $of = if ($env:COPILOT_CUSTOM_INSTRUCTIONS_DIRS) { 'yes' } else { 'no' }
    $sep = if ($args -contains '--') { 'yes' } else { 'no' }
    Write-Host ("CAPTURE model=" + $env:COPILOT_MODEL + " base=" + $env:COPILOT_PROVIDER_BASE_URL + " prompt=" + $env:COPILOT_PROVIDER_MAX_PROMPT_TOKENS + " out=" + $env:COPILOT_PROVIDER_MAX_OUTPUT_TOKENS + " imagegen=" + $ig + " office=" + $of)
    Write-Host ("IMAGEGEN_HOST=" + $env:COPILOT_MCP_IMAGEGEN_HOST)
    Write-Host ("ARGV_HAS_SEP=" + $sep)
}
function crush { Write-Host "CAPTURE crush" }
function Invoke-RestMethod { throw "no network in tests" }
$script:__in = @(__INPUTS__); $script:__i = 0
function Read-Host { param($p) $v = $script:__in[$script:__i]; $script:__i++; $v }
Set-Location (Join-Path '__SB__' 'work')
. (Join-Path '__SB__' 'launcher.ps1') __LARGS__
'@

# Run a .ps1 launcher headless. Sets $script:PS_LAST_OUT and $script:PS_CRUSH (path or "").
function Invoke-LauncherPs1 {
    param([string]$Src, [string]$Providers, [string[]]$Inputs, [string]$ModelArg, [string]$TaskArg)
    $sb = Join-Path $env:TEMP ("llt_" + [guid]::NewGuid().ToString("N").Substring(0, 10))
    New-Item -ItemType Directory -Force -Path (Join-Path $sb ".config\local-llm"), (Join-Path $sb "work"), (Join-Path $sb ".config\crush\skills\office") | Out-Null
    Copy-Item (Join-Path $PS_FIX "local-models.5090.json") (Join-Path $sb ".config\local-llm\local-models.json")
    Copy-Item (Join-Path $PS_FIX "server-models.json") (Join-Path $sb ".config\local-llm\server-models.json")
    Set-Content (Join-Path $sb ".config\crush\skills\office\SKILL.md") "office skill (test fixture)" -Encoding UTF8
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
    if ($TaskArg)  { $largs = "-Task '$TaskArg'" }
    $wrapper = $script:PS_WRAPPER_TMPL.Replace('__SB__', $sb).Replace('__INPUTS__', $inLit).Replace('__LARGS__', $largs)
    [System.IO.File]::WriteAllText((Join-Path $sb "wrapper.ps1"), $wrapper, $withBom)

    $raw = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sb "wrapper.ps1") 2>&1 |
        ForEach-Object { ($_ | Out-String).TrimEnd("`r", "`n") -replace "$([char]27)\[[0-9;]*m", "" }
    $script:PS_LAST_OUT = ($raw -join "`n")

    $cj = Join-Path $sb "work\.crush.json"
    if (Test-Path $cj) {
        $dst = Join-Path $env:TEMP ("cj_" + [guid]::NewGuid().ToString("N").Substring(0, 10) + ".json")
        Copy-Item $cj $dst
        $script:PS_CRUSH = $dst
    } else {
        $script:PS_CRUSH = ""
    }
    Remove-Item -Recurse -Force $sb
}
