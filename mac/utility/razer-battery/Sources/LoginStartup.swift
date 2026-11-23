import AppKit
import ServiceManagement

@MainActor
enum LoginStartup {
  static var installedURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Applications/RazerBattery.app")
  }

  static var isInstalled: Bool {
    Bundle.main.bundleIdentifier == "com.dotfiles.razer-battery"
      && Bundle.main.bundleURL.standardizedFileURL == installedURL.standardizedFileURL
      && Bundle.main.bundleURL.resolvingSymlinksInPath() == installedURL.standardizedFileURL
  }

  static var status: SMAppService.Status { SMAppService.mainApp.status }

  static var statusDescription: String {
    switch status {
    case .enabled: return "enabled"
    case .notRegistered: return "not-registered"
    case .requiresApproval: return "requires-approval"
    case .notFound: return "not-found"
    @unknown default: return "unknown"
    }
  }

  static func setEnabled(_ enabled: Bool) throws {
    guard isInstalled else {
      throw NSError(
        domain: "RazerBattery", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Install in ~/Applications/RazerBattery.app first."])
    }
    if enabled {
      if status != .enabled { try SMAppService.mainApp.register() }
    } else if status != .notRegistered {
      try SMAppService.mainApp.unregister()
    }
  }
}

@MainActor
enum InstalledApplication {
  static var running: [NSRunningApplication] {
    NSRunningApplication.runningApplications(
      withBundleIdentifier: "com.dotfiles.razer-battery"
    ).filter {
      $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        && $0.bundleURL?.standardizedFileURL == LoginStartup.installedURL.standardizedFileURL
    }
  }

  static func quit() -> Bool {
    let applications = running
    for application in applications {
      guard application.terminate() else { return false }
    }
    let deadline = Date().addingTimeInterval(10)
    while applications.contains(where: { !$0.isTerminated }) && Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    return applications.allSatisfy(\.isTerminated)
  }
}
