# Development Templates

### Overview

Included in this section are source and packaging assets for personal project templates installed by the operating-system development bootstraps.

The current collection contains the `jesse-csharp` .NET solution template.  It is packaged as `Jesse.CSharp.Templates` and registered with the current user's `dotnet new` template registry, allowing it to be used from any working directory without a source or package path.

### Structure

* **content**  
  _Contains the files emitted into generated projects, including repository configuration, agent instructions, reusable skills, source projects, tests, and automation._

### Items

* **Jesse.CSharp.Templates.csproj**  
  _Defines the NuGet template package installed by the supported operating-system development bootstraps._

### Usage

Inspect the available options.

```shell
dotnet new jesse-csharp --help
```

Create a project.

```shell
dotnet new jesse-csharp --name Contoso.Sample --applicationType class-library
```

Supported application types are `class-library`, `console`, `web-api`, and `worker`.

Generated repositories include NUnit, NSubstitute, native Microsoft.Testing.Platform, Central Package Management, GitHub Actions, Dependabot, `AGENTS.md`, and portable agent skills.

GitHub Copilot CLI reads the generated `AGENTS.md`, `.agents/skills`, and `.github/instructions` assets.  Crush reads the generated `AGENTS.md` and `.agents/skills` assets.

Remove the installed package with:

```shell
dotnet new uninstall Jesse.CSharp.Templates
```
