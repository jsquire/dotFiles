# MCP Venv Setup — Windows
#
# Creates isolated uv virtual environments for each MCP server.
# Run this AFTER install-windows.ps1 has installed uv and Python.
#
# Usage:
#   .\setup-mcp-venvs.ps1

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$AiToolsRoot = Join-Path $env:LOCALAPPDATA "ai-tools"

$McpServers = @(
    @{ Name = "mcp-office";  Package = "office-mcp";       Description = "OfficeMCP — Word, PowerPoint, Excel" }
    @{ Name = "mcp-word";    Package = "python-docx-mcp";  Description = "Word MCP via python-docx" }
    @{ Name = "mcp-pptx";    Package = "python-pptx-mcp";  Description = "PowerPoint MCP via python-pptx" }
)

foreach ($server in $McpServers) {
    $venvPath = Join-Path $AiToolsRoot $server.Name
    Write-Host "`n── Setting up $($server.Description) ──" -ForegroundColor Cyan

    if (Test-Path $venvPath) {
        Write-Host "  Directory exists, updating..." -ForegroundColor Yellow
    } else {
        New-Item -ItemType Directory -Path $venvPath -Force | Out-Null
        Write-Host "  Created $venvPath"
    }

    Write-Host "  Initializing uv project..."
    & uv init --directory $venvPath --no-readme 2>&1 | Out-Null

    Write-Host "  Installing $($server.Package)..."
    & uv add --directory $venvPath $server.Package

    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✓ $($server.Name) ready" -ForegroundColor Green
    } else {
        Write-Host "  ✗ Failed to install $($server.Package)" -ForegroundColor Red
    }
}

Write-Host "`n── Done ──" -ForegroundColor Cyan
Write-Host "MCP venvs are at: $AiToolsRoot"
Write-Host "Update ~/.crush/mcp-servers.json to point to these paths."
Write-Host "See config/mcp-servers.json for a template."
