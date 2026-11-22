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

function Get-AncestorConditions($node) {
    $result = @()
    $node = $node.Parent
    while ($node) {
        if ($node -is [Management.Automation.Language.IfStatementAst]) {
            foreach ($clause in $node.Clauses) {
                $result += $clause.Item1.Extent.Text.Trim()
            }
        }
        $node = $node.Parent
    }
    @($result)
}

$hostCopies = @($ast.FindAll(
    {
        param($node)
        $node -is [Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Copy-Item' -and
            $node.Extent.Text -match '\$ollamaHostSource'
    },
    $true))

Assert-Eq "Ollama Host executable has one deployment copy" 1 $hostCopies.Count
$hostCopyConditions = if ($hostCopies.Count -eq 1) { Get-AncestorConditions $hostCopies[0] } else { @() }
Assert-Eq "Ollama Host deployment requires Full mode" $true ($hostCopyConditions -contains '$IsFullMode')
Assert-Eq "Ollama Host deployment requires client tools" $true ($hostCopyConditions -contains '$InstallClientTools')

$hostShortcuts = @($ast.FindAll(
    {
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -eq '$hostLnk'
    },
    $true))

Assert-Eq "Ollama Host has one shortcut creation" 1 $hostShortcuts.Count
$hostShortcutConditions = if ($hostShortcuts.Count -eq 1) { Get-AncestorConditions $hostShortcuts[0] } else { @() }
Assert-Eq "Ollama Host shortcut requires Full mode" $true ($hostShortcutConditions -contains '$IsFullMode')
Assert-Eq "Ollama Host shortcut requires client tools" $true ($hostShortcutConditions -contains '$InstallClientTools')

if (PS-Summary "windows-installer-scope") { exit 0 } else { exit 1 }
