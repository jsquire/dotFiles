# MCP Tool Setup — Windows
#
# Installs MCP servers as uv tools (globally accessible via uvx).
# Run this AFTER install-windows.ps1 has installed uv and Python.
#
# Usage:
#   .\setup-mcp-venvs.ps1

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$McpTools = @(
    @{ Package = "ppt-mcp";          Python = $null;  Description = "PowerPoint COM automation (154 tools)" }
    @{ Package = "docx-mcp-server";  Python = "3.12"; Description = "Word OOXML editing (45 tools)" }
)

foreach ($tool in $McpTools) {
    Write-Host "`n── Installing $($tool.Description) ──" -ForegroundColor Cyan

    $args = @("tool", "install", $tool.Package)
    if ($tool.Python) {
        $args += "--python"
        $args += $tool.Python
    }

    & uv @args

    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✓ $($tool.Package) ready" -ForegroundColor Green
    } else {
        Write-Host "  ✗ Failed to install $($tool.Package)" -ForegroundColor Red
    }
}

Write-Host "`n── Done ──" -ForegroundColor Cyan
Write-Host "MCP tools installed globally via uv. Use 'uvx <tool>' to run."
Write-Host "Config files point to 'uvx' command — no path changes needed."
