# Polychrome Display Watcher

The executable in this directory is a self-contained NativeAOT tray utility for Windows x64. It does
not require a separately installed .NET runtime. The adjacent `.sha256` file is verified by
`Install.ps1` before deployment. `security.ico` is deployed beside the executable and provides the
watcher's distinct notification-area icon.

Rebuild and refresh the shipping artifact from a Visual Studio Developer PowerShell session.

```powershell
dotnet publish .\src\PolychromeDisplayWatcher\PolychromeDisplayWatcher.csproj -c Release -r win-x64
```
