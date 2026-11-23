# Razer Battery Tray

Tiny Windows tray indicator for supported Razer wireless devices.

It polls the mouse every 5 minutes using the same battery request shape used by OpenRazer-derived Windows tools, then draws the percentage directly into the tray icon. It does not run Electron, Razer Synapse, a browser runtime, or a background service.

## Requirements

.NET 8 SDK is required to build or run from source. The published framework-dependent executable requires the .NET 8 Desktop Runtime.

Razer Synapse is not required. The utility reads the battery directly from the device and uses Synapse logs only as a fallback when they are available.

## Run

From `windows\utility\razer-taskbar-battery`:

```powershell
dotnet run --project .\RazerBatteryTray.csproj
```

Right-click the tray icon for `Refresh now` or `Quit`.

## Diagnose detection

```powershell
.\publish-light\RazerBatteryTray.exe --diagnose
```

This writes `razer-battery-diagnostics.txt` next to the executable with the Razer HID paths found and the battery report result for each one.

## Publish a small local copy

```powershell
dotnet publish .\RazerBatteryTray.csproj -c Release --self-contained false -p:PublishSingleFile=false -o .\publish-light
```

The executable will be:

```text
publish-light\RazerBatteryTray.exe
```

## Supported product IDs

The app currently includes the product IDs and transaction IDs used by the archived `Tekk-Know/RazerBatteryTaskbar` project, which credits OpenRazer and `hsutungyu/razer-mouse-battery-windows`.

If your mouse is not detected, add its `VID_1532&PID_XXXX` value to the `Products` dictionary in `Program.cs`.
