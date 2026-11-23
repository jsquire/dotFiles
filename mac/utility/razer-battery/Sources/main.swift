import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments {
case []:
  if LoginStartup.isInstalled && !InstalledApplication.running.isEmpty { exit(0) }
  let application = NSApplication.shared
  application.setActivationPolicy(.accessory)
  let delegate = BatteryAppDelegate()
  application.delegate = delegate
  withExtendedLifetime(delegate) {
    application.run()
  }
case ["--diagnose"]:
  let scan = BatteryReader.read()
  print(scan.diagnostics.joined(separator: "\n"))
  if case .unavailable = scan.outcome {
    exit(1)
  }
case ["--login-status"]:
  print(LoginStartup.statusDescription)
case ["--enable-login"], ["--disable-login"]:
  do {
    let enable = arguments == ["--enable-login"]
    try LoginStartup.setEnabled(enable)
    print(LoginStartup.statusDescription)
    if enable && LoginStartup.statusDescription != "enabled" { exit(1) }
  } catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
  }
case ["--quit"]:
  guard LoginStartup.isInstalled else {
    fputs("Run this command from ~/Applications/RazerBattery.app.\n", stderr)
    exit(1)
  }
  exit(InstalledApplication.quit() ? 0 : 1)
case ["--running"]:
  exit(InstalledApplication.running.isEmpty ? 1 : 0)
case ["--help"], ["-h"]:
  print(
    """
    Razer Battery

    Run without arguments for the menu-bar monitor.
    --diagnose  Print device access and battery-report results, then exit.
    --login-status   Print the macOS login-item status.
    --enable-login   Enable login startup from the installed application.
    --disable-login  Disable login startup before uninstalling.
    --quit           Quit the installed application.
    --running        Exit successfully if the installed application is running.
    --help      Show this help.
    """)
default:
  fputs("Unknown arguments. Use --help for usage.\n", stderr)
  exit(2)
}
