# Remote Audio Volume Watcher

A Windows NativeAOT tray utility that applies a configurable base volume to the Remote Audio
endpoint and application audio sessions in a Remote Desktop session.

## Build, Test, Publish

```powershell
dotnet restore
dotnet build --no-restore -c Release
dotnet run --no-build -c Release --project .\tests\RemoteAudioVolumeWatcher.Tests.csproj
dotnet publish .\src\RemoteAudioVolumeWatcher\RemoteAudioVolumeWatcher.csproj -c Release -r win-x64
```

NativeAOT publish requires the MSVC x64 toolchain in the same process. A successful publish stages
the executable and checksum under `dist`.

## Structure

| Path | Purpose |
|---|---|
| `src/RemoteAudioVolumeWatcher` | Native Windows message loop, Core Audio polling, and tray menu |
| `tests` | Executable tests for configuration and audio-session tracking |
| `dist` | Prebuilt self-contained Windows x64 executable and SHA-256 |
| `Install.ps1` | Verifies and deploys the binary as a current-user logon task |
| `Uninstall.ps1` | Removes only the watcher task and deployed files |

## Design

- Keep all Win32 and COM interop in `Native.cs`.
- Preserve NativeAOT compatibility and avoid desktop UI frameworks or runtime dependencies.
- Keep the process console-free. User interaction belongs in the raw Win32 tray icon and menu.
- Apply the base volume only while the process runs in a Remote Desktop session.
- Keep the Remote Audio endpoint at the selected base volume.
- Apply the base volume to application sessions during their initialization window.
- Do not persist tray selections between watcher processes.

## Conventions

- Shared compiler and analyzer settings belong in `Directory.Build.props`.
- Use file-scoped namespaces, nullable reference types, four spaces, and Allman braces.
- Mutable fields use `_camelCase`. Constants and readonly fields use PascalCase.
- Document public and non-obvious internal contracts.
- Test observable behavior with deterministic assertions.
- Do not suppress analyzer warnings without explicit approval.
- Verify Win32 and Core Audio signatures against current Microsoft documentation.
