import AppKit
import ServiceManagement

@MainActor
final class BatteryAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let reader: @Sendable () -> BatteryScan
  private var timer: Timer?
  private var refreshItem: NSMenuItem?
  private var summaryItem: NSMenuItem?
  private var updatedItem: NSMenuItem?
  private var loginItem: NSMenuItem?
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

    let timer = Timer(
      timeInterval: 300, target: self, selector: #selector(refresh),
      userInfo: nil, repeats: true)
    self.timer = timer
    timer.tolerance = 30
    RunLoop.main.add(timer, forMode: .common)
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(didWake(_:)), name: NSWorkspace.didWakeNotification,
      object: nil)
    refresh()
  }

  func menuWillOpen(_ menu: NSMenu) {
    updateLoginItem()
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
    guard !isRefreshing else { return }
    isRefreshing = true
    refreshItem?.isEnabled = false

    let reader = reader
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let scan = reader()
      DispatchQueue.main.async { [weak self] in
        self?.apply(scan.outcome)
      }
    }
  }

  private func apply(_ outcome: BatteryOutcome) {
    lastOutcome = outcome
    isRefreshing = false
    refreshItem?.isEnabled = true
    summaryItem?.title = outcome.description
    statusItem?.button?.toolTip = outcome.description
    let updated = DateFormatter.localizedString(
      from: Date(), dateStyle: .none, timeStyle: .short)
    updatedItem?.title = "Updated \(updated)"

    switch outcome {
    case .reading(_, let percent):
      let color: NSColor = percent >= 50 ? .systemGreen : percent >= 20 ? .systemYellow : .systemRed
      statusItem?.button?.attributedTitle = NSAttributedString(
        string: " \(percent)%",
        attributes: [
          .foregroundColor: color,
          .font: NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.systemFontSize, weight: .regular),
        ])
    case .unavailable:
      statusItem?.button?.attributedTitle = NSAttributedString(
        string: " ?", attributes: [.foregroundColor: NSColor.labelColor])
    }
  }

  @objc private func didWake(_ notification: Notification) {
    refresh()
  }

  @objc private func quit() {
    NSApplication.shared.terminate(nil)
  }

  func applicationWillTerminate(_ notification: Notification) {
    timer?.invalidate()
    timer = nil
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    if let statusItem {
      NSStatusBar.system.removeStatusItem(statusItem)
    }
    statusItem = nil
  }
}
