# Windows Development

### Overview

Included in this section are the artifacts and references used for configuring user-scoped development tools and defaults on Windows.

The bootstrap provides a Windows entry point for assets that should be available across working directories, rather than configuration tied to a single repository.  Shared source assets are maintained in the root `config` directory so that other operating-system bootstraps can install the same configuration.

In some cases, the artifacts may be a subset of functionality, requiring use in a specific way or order to be helpful, where others may be a fully automated and self-contained process.  Please remember that these were written for practical personal use and are not intended to be examples of best practice, nor polished and production-ready.

### Configuration

* **config/copilot**  
  _Contains the shared personal instructions installed for GitHub Copilot CLI across operating systems._

* **config/templates**  
  _Contains shared source and packaging assets for personal project templates installed into user-scoped template registries._

### Items

* **Install-DevelopmentEnvironment.ps1**  
  _Authored in 2026, this idempotent PowerShell bootstrap installs or refreshes the user-scoped development assets in this section.  It currently deploys the personal Copilot instructions and packages, registers, and verifies the .NET project templates._

### Usage

Run the bootstrap from PowerShell.

```powershell
.\Install-DevelopmentEnvironment.ps1
```

Use `-Validate` to exercise any installed assets that provide validation.  The current validation generates, restores, builds, and tests each application type exposed by the C# template.

```powershell
.\Install-DevelopmentEnvironment.ps1 -Validate
```

Use `-WhatIf` to preview the bootstrap without making changes.

```powershell
.\Install-DevelopmentEnvironment.ps1 -WhatIf
```

The bootstrap installs the following user-scoped assets.

* Personal Copilot instructions at `$HOME\.copilot\copilot-instructions.md` when the file does not already exist.
* The `jesse-csharp` template in the current user's `dotnet new` registry.

See the documentation under the root `config` directory for asset-specific behavior and usage.
