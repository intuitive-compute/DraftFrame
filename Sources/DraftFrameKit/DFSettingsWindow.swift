import AppKit

/// App settings window (⌘,). Holds app-wide defaults: the built-in watchdog
/// toggles (persisted across launches) and the PR automation config applied
/// to worktrees the user hasn't configured individually in the sidebar.
/// Singleton — reuses the same window across show/hide cycles.
final class DFSettingsWindow: NSObject, NSWindowDelegate {
  static let shared = DFSettingsWindow()

  private var window: NSWindow?

  /// Switches keyed by what they control, so external changes (e.g. a
  /// sidebar toggle while this window is open) can be reflected back.
  private var watchdogSwitches: [String: NSSwitch] = [:]
  private var prSwitches: [PRDefaultKey: NSSwitch] = [:]

  private enum PRDefaultKey {
    case autoFix, autoMerge, autoArchive
  }

  private override init() {
    super.init()
    NotificationCenter.default.addObserver(
      self, selector: #selector(syncFromState),
      name: .watchdogsDidChange, object: nil
    )
  }

  func show() {
    if window == nil { buildWindow() }
    syncFromState()
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  // MARK: - Window

  private func buildWindow() {
    let win = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 480, height: 100),
      styleMask: [.titled, .closable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    win.title = "Settings"
    win.titlebarAppearsTransparent = true
    win.titleVisibility = .hidden
    win.appearance = NSAppearance(named: .darkAqua)
    win.backgroundColor = Theme.bg
    win.isReleasedWhenClosed = false
    win.delegate = self

    let container = NSView()
    container.wantsLayer = true
    container.layer?.backgroundColor = Theme.bg.cgColor
    win.contentView = container

    let titleLabel = NSTextField(labelWithString: "SETTINGS")
    titleLabel.font = Theme.mono(14, weight: .medium)
    titleLabel.textColor = Theme.text1

    let stack = NSStackView(views: [titleLabel])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.setCustomSpacing(16, after: titleLabel)
    stack.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(stack)

    addSection(
      to: stack,
      title: "Watchdog defaults",
      subtitle: "Apply to all sessions and persist across launches."
    )
    addSwitchRow(
      to: stack,
      title: WatchdogManager.autoAcceptName,
      detail: "Types \"y\" whenever a session needs attention.",
      switchFor: .watchdog(WatchdogManager.autoAcceptName)
    )
    addSwitchRow(
      to: stack,
      title: WatchdogManager.notifyOnFinishName,
      detail: "Sends a macOS notification when a session finishes working.",
      switchFor: .watchdog(WatchdogManager.notifyOnFinishName)
    )

    addSection(
      to: stack,
      title: "PR automation defaults",
      subtitle: "Seed every session's PR actions. Toggling a row in the sidebar "
        + "overrides these for that worktree."
    )
    addSwitchRow(
      to: stack,
      title: "Auto-fix CI",
      detail: "Asks the agent to investigate and fix failing CI checks.",
      switchFor: .pr(.autoFix)
    )
    addSwitchRow(
      to: stack,
      title: "Auto-merge PR",
      detail: "Queues a squash merge once the PR's checks pass.",
      switchFor: .pr(.autoMerge)
    )
    addSwitchRow(
      to: stack,
      title: "Auto-archive PR",
      detail: "Closes the session and removes its worktree after the PR is merged or closed.",
      switchFor: .pr(.autoArchive)
    )

    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 36),
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
      stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
      container.widthAnchor.constraint(equalToConstant: 480),
    ])
    win.setContentSize(container.fittingSize)
    win.center()

    // Escape key closes the window
    let escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak win] event in
      if event.keyCode == 53, win?.isKeyWindow == true {
        win?.close()
        return nil
      }
      return event
    }
    // Store so it lives as long as the window
    objc_setAssociatedObject(win, "escMonitor", escMonitor, .OBJC_ASSOCIATION_RETAIN)

    self.window = win
  }

  // MARK: - Row building

  private enum SwitchTarget {
    case watchdog(String)
    case pr(PRDefaultKey)
  }

  private func addSection(to stack: NSStackView, title: String, subtitle: String) {
    let label = NSTextField(labelWithString: title.uppercased())
    label.font = Theme.mono(11, weight: .medium)
    label.textColor = Theme.text3

    let sub = NSTextField(wrappingLabelWithString: subtitle)
    sub.font = Theme.mono(10)
    sub.textColor = Theme.text3

    stack.setCustomSpacing(18, after: stack.arrangedSubviews.last ?? label)
    stack.addArrangedSubview(label)
    stack.setCustomSpacing(2, after: label)
    stack.addArrangedSubview(sub)
    sub.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
  }

  private func addSwitchRow(
    to stack: NSStackView, title: String, detail: String, switchFor target: SwitchTarget
  ) {
    let row = NSView()
    row.wantsLayer = true
    row.layer?.backgroundColor = Theme.surface1.cgColor
    row.layer?.cornerRadius = 6

    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.font = Theme.mono(13)
    titleLabel.textColor = Theme.text1

    let detailLabel = NSTextField(wrappingLabelWithString: detail)
    detailLabel.font = Theme.mono(10)
    detailLabel.textColor = Theme.text3

    let toggle = NSSwitch()
    toggle.controlSize = .small
    toggle.target = self
    switch target {
    case .watchdog(let name):
      toggle.action = #selector(watchdogSwitchChanged(_:))
      watchdogSwitches[name] = toggle
    case .pr(let key):
      toggle.action = #selector(prSwitchChanged(_:))
      prSwitches[key] = toggle
    }

    for v in [titleLabel, detailLabel, toggle] {
      v.translatesAutoresizingMaskIntoConstraints = false
      row.addSubview(v)
    }
    NSLayoutConstraint.activate([
      titleLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 8),
      titleLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
      detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
      detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      detailLabel.trailingAnchor.constraint(equalTo: toggle.leadingAnchor, constant: -12),
      detailLabel.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -8),
      toggle.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
      toggle.centerYAnchor.constraint(equalTo: row.centerYAnchor),
    ])

    stack.addArrangedSubview(row)
    row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
  }

  // MARK: - State sync

  /// Push current app state into the switches (on open, and whenever
  /// watchdogs change elsewhere while the window is up).
  @objc private func syncFromState() {
    guard window != nil else { return }
    watchdogSwitches[WatchdogManager.autoAcceptName]?.state =
      WatchdogManager.shared.isEnabled(
        builtinName: WatchdogManager.autoAcceptName, fallback: false) ? .on : .off
    watchdogSwitches[WatchdogManager.notifyOnFinishName]?.state =
      WatchdogManager.shared.isEnabled(
        builtinName: WatchdogManager.notifyOnFinishName, fallback: true) ? .on : .off

    let config = AppSettings.defaultPRConfig
    prSwitches[.autoFix]?.state = config.autoFix ? .on : .off
    prSwitches[.autoMerge]?.state = config.autoMerge ? .on : .off
    prSwitches[.autoArchive]?.state = config.autoArchive ? .on : .off
  }

  @objc private func watchdogSwitchChanged(_ sender: NSSwitch) {
    guard let name = watchdogSwitches.first(where: { $0.value === sender })?.key else { return }
    WatchdogManager.shared.setEnabled(sender.state == .on, builtinName: name)
  }

  @objc private func prSwitchChanged(_ sender: NSSwitch) {
    guard let key = prSwitches.first(where: { $0.value === sender })?.key else { return }
    var config = AppSettings.defaultPRConfig
    switch key {
    case .autoFix: config.autoFix = sender.state == .on
    case .autoMerge: config.autoMerge = sender.state == .on
    case .autoArchive: config.autoArchive = sender.state == .on
    }
    AppSettings.defaultPRConfig = config
    // Sidebar PR action rows read through the defaults fallback — refresh them.
    NotificationCenter.default.post(name: .prStatusDidChange, object: nil)
  }
}
