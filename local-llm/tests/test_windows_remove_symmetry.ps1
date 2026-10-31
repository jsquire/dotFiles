# Executes the Windows client-asset removal function against isolated profiles.
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "lib.ps1")

$removeScript = Join-Path $PS_REPO "windows\remove-windows.ps1"
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($removeScript, [ref]$tokens, [ref]$errors)
$fn = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "Remove-InstallerOwnedClientAssets"
}, $true)
if (-not $fn) {
    Write-Host "  FAIL: Remove-InstallerOwnedClientAssets function not found"
    exit 1
}
Invoke-Expression $fn.Extent.Text

function Write-Info {}
function Write-Success {}
function Write-Warn {}
function Remove-SafeItem {
    param([string]$Path, [string]$Description)
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
}

function New-OwnedProfile($name) {
    $root = Join-Path $env:TEMP $name
    $profile = Join-Path $root "profile"
    $appdata = Join-Path $profile "AppData\Roaming"
    $paths = @(
        (Join-Path $profile "Documents\CLI"),
        (Join-Path $profile ".config\local-llm\icons"),
        (Join-Path $profile ".config\local-llm\.installer-owned"),
        (Join-Path $profile ".copilot\skills\office"),
        (Join-Path $profile ".copilot"),
        (Join-Path $profile "AppData\Local\ollama-host"),
        (Join-Path $appdata "Microsoft\Windows\Start Menu\Programs\AI")
    )
    New-Item -ItemType Directory -Path $paths -Force | Out-Null
    foreach ($path in @(
        (Join-Path $profile "Documents\CLI\copilot-local.ps1"),
        (Join-Path $profile "Documents\CLI\copilot-local.cmd"),
        (Join-Path $profile ".config\local-llm\local-models.json"),
        (Join-Path $profile ".config\local-llm\server-models.json"),
        (Join-Path $profile ".config\local-llm\icons\copilot-light.ico"),
        (Join-Path $profile ".config\local-llm\.installer-owned\copilot-mcp-config"),
        (Join-Path $profile ".copilot\skills\office\SKILL.md"),
        (Join-Path $profile ".copilot\mcp-config.json"),
        (Join-Path $profile "AppData\Local\ollama-host\ollama-host.exe"),
        (Join-Path $appdata "Microsoft\Windows\Start Menu\Programs\AI\Copilot (Local).lnk"),
        (Join-Path $appdata "Microsoft\Windows\Start Menu\Programs\AI\Ollama Host.lnk")
    )) {
        Set-Content -LiteralPath $path -Value "managed"
    }
    Set-Content -LiteralPath (Join-Path $profile ".config\local-llm\user-notes.json") -Value "user"
    [pscustomobject]@{ Root = $root; Profile = $profile; AppData = $appdata }
}

$removeCase = New-OwnedProfile ("remove_owned_" + [guid]::NewGuid().ToString("N"))
Remove-InstallerOwnedClientAssets $removeCase.Profile $removeCase.AppData $false
Assert-Eq "launcher removed" $false (Test-Path (Join-Path $removeCase.Profile "Documents\CLI\copilot-local.ps1"))
Assert-Eq "roster removed" $false (Test-Path (Join-Path $removeCase.Profile ".config\local-llm\local-models.json"))
Assert-Eq "office skill removed" $false (Test-Path (Join-Path $removeCase.Profile ".copilot\skills\office"))
Assert-Eq "managed MCP removed" $false (Test-Path (Join-Path $removeCase.Profile ".copilot\mcp-config.json"))
Assert-Eq "shortcut removed" $false (Test-Path (Join-Path $removeCase.AppData "Microsoft\Windows\Start Menu\Programs\AI\Copilot (Local).lnk"))
Assert-Eq "user file preserved" $true (Test-Path (Join-Path $removeCase.Profile ".config\local-llm\user-notes.json"))

$keepCase = New-OwnedProfile ("keep_owned_" + [guid]::NewGuid().ToString("N"))
Remove-InstallerOwnedClientAssets $keepCase.Profile $keepCase.AppData $true
Assert-Eq "keep-config still removes launcher" $false (Test-Path (Join-Path $keepCase.Profile "Documents\CLI\copilot-local.ps1"))
Assert-Eq "keep-config preserves roster" $true (Test-Path (Join-Path $keepCase.Profile ".config\local-llm\local-models.json"))
Assert-Eq "keep-config preserves office" $true (Test-Path (Join-Path $keepCase.Profile ".copilot\skills\office\SKILL.md"))
Assert-Eq "keep-config preserves MCP" $true (Test-Path (Join-Path $keepCase.Profile ".copilot\mcp-config.json"))

Remove-Item $removeCase.Root, $keepCase.Root -Recurse -Force
if (PS-Summary "windows-remove-symmetry") { exit 0 } else { exit 1 }
