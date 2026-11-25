import Foundation

enum BatteryFailureKind: Sendable {
  case transient
  case disconnected
  case accessDenied
  case unsupported
}

enum BatteryRetry {
  static func read(
    attempt: () -> BatteryScan,
    sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
  ) -> BatteryScan {
    var diagnostics: [String] = []
    for index in 0..<3 {
      let scan = attempt()
      diagnostics.append("Attempt \(index + 1)")
      diagnostics.append(contentsOf: scan.diagnostics)
      if case .reading = scan.outcome {
        return BatteryScan(outcome: scan.outcome, diagnostics: diagnostics)
      }
      if scan.failureKind != .transient || index == 2 {
        return BatteryScan(
          outcome: scan.outcome, diagnostics: diagnostics, failureKind: scan.failureKind)
      }
      sleep(index == 0 ? 0.5 : 1)
    }
    preconditionFailure("A bounded scan must return a result.")
  }
}

struct BatteryPollingState {
  static let staleLifetime: TimeInterval = 900
  static let regularInterval: TimeInterval = 300

  struct Failure {
    let time: Date
    let reason: String
    let diagnostics: [String]
  }

  enum Display: Equatable {
    case fresh(device: String, percent: Int)
    case stale(device: String, percent: Int)
    case unknown
  }

  private(set) var outcome: BatteryOutcome?
  private(set) var lastSuccess: Date?
  private(set) var lastFailure: Failure?
  private var lastReading: (device: String, percent: Int)?
  private var consecutiveFailures = 0

  mutating func record(_ scan: BatteryScan, at time: Date) {
    outcome = scan.outcome
    switch scan.outcome {
    case .reading(let device, let percent):
      lastReading = (device, percent)
      lastSuccess = time
      consecutiveFailures = 0
    case .unavailable(let reason):
      consecutiveFailures = min(consecutiveFailures + 1, 4)
      lastFailure = Failure(
        time: time, reason: reason,
        diagnostics: scan.diagnostics.suffix(64).map { String($0.prefix(300)) })
    }
  }

  var nextPollInterval: TimeInterval {
    switch consecutiveFailures {
    case 0: return Self.regularInterval
    case 1: return 30
    case 2: return 60
    case 3: return 120
    default: return Self.regularInterval
    }
  }

  func display(at time: Date) -> Display {
    guard let lastReading, let lastSuccess,
      time.timeIntervalSince(lastSuccess) < Self.staleLifetime
    else { return .unknown }
    if case .unavailable = outcome {
      return .stale(device: lastReading.device, percent: lastReading.percent)
    }
    return .fresh(device: lastReading.device, percent: lastReading.percent)
  }
}
