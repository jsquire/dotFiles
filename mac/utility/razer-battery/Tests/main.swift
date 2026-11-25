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

let successfulScan = BatteryScan(
  outcome: .reading(device: "Test mouse", percent: 75), diagnostics: ["Valid report"])
let failedScan = BatteryScan(
  outcome: .unavailable("Temporary timeout"), diagnostics: ["USB get feature timed out"])
var attempts = 0
var delays: [TimeInterval] = []
let recoveredScan = BatteryRetry.read(
  attempt: {
    attempts += 1
    return attempts == 3 ? successfulScan : failedScan
  }, sleep: { delays.append($0) })
check(
  recoveredScan.outcome == successfulScan.outcome && attempts == 3 && delays == [0.5, 1],
  "A transient failure must retry with bounded backoff and recover on a valid report.")
check(
  recoveredScan.diagnostics.filter { $0 == "USB get feature timed out" }.count == 2,
  "Retry diagnostics must retain earlier failed attempts.")
attempts = 0
_ = BatteryRetry.read(
  attempt: {
    attempts += 1
    return failedScan
  }, sleep: { _ in })
check(attempts == 3, "Persistent transient failures must stop after three attempts.")
for kind: BatteryFailureKind in [.disconnected, .accessDenied, .unsupported] {
  attempts = 0
  _ = BatteryRetry.read(
    attempt: {
      attempts += 1
      return BatteryScan(outcome: .unavailable("Unavailable"), diagnostics: [], failureKind: kind)
    }, sleep: { _ in fatalError("Non-transient failures must not sleep and retry.") })
  check(attempts == 1, "Non-transient failures must not retry within a scan.")
}
let start = Date(timeIntervalSince1970: 1_000)
var polling = BatteryPollingState()
polling.record(failedScan, at: start)
check(polling.display(at: start) == .unknown, "No reading must be invented before first success.")
polling.record(successfulScan, at: start)
polling.record(failedScan, at: start.addingTimeInterval(300))
check(
  polling.display(at: start.addingTimeInterval(899)) == .stale(device: "Test mouse", percent: 75),
  "A temporary failure must preserve a visibly stale percentage before expiry.")
check(
  polling.display(at: start.addingTimeInterval(900)) == .unknown,
  "A reading must expire at fifteen minutes from success, not from the latest failure.")
check(polling.lastSuccess == start, "Failed attempts must not advance last-success time.")
check(polling.nextPollInterval == 30, "The first failed scan must schedule fast recovery.")
for expected: TimeInterval in [60, 120, 300, 300] {
  polling.record(failedScan, at: start.addingTimeInterval(600))
  check(polling.nextPollInterval == expected, "Recovery must back off to the regular interval.")
}
polling.record(successfulScan, at: start.addingTimeInterval(901))
check(
  polling.display(at: start.addingTimeInterval(901)) == .fresh(device: "Test mouse", percent: 75)
    && polling.nextPollInterval == 300,
  "Success must clear stale state and restore normal polling.")
check(
  polling.lastFailure?.reason == "Temporary timeout",
  "The last failure must remain inspectable after recovery.")
polling.record(
  BatteryScan(
    outcome: .unavailable("Failure"),
    diagnostics: Array(repeating: String(repeating: "x", count: 400), count: 100)),
  at: start.addingTimeInterval(902))
check(
  polling.lastFailure?.diagnostics.count == 64
    && polling.lastFailure?.diagnostics.allSatisfy { $0.count == 300 } == true,
  "Retained failure details must use bounded memory.")
print("Retry, recovery, freshness, and diagnostic retention tests passed.")

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

  func recover() {
    lock.withLock {
      outcome = .reading(device: "Test mouse", percent: 74)
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
        delegate.statusItem?.button?.attributedTitle.string == " 75%*",
        "A failed refresh must visibly mark the previous percentage stale.")
      check(
        delegate.statusItem?.button?.toolTip?.contains("Test mouse disconnected") == true
          && delegate.statusItem?.button?.toolTip?.contains("Last successful read") == true,
        "A failed refresh must explain the failure and show last-success time.")
      check(
        menu.items.contains(where: { $0.title == "Show Last Failure" && $0.isEnabled }),
        "Failure details must be available from the menu.")
      check(reader.calls == 2, "Overlapping refresh requests must be coalesced.")
      reader.recover()
      DispatchQueue.main.asyncAfter(deadline: .now() + 32) {
        check(
          delegate.statusItem?.button?.attributedTitle.string == " 74%" && reader.calls == 3,
          "The recovery timer must obtain a fresh reading without a manual refresh.")
        check(
          menu.items.contains(where: { $0.title == "Show Last Failure" && $0.isEnabled }),
          "The previous failure must remain available after automatic recovery.")
        delegate.applicationWillTerminate(
          Notification(name: NSApplication.willTerminateNotification))
        check(delegate.statusItem == nil, "Shutdown must remove the menu-bar item.")
        print("Menu-bar automatic recovery integration tests passed.")
        exit(0)
      }
    }
  }
  app.run()
}
