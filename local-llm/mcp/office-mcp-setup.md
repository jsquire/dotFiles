# OfficeMCP Setup Guide

OfficeMCP is a .NET-based MCP server from Microsoft that provides Word, PowerPoint, Excel, and PDF creation/editing capabilities.  No Office license is required — it manipulates the underlying XML inside `.docx`, `.pptx`, and `.xlsx` files directly.

## Prerequisites

- .NET 8.0 SDK or Runtime (`winget install Microsoft.DotNet.SDK.8` or `pacman -S dotnet-sdk`)
- Crush configured with MCP server support

## Installation (Windows)

```powershell
# Clone the repository
git clone https://github.com/anthropics/office-mcp.git "$env:LOCALAPPDATA\ai-tools\office-mcp"

# Build
cd "$env:LOCALAPPDATA\ai-tools\office-mcp"
dotnet build -c Release

# Verify
dotnet run --project src/OfficeMcp -- --help
```

## Installation (Linux)

```bash
git clone https://github.com/anthropics/office-mcp.git ~/.local/share/ai-tools/office-mcp
cd ~/.local/share/ai-tools/office-mcp
dotnet build -c Release
```

## Configure in Crush

Add to `~/.crush/mcp-servers.json`:

```json
{
    "office-mcp": {
        "command": "dotnet",
        "args": ["run", "--project", "%LOCALAPPDATA%\\ai-tools\\office-mcp\\src\\OfficeMcp"],
        "description": "Microsoft Office document creation"
    }
}
```

## Capabilities

| Feature | Supported |
|---------|-----------|
| Create Word documents | ✅ Headings, tables, images, lists, formatting |
| Create PowerPoint decks | ✅ Slides, text, tables, shapes |
| Create Excel workbooks | ✅ Sheets, formulas, formatting |
| Read/modify existing docs | ✅ Full round-trip |
| Apply branded templates | ✅ Provide .pptx/.docx template files in `mcp/templates/` |
| Complex charts, SmartArt | ⚠️ Charts are basic; SmartArt unsupported |
| Macro-enabled documents | ❌ Not supported |

## Alternative Python-Based Servers

For finer PowerPoint or Word control, use the Python-based MCP servers instead:

- **Office-PowerPoint-MCP-Server** — themes, templates, charts, images
- **Office-Word-MCP-Server** — headings, tables, images, PDF conversion

These are set up automatically by `setup-mcp-venvs.ps1` / `setup-mcp-venvs.sh`.

## Templates

Place branded `.docx` and `.pptx` templates in `mcp/templates/`.  The MCP server can use these as starting points for new documents, applying your organization's styles, logos, and formatting.
