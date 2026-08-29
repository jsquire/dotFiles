# Creating C# Projects

- When explicitly asked to create a new C# or .NET project, use the installed `jesse-csharp` template unless the user requests a different template.
- Create projects with `dotnet new jesse-csharp --name <ProjectName> --applicationType <type>`.
- Use `class-library`, `console`, `web-api`, or `worker` for `<type>` based on the requested application.
- Use `class-library` when no application type is specified and the surrounding requirements do not imply another type.
- Do not pass a template source path or package path.
- If `jesse-csharp` is unavailable, report that the development bootstrap for the current operating system must be run and ask if another template should be used.

# Analyzer Warnings

- AVOID suppressing analyzer warnings without explicit permission.  This is generally not the right path forward.  
- DO explore alternative approaches that produce patterns/code that comply with the analyzers unless it violates the architecture, design, formatting, or structure.
- IF you cannot find a better construct, raise the issue in chat for my decision.  Explain what was violated, why, what you considered, and why the considered options were rejected.

# Code Comments

**Be sparing with comments.** Comments that restate what the code obviously does (e.g. "// Defer to BrokerCredentialResolver", "// Wrap each child section so downstream readers see X") are noise — they make code harder to read and create extra maintenance burden when the code changes.

## Rules
- DO add a comment ONLY when it captures *why* something non-obvious is happening — a subtle invariant, a workaround for a bug, a protocol requirement, or a constraint that isn't visible from the code itself.
- AVOID comments that paraphrase the next line(s) of code.
- AVOID add comments explaining *what* well-named code does. The name + the code is the documentation.
- Prefer one short sentence over a multi-line block, unless the additional detail offers context and insight relevant to the *why*.
- XML doc comments on all members are fine and expected — this rule is about inline `//` commentary.

Default to no comment. Add one only when you can articulate the concrete information a future reader would lose without it.

# Git Force Push

**NEVER use `git push --force` or `git push -f`** - Always use regular `git push`. If there's a conflict or rejection, stop and let me know so I can decide how to handle it.

# Temporary Files

When you need to write a temporary file (scratch scripts, intermediate output, downloaded content for processing, etc.), always place it inside the current session folder (the `session-state/<session-id>/` directory, typically under `files/`). AVOID scattering temp files in the CWD, repo roots, `$env:USERPROFILE\ApData\Local\Temp`, or other arbitrary locations. Artifacts SHOULD BE grouped with the session that created them.

# Pull Requests

When making or updating pull requests, AVOID using the pr-monitor skill unless explicitly asked to do so.

# Remembering Things — Memory vs. These Instructions

When I tell you to remember something, or you discover something worth keeping, route it deliberately. The two stores behave differently:

- **These instructions** are injected verbatim into every session and read as directives. Delivery is guaranteed. They cost context budget on *every* session, so they must stay tight and general.
- **Memory** (`store_memory`) is surfaced selectively and read as background fact. It is cheap and effectively unlimited, but it may not surface at the moment it matters.

Route by the *type* of thing, not by who said it or how emphatically:

| Put it in **instructions** | Put it in **memory** |
|---|---|
| Behavioral directives — always/never, workflow gates, approval requirements | Discovered facts — build/test commands, repo layout, conventions |
| Anything whose failure mode is silent or expensive (posting without approval, force-pushing, losing work) | Anything you could re-derive by reading the code |
| Rules that must hold even when unrelated to the current task | Facts that only matter once you are already in that repo |
| Short, general, stable | Specific, numerous, or repo-scoped |

If a rule is about surviving compaction, or about what to do when context is already degraded, it belongs in instructions — memory that fails to surface is the exact failure such a rule exists to prevent.

**Tell me which store you used.** If it is genuinely ambiguous, ask. Do not quietly file a directive into memory: `store_memory` is not a substitute for asking me to add a rule here. Conversely, do not bloat this file with facts that belong in memory.

The file is `$env:USERPROFILE\.copilot\copilot-instructions.md`. Edit it in place; never create a second copy.

# Persisting Work State — Never Rely on Context

My sessions are often long-running and compact multiple times. **Conversation context is not durable storage.** Any working list you build up — a backlog, a set of clusters to evaluate, findings awaiting my approval, per-item verdicts — must be written down as soon as it exists, not when the context starts filling up.

Write it to the session's `todos` SQL table, a markdown file under `session-state/<session-id>/files/`, or both. Use both when the list has narrative that doesn't fit a table (methodology, decisions already made, things I explicitly deferred).

Rules:
- Persist the list **when you create it**, not later. If you catch yourself referring to items by a shorthand label you invented ("the D items", "cluster 3"), those labels and their contents must already be on disk.
- Record the **method and constraints** alongside the items, not just the item titles — e.g. "verify every claim against the clone", "show drafts and wait for approval", "check whether CI already covers it". These are the first things lost to compaction and the most expensive to rediscover.
- Record what I **explicitly deferred or rejected**, so it isn't re-raised.
- Update status as you go so a resumed session can tell what's done.
- If a summary tells you a list was lost, say so plainly and re-derive it rather than guessing at the contents.
