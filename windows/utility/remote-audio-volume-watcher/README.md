# Remote Audio Volume Watcher

A hidden Windows utility that keeps the Remote Audio endpoint at a configurable base volume and
applies that volume to application audio sessions when they open. It is intended for Microsoft
Dev Box and other Remote Desktop sessions where reconnecting or restarting an application resets
audio to 100%.

The default base volume is 40%. The notification-area context menu can select a base volume from
10% through 100% in 10% increments. A tray selection applies immediately to the endpoint and
currently open application sessions, then becomes the base for sessions that open later. The
selection is intentionally not persisted after the watcher exits.

The notification-area icon uses Microsoft's Fluent **Headphones Sound Wave** artwork as a blue
audio-processing badge. It is intentionally distinct from the speaker icon used by Windows volume
controls.

## Behavior

The watcher runs a 500-millisecond Core Audio scan while the current Windows session uses the
Remote Desktop protocol. It keeps the default multimedia render endpoint at the selected base
volume. Each newly observed application audio session receives the base volume during its first
four scans so applications can finish initializing without immediately resetting the value.
After that initialization window, the watcher does not overwrite manual per-application changes.

When the watcher is not running in a Remote Desktop session, it remains idle and does not change
the local audio endpoint.

## Install

Run the installer from PowerShell in this directory:

```powershell
.\Install.ps1
```

The installer verifies the committed NativeAOT executable, copies it to
`%LOCALAPPDATA%\remote-audio-volume-watcher`, registers a current-user logon task, and starts the
watcher. Administrator privileges are not required.

## Verify

Confirm the task and process are running:

```powershell
Get-ScheduledTask -TaskName 'Remote Audio Volume Watcher'
Get-Process remote-audio-volume-watcher
```

The active log is:

```text
%LOCALAPPDATA%\remote-audio-volume-watcher\logs\watcher.log
```

Restart an audio-producing application such as Teams. Its Volume Mixer entry should settle at the
selected base volume within two seconds. Reconnect the Remote Desktop session and confirm that
Remote Audio returns to the selected base volume.

## Configuration

The startup default can be overridden with an environment variable before the scheduled task
starts.

| Variable | Default | Purpose |
|---|---|---|
| `REMOTE_AUDIO_VOLUME_WATCHER_BASE_VOLUME_PERCENT` | `40` | Base endpoint and application volume from 1 through 100 |
| `REMOTE_AUDIO_VOLUME_WATCHER_LOG_PATH` | `%LOCALAPPDATA%\remote-audio-volume-watcher\logs\watcher.log` | Diagnostic log destination |

The log rolls at 1 MiB and retains one previous file as `watcher.log.1`.

## Uninstall

```powershell
.\Uninstall.ps1
```

The script removes only the watcher scheduled task and
`%LOCALAPPDATA%\remote-audio-volume-watcher`.

## Build and test

The project targets .NET 10 without external package dependencies.

```powershell
dotnet restore
dotnet build --no-restore -c Release
dotnet run --no-build -c Release --project .\tests\RemoteAudioVolumeWatcher.Tests.csproj
```

Create the self-contained Windows x64 executable from a Visual Studio Developer PowerShell
session:

```powershell
dotnet publish .\src\RemoteAudioVolumeWatcher\RemoteAudioVolumeWatcher.csproj -c Release -r win-x64
```

NativeAOT publishing requires the MSVC x64 toolchain. The publish target copies
`remote-audio-volume-watcher.exe` into `dist` and refreshes the adjacent SHA-256 file.

## Third-party artwork

The source icon is `ic_fluent_headphones_sound_wave_32_filled.svg` from Microsoft Fluent System
Icons. It is used and modified under the MIT license. The source SVG, generation script, and
license are retained under `src\RemoteAudioVolumeWatcher\assets`, and the license is included in
the published distribution.
