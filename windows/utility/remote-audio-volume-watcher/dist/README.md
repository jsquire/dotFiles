# Remote Audio Volume Watcher

The executable in this directory is a self-contained NativeAOT tray utility for Windows x64. It
does not require a separately installed .NET runtime. The adjacent `.sha256` file is verified by
`Install.ps1` before deployment. `remote-audio.ico` provides the notification-area and executable
icon. Its Microsoft Fluent System Icons MIT license is included beside it.

Rebuild and refresh the shipping artifact from a Visual Studio Developer PowerShell session.

```powershell
dotnet publish .\src\RemoteAudioVolumeWatcher\RemoteAudioVolumeWatcher.csproj -c Release -r win-x64
```
