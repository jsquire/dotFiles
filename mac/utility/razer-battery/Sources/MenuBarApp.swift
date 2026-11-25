import AppKit
import ServiceManagement

@MainActor
final class BatteryAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let reader: @Sendable () -> BatteryScan
  private var timer: Timer?
  private var expiryTimer: Timer?
  private var refreshItem: NSMenuItem?
  private var summaryItem: NSMenuItem?
  private var updatedItem: NSMenuItem?
  private var loginItem: NSMenuItem?
  private var failureItem: NSMenuItem?
  private var polling = BatteryPollingState()
  private var isTerminating = false
  private var isRefreshing = false
  private(set) var statusItem: NSStatusItem?
  private(set) var lastOutcome: BatteryOutcome?

  init(reader: @escaping @Sendable () -> BatteryScan = { BatteryReader.read() }) {
    self.reader = reader
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem = item
    item.button?.font = NSFont.monospacedDigitSystemFont(
      ofSize: NSFont.systemFontSize, weight: .regular)
    item.button?.imagePosition = .imageLeading
    item.button?.image = NSImage(
      systemSymbolName: "battery.100percent", accessibilityDescription: "Razer battery")
    item.button?.title = " ?"
    item.button?.toolTip = "Razer battery: starting"

    let menu = NSMenu()
    menu.delegate = self
    menu.autoenablesItems = false
    summaryItem = menu.addItem(withTitle: "Reading battery...", action: nil, keyEquivalent: "")
    summaryItem?.isEnabled = false
    updatedItem = menu.addItem(withTitle: "Not yet updated", action: nil, keyEquivalent: "")
    updatedItem?.isEnabled = false
    failureItem = menu.addItem(
      withTitle: "Show Last Failure", action: #selector(showLastFailure), keyEquivalent: "")
    failureItem?.target = self
    failureItem?.isEnabled = false
    menu.addItem(.separator())
    refreshItem = menu.addItem(
      withTitle: "Refresh now", action: #selector(refresh), keyEquivalent: "r")
    refreshItem?.target = self
    loginItem = menu.addItem(
      withTitle: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
    loginItem?.target = self
    updateLoginItem()
    let quitItem = menu.addItem(
      withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
    quitItem.target = self
    item.menu = menu

    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(didWake(_:)), name: NSWorkspace.didWakeNotification,
      object: nil)
    refresh()
  }

  func menuWillOpen(_ menu: NSMenu) {
    updateLoginItem()
    render()
  }

  @objc private func showLastFailure() {
    guard let failure = polling.lastFailure else { return }
    let alert = NSAlert()
    alert.messageText = "Last Battery Read Failure"
    alert.informativeText = [
      DateFormatter.localizedString(from: failure.time, dateStyle: .short, timeStyle: .medium),
      failure.reason,
      failure.diagnostics.joined(separator: "\n"),
    ].joined(separator: "\n\n")
    alert.runModal()
  }

  private func updateLoginItem() {
    loginItem?.isEnabled = LoginStartup.isInstalled
    loginItem?.state =
      LoginStartup.status == .enabled
      ? .on : LoginStartup.status == .requiresApproval ? .mixed : .off
    loginItem?.toolTip =
      LoginStartup.isInstalled
      ? "Manage automatic launch at login in macOS."
      : "Install in ~/Applications/RazerBattery.app to enable login startup."
  }

  @objc private func toggleLogin() {
    do {
      if LoginStartup.status == .requiresApproval {
        SMAppService.openSystemSettingsLoginItems()
      } else {
        try LoginStartup.setEnabled(LoginStartup.status != .enabled)
      }
      updateLoginItem()
    } catch {
      let alert = NSAlert(error: error)
      alert.runModal()
    }
  }

  @objc func refresh() {
    guard !isRefreshing && !isTerminating else { return }
    timer?.invalidate()
    isRefreshing = true
    refreshItem?.isEnabled = false

    let reader = reader
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let scan = reader()
      DispatchQueue.main.async { [weak self] in
        self?.apply(scan)
      }
    }
  }

  private func apply(_ scan: BatteryScan) {
    guard !isTerminating else { return }
    lastOutcome = scan.outcome
    polling.record(scan, at: Date())
    isRefreshing = false
    refreshItem?.isEnabled = true
    failureItem?.isEnabled = polling.lastFailure != nil
    render()
    schedulePoll()
    expiryTimer?.invalidate()
    if let success = polling.lastSuccess {
      let remaining = BatteryPollingState.staleLifetime - Date().timeIntervalSince(success)
      if remaining > 0 {
        let expiry = Timer(
          timeInterval: remaining, target: self, selector: #selector(expireReading),
          userInfo: nil, repeats: false)
        expiryTimer = expiry
        RunLoop.main.add(expiry, forMode: .common)
      }
    }
  }

  private func schedulePoll() {
    timer?.invalidate()
    let interval = polling.nextPollInterval
    let timer = Timer(
      timeInterval: interval, target: self, selector: #selector(refresh),
      userInfo: nil, repeats: false)
    timer.tolerance = interval == BatteryPollingState.regularInterval ? 30 : 1
    self.timer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  @objc private func expireReading() {
    render()
  }

  private func render() {
    let display = polling.display(at: Date())
    var summary = polling.outcome?.description ?? "Reading battery..."
    if let success = polling.lastSuccess {
      let time = DateFormatter.localizedString(
        from: success, dateStyle: .short, timeStyle: .medium)
      updatedItem?.title = "Last successful read \(time)"
    } else {
      updatedItem?.title = "No successful reading yet"
    }
    switch display {
    case .fresh(let device, let percent):
      summary = "\(device): \(percent)%"
      let color: NSColor = percent >= 50 ? .systemGreen : percent >= 20 ? .systemYellow : .systemRed
      statusItem?.button?.attributedTitle = NSAttributedString(
        string: " \(percent)%",
        attributes: [
          .foregroundColor: color,
          .font: NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.systemFontSize, weight: .regular),
        ])
    case .stale(let device, let percent):
      summary = "\(device): \(percent)% (stale)\n\(summary)"
      statusItem?.button?.attributedTitle = NSAttributedString(
        string: " \(percent)%*",
        attributes: [
          .foregroundColor: NSColor.secondaryLabelColor,
          .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
        ])
    case .unknown:
      if case .reading = polling.outcome { summary = "Last battery reading has expired." }
      statusItem?.button?.attributedTitle = NSAttributedString(
        string: " ?", attributes: [.foregroundColor: NSColor.labelColor])
    }
    summaryItem?.title = summary.replacingOccurrences(of: "\n", with: " ")
    statusItem?.button?.toolTip = "\(summary)\n\(updatedItem?.title ?? "")"
  }

  @objc private func didWake(_ notification: Notification) {
    refresh()
  }

  @objc private func quit() {
    NSApplication.shared.terminate(nil)
  }

  func applicationWillTerminate(_ notification: Notification) {
    isTerminating = true
    timer?.invalidate()
    timer = nil
    expiryTimer?.invalidate()
    expiryTimer = nil
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    if let statusItem {
      NSStatusBar.system.removeStatusItem(statusItem)
    }
    statusItem = nil
  }
}
