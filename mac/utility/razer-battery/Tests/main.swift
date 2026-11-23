import AppKit

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() {
    fatalError(message)
  }
}

func reply(battery: UInt8, transactionID: UInt8 = 0x1f) -> [UInt8] {
  var report = BatteryProtocol.request(transactionID: transactionID)
  report[0] = 0x02
  report[9] = battery
  report[88] = BatteryProtocol.checksum(report)
  return report
}

let request = BatteryProtocol.request(transactionID: 0x1f)
check(
  request[1] == 0x1f && request[5...7] == [0x02, 0x07, 0x80],
  "Battery request must select the battery command and transaction.")
check(request[88] == 0x85, "Battery request must carry the protocol checksum.")

for transactionID: UInt8 in [0x1f, 0x3f, 0xff] {
  for (raw, expected) in [(UInt8(0), 0), (128, 50), (255, 100)] {
    check(
      BatteryProtocol.percent(
        from: reply(battery: raw, transactionID: transactionID),
        transactionID: transactionID) == expected,
      "Battery scaling must include an empty battery for each supported transaction.")
  }
}
check(
  BatteryProtocol.percent(from: [0x02], transactionID: 0x1f) == nil,
  "Truncated responses must not be indexed or accepted.")
check(
  BatteryProtocol.percent(
    from: reply(battery: 200, transactionID: 0x3f),
    transactionID: 0x1f) == nil, "A stale transaction must not be accepted.")
for index in [0, 2, 3, 4, 5, 6, 7] {
  var invalid = reply(battery: 200)
  invalid[index] ^= 0x01
  invalid[88] = BatteryProtocol.checksum(invalid)
  check(
    BatteryProtocol.percent(from: invalid, transactionID: 0x1f) == nil,
    "A response for a failed or different command must not be accepted.")
}
var corrupt = reply(battery: 200)
corrupt[9] ^= 0x01
check(
  BatteryProtocol.percent(from: corrupt, transactionID: 0x1f) == nil,
  "Corrupt battery values must fail the checksum.")
print("Battery protocol tests passed.")

check(!LoginStartup.isInstalled, "A test executable must not qualify as the installed app.")
do {
  try LoginStartup.setEnabled(true)
  fatalError("A build or test executable must not be allowed to register login startup.")
} catch {
  check(
    error.localizedDescription.contains("Install in ~/Applications/RazerBattery.app first."),
    "Uninstalled startup registration must report the required installation path.")
}
print("Login registration guard tests passed.")

// Every access to mutable state is protected by the same lock.
final class SimulatedReader: @unchecked Sendable {
  private let lock = NSLock()
  private var outcome = BatteryOutcome.reading(device: "Test mouse", percent: 75)
  private var readCount = 0

  func read() -> BatteryScan {
    lock.withLock {
      readCount += 1
      return BatteryScan(outcome: outcome, diagnostics: [])
    }
  }

  func disconnect() {
    lock.withLock {
      outcome = .unavailable("Test mouse disconnected")
    }
  }

  var calls: Int {
    lock.withLock { readCount }
  }
}

if CommandLine.arguments.contains("--ui") {
  let app = NSApplication.shared
  app.setActivationPolicy(.accessory)
  let reader = SimulatedReader()
  let delegate = BatteryAppDelegate { reader.read() }
  app.delegate = delegate
  DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
    check(
      delegate.statusItem?.button?.attributedTitle.string == " 75%",
      "Application launch must display the asynchronous battery reading.")
    guard let menu = delegate.statusItem?.menu,
      let index = menu.items.firstIndex(where: { $0.title == "Refresh now" })
    else {
      fatalError("The refresh action must be present.")
    }
    check(menu.items[index].isEnabled, "Refresh must be enabled when polling completes.")
    check(
      menu.items.contains(where: { $0.title == "Launch at Login" && !$0.isEnabled }),
      "A development or test executable must show a disabled login-startup control.")
    reader.disconnect()
    menu.performActionForItem(at: index)
    delegate.refresh()
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
      check(
        delegate.statusItem?.button?.attributedTitle.string == " ?",
        "A failed refresh must clear the previous battery percentage.")
      check(
        delegate.statusItem?.button?.toolTip == "Test mouse disconnected",
        "A failed refresh must explain why no battery reading is available.")
      check(reader.calls == 2, "Overlapping refresh requests must be coalesced.")
      delegate.applicationWillTerminate(
        Notification(name: NSApplication.willTerminateNotification))
      check(delegate.statusItem == nil, "Shutdown must remove the menu-bar item.")
      print("Menu-bar integration tests passed.")
      exit(0)
    }
  }
  app.run()
}
