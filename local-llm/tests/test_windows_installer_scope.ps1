. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "lib.ps1")

$installer = Join-Path $PS_REPO "windows\install-windows.ps1"
$source = Get-Content -LiteralPath $installer -Raw

$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $installer,
    [ref]$tokens,
    [ref]$errors)

Assert-Eq "installer parses for scope inspection" 0 @($errors).Count
Assert-Eq "full install retains csharp-ls" $true ($source -match 'function Install-CSharpLanguageServer')
Assert-Eq "full install pins csharp-ls" $true ($source -match 'csharp-ls --version 0\.28\.0')
Assert-Eq "full install retains the .NET 11 prerequisite" $true ($source -match 'Microsoft\.DotNet\.SDK\.11')

$calls = @($ast.FindAll(
    {
        param($node)
        $node -is [Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Install-CSharpLanguageServer'
    },
    $true))

Assert-Eq "language server has one installation call" 1 $calls.Count

$conditions = @()
if ($calls.Count -eq 1) {
    $node = $calls[0].Parent
    while ($node) {
        if ($node -is [Management.Automation.Language.IfStatementAst]) {
            foreach ($clause in $node.Clauses) {
                $conditions += $clause.Item1.Extent.Text.Trim()
            }
        }
        $node = $node.Parent
    }
}

Assert-Eq "language server requires Full mode" $true ($conditions -contains '$IsFullMode')
Assert-Eq "language server requires client tools" $true ($conditions -contains '$InstallClientTools')
Assert-Eq "Client mode does not guard the language server call" $false ($conditions -contains '$IsClientMode')

if (PS-Summary "windows-installer-scope") { exit 0 } else { exit 1 }
