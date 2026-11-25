# Razer Battery

Native macOS menu-bar battery indicator, based on the device table and battery request in `windows/utility/razer-taskbar-battery`. This version uses Swift, AppKit, IOKit, and a small Objective-C USB control-transfer bridge instead of Windows Forms and Windows DLLs. It compiles ahead of time into a standalone executable with no .NET runtime, Synapse, third-party packages, or background service.

The menu bar shows the battery percentage in green, yellow, or red. It polls every five minutes and after wake, with timer tolerance to allow macOS to coalesce background work. Choose **Refresh now** for an immediate reading or **Quit** to exit. Device communication runs off the UI thread.

Transient failures get up to three complete scan attempts, with half-second and one-second delays between attempts. Detected disconnection, access denial, and unknown product IDs do not retry within a scan. After an unsuccessful scan, automatic recovery polls back off through 30, 60, and 120 seconds, then return to five-minute intervals until a reading succeeds.

A failed scan preserves the last successful percentage in a subdued color with an asterisk, such as `75%*`. The menu and tooltip label it **stale**, show the failure reason, and retain the actual last-success time. The reading expires to `?` fifteen minutes after its last success, including while a poll is still running. Before any successful reading, the display is `?`. Recovery removes the stale marker and restores normal polling. Cached readings are held only in memory and are not restored after restarting.

**Show Last Failure** retains the latest unsuccessful scan's time, reason, and bounded diagnostic details, including its retry attempts. These remain inspectable after recovery, without continuous logging or writing device data to disk.

## Requirements

macOS 14 or later and Xcode Command Line Tools are required to build. The build uses the installed toolchain and targets the current machine's architecture.

Battery requests use USB control transfers on interface 0, with HID feature reports as a fallback. Neither transport requests exclusive device capture or seizure. Connect the USB receiver or device. Bluetooth battery reporting is not implemented. The device table starts from the Windows utility, with mouse product IDs and transactions corrected against OpenRazer. Inclusion is not a guarantee that every model exposes compatible reports on macOS. No Synapse logs are read.

The native ARM64 build was verified with a Basilisk V3 Pro both wired (`PID_00AA`) and through its wireless USB receiver (`PID_00AB`). The installed app returned a valid battery reading through the receiver with no wired mouse connected. Other device models remain unverified.

## Install and launch at login

From this directory:

```bash
bash ./install.sh --enable-login
```

The installer builds and verifies a locally ad-hoc-signed app, installs it at `$HOME/Applications/RazerBattery.app`, and opens that copy. The Finder display name is **Razer Battery**. The installed bundle is independent of the repository. No administrator access, package downloads, custom LaunchAgent, or privileged background service is needed.

**Launch at Login** in the app menu uses Apple's `SMAppService.mainApp`. The menu reflects macOS registration status rather than a separate preference. A mixed checkmark means approval is required; choose it to open Login Items settings. The app does not silently re-enable startup after you disable it. Startup registration is restricted to the installed, non-symlinked bundle at the path above.

Run `bash ./install.sh` to update without opting into startup. Updates preserve an already-enabled login item and do not enable one that is disabled or awaiting approval. The installer refuses an unrelated or symlinked destination, builds before stopping the old version, and keeps the previous bundle until replacement is verified. A failed replacement restores the previous version. Login registration or launch errors after a verified replacement are reported without deleting the newly installed app. Install and uninstall share a lock to prevent concurrent replacements.

To uninstall:

```bash
bash ./uninstall.sh
```

The uninstaller unregisters login startup and quits the installed app before removing only its verified bundle. It stops rather than removing the app if unregistering or quitting fails. Installation and removal are not part of the workstation bootstrap.

## Build without installing

```bash
bash ./build.sh
open "./dist/RazerBattery.app"
```

An optional output directory can be supplied to `build.sh`. Only the final app bundle is retained. Compiler caches and object files use a unique staging directory that is removed on success, failure, or handled interruption. Tests use the same isolation and retain no executable. Default output directories and narrowly scoped generated artifacts are ignored by Git. Abrupt termination such as `SIGKILL` can prevent cleanup; do not delete arbitrary paths when cleaning up an interrupted invocation.

## Diagnose detection

```bash
"$HOME/Applications/RazerBattery.app/Contents/MacOS/razer-battery" --diagnose
```

Diagnostics print the Razer product IDs, HID transport, report failures, and battery result to the terminal, without device serial numbers or persistent log files. Exit code `0` means a valid battery reading; `1` means no reading; `2` means invalid arguments.

The installed executable also supports `--login-status`, `--enable-login`, `--disable-login`, `--running`, and `--quit` for lifecycle validation and scripting. `--running` exits `0` when the installed GUI is running and `1` otherwise. Quit does not unregister login startup.

If device access is denied, check **System Settings > Privacy & Security > Input Monitoring** for the application or terminal running the diagnostic. The utility does not request permission to capture input, seize devices, install a driver, or bypass access controls.

## Tests

```bash
bash ./test.sh
bash ./test.sh ./dist/tests --ui
```

Protocol tests cover request construction, battery scaling including 0%, truncated reports, stale responses, failed or mismatched commands, and corrupt checksums. Recovery tests cover bounded retries, non-transient failures, stale-reading expiry, recovery backoff, and bounded diagnostic retention. The optional UI test runs the application lifecycle with a temporary menu-bar item, verifies stale rendering, failure details, coalescing overlapping requests, and an actual automatic recovery timer, then removes the item. It takes about 35 seconds, uses a simulated battery, and does not access devices.

## Protocol references

The USB control-transfer format and device-specific battery transaction IDs were checked against OpenRazer's `driver/razercommon.c` and `driver/razermouse_driver.c`. The macOS transport uses the documented `IOUSBHostObject` and `IOHIDDevice` APIs from the installed macOS SDK. Only battery queries are sent; device settings and input events are not changed.

To add a product ID, update `RazerProduct.products` in `Sources/BatteryProtocol.swift` and verify its battery-report format and transaction ID on the actual device.
