# Polychrome Display Watcher

A Windows NativeAOT tray utility that restarts ASRock Polychrome DISPLAY after the interactive
display transitions from off to on.

## Build, Test, Publish

```powershell
dotnet restore
dotnet build --no-restore -c Release
dotnet test --no-build -c Release
dotnet publish .\src\PolychromeDisplayWatcher\PolychromeDisplayWatcher.csproj -c Release -r win-x64
```

NativeAOT publish requires the MSVC x64 toolchain in the same process. A successful publish stages
the executable and checksum under `dist`.

## Structure

| Path | Purpose |
|---|---|
| `src/PolychromeDisplayWatcher` | Native Windows message loop, display transition tracking, and process restart |
| `tests` | NUnit tests for transition and configuration behavior |
| `dist` | Prebuilt self-contained Windows x64 executable and SHA-256 |
| `Install.ps1` | Verifies and deploys the binary as a highest-privilege logon task |
| `Uninstall.ps1` | Removes only the watcher task and deployed files |

## Design

- Keep all Win32 interop in `Native.cs`.
- Preserve NativeAOT compatibility and avoid desktop UI frameworks.
- Keep the process console-free. User interaction belongs in the raw Win32 tray icon and menu.
- React only to a confirmed session display `Off` to `On` transition.
- Do not alter Polychrome themes, USB state, firmware, or ASRock's startup tasks.
- Keep operational defaults configurable through the documented environment variables.

## Conventions

- Shared compiler and analyzer settings belong in `Directory.Build.props`.
- Package versions belong only in `Directory.Packages.props`.
- Use file-scoped namespaces, nullable reference types, four spaces, and Allman braces.
- Mutable fields use `_camelCase`. Constants and readonly fields use PascalCase.
- Document public and non-obvious internal contracts.
- Test observable behavior with NUnit constraint assertions.
- Do not suppress analyzer warnings without explicit approval.
- Verify Win32 signatures against current Microsoft documentation.
