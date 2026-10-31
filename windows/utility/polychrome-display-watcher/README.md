# Polychrome Display Watcher

A hidden Windows utility that restores an ASRock Phantom Gaming LCD after the interactive display
wakes. Polychrome DISPLAY 1.2.7 can leave the physical LCD frozen even though its preview and device
connection remain active. Restarting Polychrome restores rendering, so this watcher automates that
known recovery.

The watcher displays a distinct security icon in the Windows notification area. Right-click or left-click
the icon to view status, restart Polychrome manually, open the watcher log, or exit the watcher.
The source asset is stored as `src\PolychromeDisplayWatcher\assets\security.ico`, published beside
the executable, and falls back to the shared Windows application icon if it cannot be loaded.

## Behavior

The watcher registers a message-only window for `GUID_SESSION_DISPLAY_STATUS`. At logon, it schedules
one initial repair restart because Windows reports the current state as `On` without an `Off` to `On`
transition. It also reacts to each later confirmed `Off` to `On` transition. After a 10-second
stabilization delay, it terminates the complete Polychrome Electron process tree and relaunches:

```text
C:\Program Files\Polychrome DISPLAY\Polychrome DISPLAY.exe --startupWithMinimize
```

A 60-second cooldown prevents duplicate restart cycles. If the display turns off during the delay,
the pending restart is canceled. If Explorer's notification area is not ready at logon, tray icon
registration is retried every two seconds for up to one minute.

The watcher changes only Polychrome's process lifetime. It does not change USB power settings,
firmware, themes, Windows display configuration, or the existing ASRock startup tasks. Restarting
Polychrome forcibly terminates its processes, so unsaved theme edits would be lost if the display
wakes while the editor is open.

## Install

Run the installer from an elevated PowerShell session:

```powershell
cd << REPO ROOT >>\dotFiles\windows\utility\polychrome-display-watcher
.\Install.ps1
```

The installer:

1. Verifies the committed NativeAOT executable against its SHA-256 file.
2. Copies it to `%LOCALAPPDATA%\polychrome-display-watcher`.
3. Registers **Polychrome Display Watcher** as a scheduled task for the current user.
4. Configures the task to run at logon with highest privileges and no execution time limit.
5. Starts the task immediately.

Highest privileges are required because Polychrome DISPLAY is already launched at that level. The
installer does not modify the existing `StartASRock` or `StartASRock_admin` tasks.

## Verify

Confirm the task and process are running:

```powershell
Get-ScheduledTask -TaskName 'Polychrome Display Watcher'
Get-Process polychrome-display-watcher
```

Confirm that the security icon is present in the Windows notification area. It may be under the
notification-area overflow menu. At logon, the log should record the initial restart schedule,
Polychrome restart, and new process ID.

The active log is:

```text
%LOCALAPPDATA%\polychrome-display-watcher\logs\watcher.log
```

To test the workaround, allow the displays to turn fully off and wake them normally. The log should
record `Off`, `On`, the delayed restart, and the new Polychrome process ID. Confirm that the cooler
LCD resumes animation and live sensor updates.

## Configuration

Defaults can be overridden with user or system environment variables before the scheduled task
starts.

| Variable | Default | Purpose |
|---|---|---|
| `POLYCHROME_WATCHER_EXECUTABLE_PATH` | `%ProgramFiles%\Polychrome DISPLAY\Polychrome DISPLAY.exe` | Polychrome executable to relaunch |
| `POLYCHROME_WATCHER_RESTART_DELAY_SECONDS` | `10` | Stabilization delay after display wake |
| `POLYCHROME_WATCHER_COOLDOWN_SECONDS` | `60` | Minimum interval between restart attempts |
| `POLYCHROME_WATCHER_LOG_PATH` | `%LOCALAPPDATA%\polychrome-display-watcher\logs\watcher.log` | Diagnostic log destination |

The log rolls at 1 MiB and retains one previous file as `watcher.log.1`.

## Uninstall

Run the removal script from an elevated PowerShell session:

```powershell
cd D:\personal\dotFiles\windows\utility\polychrome-display-watcher
.\Uninstall.ps1
```

The script removes only the watcher scheduled task and
`%LOCALAPPDATA%\polychrome-display-watcher`. It does not uninstall Polychrome DISPLAY or alter
ASRock's tasks.

## Build and test

The project targets .NET 10 and uses NUnit.

```powershell
dotnet restore
dotnet build --no-restore -c Release
dotnet test --no-build -c Release
```

Create the self-contained Windows x64 executable from a Visual Studio Developer PowerShell session:

```powershell
dotnet publish .\src\PolychromeDisplayWatcher\PolychromeDisplayWatcher.csproj -c Release -r win-x64
```

NativeAOT publishing requires the MSVC x64 toolchain. The publish target copies
`polychrome-display-watcher.exe` into `dist` and refreshes the adjacent SHA-256 file.

## Project structure

| Path | Purpose |
|---|---|
| `src\PolychromeDisplayWatcher` | Native message loop, transition tracking, logging, and process restart |
| `tests` | NUnit tests for transition and configuration behavior |
| `dist` | Prebuilt Windows x64 executable, checksum, and tray icon |
| `Install.ps1` | Verified deployment and scheduled-task registration |
| `Uninstall.ps1` | Scheduled-task and deployed-file removal |
