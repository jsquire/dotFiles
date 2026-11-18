---
name: create-dotnet-project
description: Personal template guidance. Use only when explicitly asked to create a new C# or .NET project.
---

# Creating C# Projects

- When explicitly asked to create a new C# or .NET project, use the installed `jesse-csharp` template unless the user requests a different template.
- Create projects with `dotnet new jesse-csharp --name <ProjectName> --applicationType <type>`.
- Use `class-library`, `console`, `web-api`, or `worker` for `<type>` based on the requested application.
- Use `class-library` when no application type is specified and the surrounding requirements do not imply another type.
- Do not pass a template source path or package path.
- If `jesse-csharp` is unavailable, report that limitation and ask how to proceed. Do not install templates, run bootstrap scripts, or substitute another template without approval.

