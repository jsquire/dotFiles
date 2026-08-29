# Jesse.Project-1

This repository was generated from the Jesse C# Solution template.

The selected application type is `__APPLICATION_TYPE__`.

## Structure

- `src/Jesse.Project-1` contains the application.
- `tests/Jesse.Project-1.Tests` contains NUnit tests.
- `.agents/skills` contains portable task guidance for coding agents.
- `.github/instructions` contains GitHub-specific path instructions.
- `Directory.Build.props` contains shared compiler and analyzer settings.
- `Directory.Packages.props` contains every package version.

## Build and test

```shell
dotnet restore
dotnet build --no-restore
dotnet test --no-build
```

The repository targets .NET 10 LTS and uses Microsoft.Testing.Platform with NUnit.

## Package management

Central Package Management is required. Add package references without versions to project files and add each version to `Directory.Packages.props`.

## Agent guidance

Coding agents should read `AGENTS.md` before making changes and load the relevant skill from `.agents/skills`.
