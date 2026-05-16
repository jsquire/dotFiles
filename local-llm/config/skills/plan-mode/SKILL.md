# Plan/Act Mode

## Overview
This project uses a Plan/Act mode system with three components:
1. A **plan-mode MCP server** for toggling (tools: `plan_mode_enable`, `plan_mode_disable`, `plan_mode_status`)
2. A **PreToolUse hook** that blocks write tools when plan mode is active
3. This **skill** that defines your behavior in each mode

## How to Toggle

Use the MCP tools — do NOT use bash for toggling:
- **Enable plan mode:** Call `plan_mode_enable`
- **Disable plan mode:** Call `plan_mode_disable`
- **Check current mode:** Call `plan_mode_status`

## Behavior

### When plan mode is active:
- **DO:** Analyze code, read files, search, discuss approaches, outline changes
- **DO:** Present proposed changes as diffs or descriptions
- **DO:** Ask clarifying questions about requirements
- **DO NOT:** Write files, run bash commands that modify state, or use edit tools
- **ANNOUNCE:** "🔒 Plan mode is active. I'll analyze and suggest without making changes."

### When act mode is active:
- **DO:** Execute the agreed-upon plan — write files, run commands, make changes
- **ANNOUNCE:** "🔓 Act mode is active. Proceeding with implementation."

## User Commands

When the user says any of these, use the corresponding MCP tool:
- "plan mode", "switch to plan", "plan", "/plan" → call `plan_mode_enable`
- "act mode", "switch to act", "act", "/act", "go ahead", "implement it" → call `plan_mode_disable`
- "what mode", "status", "are you in plan mode" → call `plan_mode_status`

## On Session Start

At the beginning of each session, call `plan_mode_status` to check the current mode
and announce it. This catches cases where the toggle file persists across sessions.

## Notes
- The hook blocks tools at the infrastructure level — even if you try to write, Crush will prevent it
- Read-only tools (grep, glob, view, read) are never blocked
- The MCP toggle tools are never blocked — you can always switch modes
- MCP tools that read data are not blocked; only `mcp__filesystem` write operations are matched
