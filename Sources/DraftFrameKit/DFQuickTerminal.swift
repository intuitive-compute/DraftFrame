import AppKit
import SwiftTerm

/// Floating quick-terminal window. Toggled with Cmd+` (backtick). Each
/// session owns its own set of tabs, and each tab owns its own tree of
/// terminal splits — switching sessions swaps in that session's own
/// tabs/splits, switching tabs/panes swaps which part of that tree is
/// visible/focused. Shells persist across show/hide, tab switches, and
/// session switches, so scrollback and in-flight commands survive all of
/// that until the shell itself exits.
final class DFQuickTerminal {
  static let shared = DFQuickTerminal()

  private var window: NSWindow?
  private var container: NSView?
  private var sessionStates: [UUID: QTSessionState] = [:]
  private var currentlyInstalledSessionID: UUID?
  private var clickMonitor: Any?

  /// Wrapper views for the panes currently on screen, keyed by pane id —
  /// rebuilt every time the visible tab's tree is rebuilt. Used to toggle the
  /// focus-highlight border without a full rebuild.
  private var paneWrappers: [UUID: NSView] = [:]

  /// In-flight loading state for panes whose shell is still booting. Present
  /// only while a fresh shell renders its banner and runs the `cd && clear`
  /// bootstrap; cleared once the shell settles.
  private var loads: [UUID: LoadState] = [:]

  /// Tracks one booting shell: the overlay shown over it, the timers that
  /// decide when it's settled, and the rolling scan for the ready marker.
  private final class LoadState {
    let overlay: TerminalLoadingOverlay
    let terminalView: ClaudeTerminalView
    var settleTimer: Timer?
    var maxTimer: Timer?
    /// True once the invisible ready marker has been observed in the PTY
    /// stream — the shell has finished sourcing rc files and run the
    /// bootstrap. Quiescence only counts toward "ready" after this.
    var sawMarker = false
    /// Rolling window of recent printable bytes, scanned for the marker.
    var scanBuffer = ""
    init(overlay: TerminalLoadingOverlay, terminalView: ClaudeTerminalView) {
      self.overlay = overlay
      self.terminalView = terminalView
    }
  }

  /// Container inset matching the transparent titlebar so content doesn't
  /// render behind the traffic lights.
  private static let titlebarInset: CGFloat = 28

  /// Height of the per-session tab strip.
  private static let tabBarHeight: CGFloat = 24

  /// Token emitted (invisibly, inside an OSC sequence) by the bootstrap once
  /// the shell is ready. Split across printf's format and argument so the
  /// literal token never appears in the shell's echo of the typed command —
  /// only the actual emission matches.
  private static let readyToken = "DFQT_READY"

  /// Once the marker is seen, how long the prompt must stay quiet before we
  /// reveal — just long enough to let the fresh prompt paint.
  private static let settleQuiet: TimeInterval = 0.15

  /// Hard ceiling on the loading overlay so a shell that never emits the
  /// marker (exotic shell, wedged rc file) still reveals itself.
  private static let maxLoad: TimeInterval = 6.0

  private init() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(activeSessionDidChange),
      name: .activeSessionDidChange,
      object: nil)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(sessionsDidChange),
      name: .sessionsDidChange,
      object: nil)
  }

  /// Whether the popup terminal is currently the key window — used to scope
  /// its tab/split shortcuts so they only fire while it's focused.
  var isFocused: Bool {
    window?.isKeyWindow == true
  }

  /// Show the quick terminal if hidden, hide it if currently visible and key.
  /// If visible but not key (user clicked the main window), re-focus it
  /// instead of hiding — avoids requiring a double Cmd+` to get it back.
  func toggle() {
    if let win = window, win.isVisible {
      if win.isKeyWindow {
        win.orderOut(nil)
      } else {
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        focusInstalledContent()
      }
    } else {
      show()
    }
  }

  func show() {
    if window == nil {
      buildWindow()
    }
    guard let win = window else { return }
    guard let active = SessionManager.shared.activeSession else {
      // No session to attach to — quick terminal is session-scoped.
      return
    }
    install(for: active)
    positionAtTop(of: win)
    win.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    focusInstalledContent()
  }

  func hide() {
    window?.orderOut(nil)
  }

  // MARK: - Window setup

  private func buildWindow() {
    let contentRect = NSRect(x: 0, y: 0, width: 900, height: 340)
    let win = NSWindow(
      contentRect: contentRect,
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    win.title = "Quick Terminal"
    win.titlebarAppearsTransparent = true
    win.titleVisibility = .hidden
    win.backgroundColor = Theme.bg
    win.isMovableByWindowBackground = false
    win.hidesOnDeactivate = true
    win.level = .normal
    win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    win.isReleasedWhenClosed = false
    win.minSize = NSSize(width: 500, height: 200)

    let container = NSView(frame: contentRect)
    container.wantsLayer = true
    container.layer?.backgroundColor = Theme.bg.cgColor
    win.contentView = container

    self.container = container
    self.window = win
    installClickTracking()
  }

  /// Track which pane the user last clicked, independent of (and in
  /// addition to) AppKit's own click-to-focus promotion. `paneWrapper`'s
  /// terminal is inset a couple of points inside each wrapper, and with
  /// nested `NSSplitView`s in between, relying solely on implicit
  /// first-responder promotion left our own bookkeeping (which pane is
  /// "focused" for the border highlight and for Option+W/split targeting)
  /// stale whenever the user clicked a pane we hadn't programmatically
  /// focused ourselves. This explicitly re-syncs both on every click.
  private func installClickTracking() {
    guard clickMonitor == nil else { return }
    clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
      self?.handleClick(event)
      return event
    }
  }

  private func handleClick(_ event: NSEvent) {
    guard let win = window, event.window === win,
      let sessionID = currentlyInstalledSessionID,
      let state = sessionStates[sessionID],
      let tab = state.activeTab
    else { return }
    let windowPoint = event.locationInWindow
    for pane in tab.allPanes() {
      guard let wrapper = paneWrappers[pane.id] else { continue }
      let localPoint = wrapper.convert(windowPoint, from: nil)
      if wrapper.bounds.contains(localPoint) {
        focusPane(pane, in: tab)
        return
      }
    }
  }

  // MARK: - Per-session state lifecycle

  /// Return the state for `session`, lazy-creating a single tab with a
  /// single terminal (today's default) if none exists yet.
  private func sessionState(for session: Session) -> QTSessionState {
    if let existing = sessionStates[session.id] {
      return existing
    }
    let dir = session.worktreePath ?? SessionManager.shared.projectDir
    let pane = makePane(sessionID: session.id, workingDirectory: dir)
    let state = QTSessionState()
    state.tabs = [QTTab(pane: pane)]
    sessionStates[session.id] = state
    return state
  }

  /// Ensure `session`'s state exists and is on screen. No-op (besides the
  /// window title) if it's already the installed session.
  private func install(for session: Session) {
    _ = sessionState(for: session)
    if currentlyInstalledSessionID == session.id {
      window?.title = "Quick Terminal — \(session.displayName)"
      return
    }
    rebuildContent(for: session)
  }

  /// Tear down and rebuild the window's content to reflect `session`'s
  /// active tab. Terminal views are reused by reference — only their
  /// superview changes — so scrollback/pty state always survives this.
  private func rebuildContent(for session: Session) {
    guard let container = container,
      let state = sessionStates[session.id],
      let tab = state.activeTab
    else { return }

    for sub in container.subviews { sub.removeFromSuperview() }
    paneWrappers.removeAll()

    let tabBar = buildTabBar(for: state)
    let content = buildView(for: tab.root)
    content.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(tabBar)
    container.addSubview(content)

    NSLayoutConstraint.activate([
      tabBar.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.titlebarInset),
      tabBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      tabBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      tabBar.heightAnchor.constraint(equalToConstant: Self.tabBarHeight),

      content.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 4),
      content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
      content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
      content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
    ])

    updateFocusBorders(for: tab)
    currentlyInstalledSessionID = session.id
    window?.title = "Quick Terminal — \(session.displayName)"

    // NSSplitView doesn't distribute space evenly among arranged subviews by
    // default — it sizes them off their fitting size, which our plain
    // terminal wrappers don't provide. Force every divider to the midpoint
    // once real frames exist. Split views are rebuilt from scratch here, so
    // this always resets to 50/50 rather than remembering a prior manual
    // drag — acceptable since nothing in the model persists divider ratios
    // across rebuilds anyway (tab switches, other splits/closes) today.
    container.layoutSubtreeIfNeeded()
    equalizeSplitPositions(in: content)
  }

  /// Recursively center every split divider in `view`'s subtree, laying out
  /// outer splits before descending so nested splits see their real (i.e.
  /// post-divider-move) bounds.
  private func equalizeSplitPositions(in view: NSView) {
    guard let splitView = view as? NSSplitView else { return }
    splitView.layoutSubtreeIfNeeded()
    let total = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
    let half = (total - splitView.dividerThickness) / 2
    if half > 0 {
      splitView.setPosition(half, ofDividerAt: 0)
      splitView.layoutSubtreeIfNeeded()
    }
    for sub in splitView.arrangedSubviews {
      equalizeSplitPositions(in: sub)
    }
  }

  /// Recursively build the view tree for a split node: a leaf becomes a
  /// bordered wrapper around its terminal, a split becomes an NSSplitView
  /// dividing its children.
  private func buildView(for node: QTNode) -> NSView {
    switch node {
    case .leaf(let pane):
      return paneWrapper(pane)
    case .split(let direction, let children):
      let splitView = NSSplitView()
      splitView.translatesAutoresizingMaskIntoConstraints = false
      splitView.isVertical = (direction == .vertical)
      splitView.dividerStyle = .thin
      for child in children {
        splitView.addArrangedSubview(buildView(for: child))
      }
      return splitView
    }
  }

  private func paneWrapper(_ pane: QTPane) -> NSView {
    let wrapper = NSView()
    wrapper.translatesAutoresizingMaskIntoConstraints = false
    wrapper.wantsLayer = true
    wrapper.layer?.cornerRadius = 4
    wrapper.layer?.borderWidth = 2
    wrapper.layer?.borderColor = NSColor.clear.cgColor

    let tv = pane.terminalView
    wrapper.addSubview(tv)
    NSLayoutConstraint.activate([
      tv.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 2),
      tv.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 2),
      tv.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -2),
      tv.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -2),
    ])

    // If this shell is still booting, lay its loading overlay on top.
    if let overlay = loads[pane.id]?.overlay {
      wrapper.addSubview(overlay)
      NSLayoutConstraint.activate([
        overlay.topAnchor.constraint(equalTo: tv.topAnchor),
        overlay.leadingAnchor.constraint(equalTo: tv.leadingAnchor),
        overlay.trailingAnchor.constraint(equalTo: tv.trailingAnchor),
        overlay.bottomAnchor.constraint(equalTo: tv.bottomAnchor),
      ])
    }

    paneWrappers[pane.id] = wrapper
    return wrapper
  }

  /// Give the focused pane's wrapper a visible accent border — only shown
  /// once there's more than one pane, since a single terminal doesn't need
  /// a "this one is active" cue.
  private func updateFocusBorders(for tab: QTTab) {
    let panes = tab.allPanes()
    let showBorders = panes.count > 1
    for pane in panes {
      guard let wrapper = paneWrappers[pane.id] else { continue }
      let isFocused = showBorders && pane.id == tab.lastFocusedPaneID
      wrapper.layer?.borderColor =
        isFocused ? Theme.accent.withAlphaComponent(0.7).cgColor : NSColor.clear.cgColor
    }
  }

  /// Make the installed session's focused pane the first responder — unless
  /// it's still booting, in which case focus its loading overlay so
  /// typed-ahead keystrokes are swallowed rather than corrupting the
  /// bootstrap command.
  private func focusInstalledContent() {
    guard let sessionID = currentlyInstalledSessionID,
      let state = sessionStates[sessionID],
      let tab = state.activeTab,
      let pane = tab.focusedPane()
    else { return }
    focusPaneOrOverlay(pane)
  }

  private func focusPaneOrOverlay(_ pane: QTPane) {
    // Deferred to the next runloop tick: calling makeFirstResponder in the
    // same turn as a split/tab rebuild races NSSplitView's own post-layout
    // bookkeeping, which can silently steal first responder back right
    // after we set it. Letting the current turn finish first makes the
    // assignment stick.
    DispatchQueue.main.async { [weak self] in
      guard let self = self, let win = self.window else { return }
      if let overlay = self.loads[pane.id]?.overlay {
        win.makeFirstResponder(overlay)
      } else {
        win.makeFirstResponder(pane.terminalView)
      }
    }
  }

  /// Focus `pane` within `tab`: record it as the tab's last-focused pane,
  /// refresh the highlight border, and move first responder to it.
  private func focusPane(_ pane: QTPane, in tab: QTTab) {
    tab.lastFocusedPaneID = pane.id
    updateFocusBorders(for: tab)
    focusPaneOrOverlay(pane)
  }

  /// The pane the user was last interacting with in `tab`, preferring
  /// whatever AppKit currently reports as first responder (i.e. wherever the
  /// user just clicked) over the tab's last recorded focus.
  private func currentFocusedPane(in tab: QTTab) -> QTPane? {
    if let responder = window?.firstResponder as? NSView,
      let match = tab.allPanes().first(where: { $0.terminalView === responder })
    {
      tab.lastFocusedPaneID = match.id
      return match
    }
    return tab.focusedPane()
  }

  private func session(withID id: UUID) -> Session? {
    SessionManager.shared.sessions.first { $0.id == id }
  }

  // MARK: - Tab/split actions (driven by shortcuts and tab-bar buttons)

  /// Add a new tab (with a single fresh terminal) to the active session and
  /// switch to it.
  func addTab() {
    guard let session = SessionManager.shared.activeSession else { return }
    let state = sessionState(for: session)
    let dir = session.worktreePath ?? SessionManager.shared.projectDir
    let pane = makePane(sessionID: session.id, workingDirectory: dir)
    let tab = QTTab(pane: pane)
    state.tabs.append(tab)
    state.activeTabIndex = state.tabs.count - 1
    rebuildContent(for: session)
    focusPane(pane, in: tab)
  }

  /// Split the active tab's focused pane, inserting a fresh terminal
  /// alongside it.
  func splitFocusedPane(_ direction: QTSplitDirection) {
    guard let session = SessionManager.shared.activeSession,
      let state = sessionStates[session.id],
      let tab = state.activeTab,
      let focused = currentFocusedPane(in: tab)
    else { return }
    let dir = session.worktreePath ?? SessionManager.shared.projectDir
    let newPane = makePane(sessionID: session.id, workingDirectory: dir)
    tab.split(paneID: focused.id, direction: direction, newPane: newPane)
    rebuildContent(for: session)
    focusPane(newPane, in: tab)
  }

  /// Close the active tab's focused pane: kill its shell and remove it from
  /// the tree immediately.
  func closeFocusedPane() {
    guard let session = SessionManager.shared.activeSession,
      let state = sessionStates[session.id],
      let tab = state.activeTab,
      let focused = currentFocusedPane(in: tab)
    else { return }
    killShell(focused.terminalView)
    removePane(paneID: focused.id, sessionID: session.id)
  }

  /// Close the active tab and every pane in it — the keyboard equivalent of
  /// clicking the tab's × button.
  func closeActiveTab() {
    guard let session = SessionManager.shared.activeSession,
      let state = sessionStates[session.id],
      let tab = state.activeTab
    else { return }
    closeTab(tabID: tab.id, sessionID: session.id)
  }

  /// Close `tabID`: kill every pane's shell, drop the tab, and re-render.
  private func closeTab(tabID: UUID, sessionID: UUID) {
    guard let state = sessionStates[sessionID],
      let tabIndex = state.tabs.firstIndex(where: { $0.id == tabID })
    else { return }
    for pane in state.tabs[tabIndex].allPanes() {
      cancelLoading(for: pane.id)
      paneWrappers.removeValue(forKey: pane.id)
      killShell(pane.terminalView)
    }
    state.tabs.remove(at: tabIndex)
    if state.activeTabIndex >= tabIndex {
      state.activeTabIndex = max(0, state.activeTabIndex - 1)
    }
    finishRemoval(sessionID: sessionID, state: state)
  }

  /// Kill a pane's shell. SwiftTerm's `terminate()` alone is not enough for a
  /// programmatic close: it sends SIGTERM, which interactive shells ignore,
  /// and it cancels its process-exit monitor without firing
  /// `processTerminated` — so the exit callback never arrives. Detach the
  /// callback (the caller removes the pane itself) and follow up with SIGHUP,
  /// which shells honor as "your terminal went away".
  private func killShell(_ tv: ClaudeTerminalView) {
    tv.onProcessExit = nil
    let pid = tv.process?.shellPid ?? 0
    tv.terminate()
    if pid > 0 {
      kill(pid, SIGHUP)
    }
  }

  /// Switch to tab `index` (0-based) in the active session — Option+1-9.
  /// Tabs only; panes within a tab are reached by click.
  func jumpTo(index: Int) {
    guard let session = SessionManager.shared.activeSession,
      let state = sessionStates[session.id],
      state.tabs.indices.contains(index)
    else { return }
    if state.activeTabIndex != index {
      state.activeTabIndex = index
      rebuildContent(for: session)
    }
    let tab = state.tabs[index]
    if let pane = tab.focusedPane() {
      focusPane(pane, in: tab)
    }
  }

  // MARK: - Tab bar

  /// NSButton carrying the id of the tab it represents, so a single action
  /// method can dispatch on whichever tab was clicked.
  private final class QTTabButton: NSButton {
    var tabID = UUID()
  }

  private func buildTabBar(for state: QTSessionState) -> NSView {
    let bar = NSView()
    bar.translatesAutoresizingMaskIntoConstraints = false

    let stack = NSStackView()
    stack.orientation = .horizontal
    stack.spacing = 4
    stack.alignment = .centerY
    stack.translatesAutoresizingMaskIntoConstraints = false
    bar.addSubview(stack)

    let canClose = state.tabs.count > 1
    for (i, tab) in state.tabs.enumerated() {
      let isActive = i == state.activeTabIndex

      let tabContainer = NSView()
      tabContainer.translatesAutoresizingMaskIntoConstraints = false
      tabContainer.wantsLayer = true
      tabContainer.layer?.cornerRadius = 4
      tabContainer.layer?.backgroundColor =
        isActive ? Theme.surface2.cgColor : NSColor.clear.cgColor
      tabContainer.layer?.borderColor =
        isActive ? Theme.accent.withAlphaComponent(0.5).cgColor : NSColor.clear.cgColor
      tabContainer.layer?.borderWidth = 1

      let nameBtn = QTTabButton(title: "", target: self, action: #selector(tabClicked(_:)))
      nameBtn.tabID = tab.id
      nameBtn.translatesAutoresizingMaskIntoConstraints = false
      nameBtn.isBordered = false
      let attrs: [NSAttributedString.Key: Any] = [
        .font: Theme.mono(11, weight: isActive ? .medium : .regular),
        .foregroundColor: isActive ? Theme.text1 : Theme.text3,
      ]
      nameBtn.attributedTitle = NSAttributedString(string: " \(i + 1) ", attributes: attrs)
      if i < 9 {
        nameBtn.toolTip = "Switch to tab (\u{2325}\(i + 1))"
      }
      tabContainer.addSubview(nameBtn)

      let closeBtn = QTTabButton(
        title: "\u{00D7}", target: self, action: #selector(closeTabClicked(_:)))
      closeBtn.tabID = tab.id
      closeBtn.translatesAutoresizingMaskIntoConstraints = false
      closeBtn.isBordered = false
      closeBtn.font = Theme.mono(10)
      closeBtn.contentTintColor = Theme.text3
      closeBtn.toolTip = "Close tab"
      closeBtn.isHidden = !canClose
      tabContainer.addSubview(closeBtn)

      NSLayoutConstraint.activate([
        tabContainer.heightAnchor.constraint(equalToConstant: Self.tabBarHeight - 4),

        nameBtn.leadingAnchor.constraint(equalTo: tabContainer.leadingAnchor),
        nameBtn.topAnchor.constraint(equalTo: tabContainer.topAnchor),
        nameBtn.bottomAnchor.constraint(equalTo: tabContainer.bottomAnchor),

        closeBtn.leadingAnchor.constraint(equalTo: nameBtn.trailingAnchor, constant: -2),
        closeBtn.trailingAnchor.constraint(equalTo: tabContainer.trailingAnchor, constant: -2),
        closeBtn.topAnchor.constraint(equalTo: tabContainer.topAnchor),
        closeBtn.bottomAnchor.constraint(equalTo: tabContainer.bottomAnchor),
        closeBtn.widthAnchor.constraint(equalToConstant: 16),
      ])

      stack.addArrangedSubview(tabContainer)
    }

    let addBtn = NSButton(title: "+", target: self, action: #selector(addTabClicked(_:)))
    addBtn.translatesAutoresizingMaskIntoConstraints = false
    addBtn.isBordered = false
    addBtn.font = Theme.mono(13)
    addBtn.contentTintColor = Theme.text3
    addBtn.toolTip = "New tab (\u{2325}T)"
    bar.addSubview(addBtn)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 6),
      stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: addBtn.leadingAnchor, constant: -6),

      addBtn.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -6),
      addBtn.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
    ])

    return bar
  }

  @objc private func tabClicked(_ sender: QTTabButton) {
    guard let session = SessionManager.shared.activeSession,
      let state = sessionStates[session.id],
      let idx = state.tabs.firstIndex(where: { $0.id == sender.tabID })
    else { return }
    state.activeTabIndex = idx
    rebuildContent(for: session)
    if let pane = state.tabs[idx].focusedPane() {
      focusPane(pane, in: state.tabs[idx])
    }
  }

  @objc private func closeTabClicked(_ sender: QTTabButton) {
    guard let sessionID = currentlyInstalledSessionID else { return }
    closeTab(tabID: sender.tabID, sessionID: sessionID)
  }

  @objc private func addTabClicked(_ sender: NSButton) {
    addTab()
  }

  // MARK: - Pane lifecycle

  /// Build a fresh terminal pane and start its shell.
  private func makePane(sessionID: UUID, workingDirectory: String?) -> QTPane {
    let tv = ClaudeTerminalView(frame: .zero)
    tv.translatesAutoresizingMaskIntoConstraints = false
    tv.nativeForegroundColor = Theme.text1
    tv.nativeBackgroundColor = Theme.bg
    tv.selectedTextBackgroundColor = Theme.selected
    tv.caretColor = Theme.accent
    tv.font = Theme.terminalMono(13)

    let pane = QTPane(terminalView: tv)
    let paneID = pane.id
    tv.onProcessExit = { [weak self] _ in
      DispatchQueue.main.async { self?.removePane(paneID: paneID, sessionID: sessionID) }
    }

    // Cover the booting shell with a loading overlay until it settles. The
    // overlay is mounted by paneWrapper() and torn down by finishLoading().
    let overlay = TerminalLoadingOverlay(message: "Starting terminal…", style: .zoom)
    overlay.translatesAutoresizingMaskIntoConstraints = false
    loads[paneID] = LoadState(overlay: overlay, terminalView: tv)

    startShell(in: tv, paneID: paneID, workingDirectory: workingDirectory)
    return pane
  }

  /// Remove a pane from its tab: on a shell exit (user typed `exit`, whose
  /// process-exit callback lands here) or after a programmatic close (whose
  /// caller already killed the shell). Drops the tab if it's now empty.
  private func removePane(paneID: UUID, sessionID: UUID) {
    cancelLoading(for: paneID)
    paneWrappers.removeValue(forKey: paneID)
    guard let state = sessionStates[sessionID],
      let tabIndex = state.tabIndex(ofPane: paneID)
    else { return }

    if state.tabs[tabIndex].remove(paneID: paneID) {
      state.tabs.remove(at: tabIndex)
      if state.activeTabIndex >= tabIndex {
        state.activeTabIndex = max(0, state.activeTabIndex - 1)
      }
    }
    finishRemoval(sessionID: sessionID, state: state)
  }

  /// Shared tail of pane/tab removal: drop the whole session state when its
  /// last tab closed (hiding the window if it was the visible session),
  /// otherwise re-render and hand focus back to the surviving focused pane
  /// so typing continues without an extra click.
  private func finishRemoval(sessionID: UUID, state: QTSessionState) {
    if state.tabs.isEmpty {
      sessionStates.removeValue(forKey: sessionID)
      if currentlyInstalledSessionID == sessionID {
        currentlyInstalledSessionID = nil
        for sub in container?.subviews ?? [] { sub.removeFromSuperview() }
        window?.orderOut(nil)
      }
      return
    }
    if currentlyInstalledSessionID == sessionID, let session = session(withID: sessionID) {
      rebuildContent(for: session)
      if window?.isVisible == true {
        focusInstalledContent()
      }
    }
  }

  // MARK: - Session notifications

  @objc private func activeSessionDidChange() {
    // Only swap eagerly while the window is visible — otherwise wait for
    // the next show() so we don't spin up a shell for a session the user
    // may never quick-terminal into.
    guard let win = window, win.isVisible else { return }
    guard let active = SessionManager.shared.activeSession else {
      currentlyInstalledSessionID = nil
      for sub in container?.subviews ?? [] { sub.removeFromSuperview() }
      win.orderOut(nil)
      return
    }
    install(for: active)
    focusInstalledContent()
  }

  @objc private func sessionsDidChange() {
    // Drop cached state for sessions that no longer exist, killing their
    // shells so closed sessions don't leak background processes.
    let liveIDs = Set(SessionManager.shared.sessions.map(\.id))
    let orphaned = sessionStates.keys.filter { !liveIDs.contains($0) }
    for id in orphaned {
      if let state = sessionStates[id] {
        for tab in state.tabs {
          for pane in tab.allPanes() {
            cancelLoading(for: pane.id)
            paneWrappers.removeValue(forKey: pane.id)
            killShell(pane.terminalView)
          }
        }
      }
      sessionStates.removeValue(forKey: id)
      if currentlyInstalledSessionID == id {
        currentlyInstalledSessionID = nil
        for sub in container?.subviews ?? [] { sub.removeFromSuperview() }
        window?.orderOut(nil)
      }
    }
  }

  // MARK: - Shell startup

  private func startShell(
    in tv: ClaudeTerminalView, paneID: UUID, workingDirectory: String?
  ) {
    let parentEnv = ProcessInfo.processInfo.environment
    let shell = SessionManager.resolveShellPath(parentEnv: parentEnv)

    // Match the PATH composition used for Claude sessions so tools installed
    // via Homebrew are available here too.
    let homebrewPaths = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]
    let inheritedPath = parentEnv["PATH"] ?? ""
    let inheritedParts = inheritedPath.split(separator: ":").map(String.init)
    let composedPath = (homebrewPaths.filter { !inheritedParts.contains($0) } + inheritedParts)
      .joined(separator: ":")

    var envDict: [String: String] = [
      "TERM": "xterm-256color",
      "COLORTERM": "truecolor",
      "LANG": parentEnv["LANG"] ?? "en_US.UTF-8",
      "PATH": composedPath,
      "SHELL": shell,
      "HOME": parentEnv["HOME"] ?? NSHomeDirectory(),
      "USER": parentEnv["USER"] ?? NSUserName(),
      "LOGNAME": parentEnv["LOGNAME"] ?? NSUserName(),
    ]
    for key in ["LC_ALL", "LC_CTYPE", "TMPDIR", "TZ", "DISPLAY"] {
      if let v = parentEnv[key] { envDict[key] = v }
    }
    let env: [String] = envDict.map { "\($0.key)=\($0.value)" }

    tv.startProcess(
      executable: shell,
      args: ["--login"],
      environment: env,
      execName: nil)

    // Watch the raw PTY stream for the invisible ready marker. dataReceived
    // (and thus onPtyData) fires on the main thread, so timer scheduling and
    // mutation of the load's scan state here are safe. Once the marker is
    // seen the shell is genuinely ready; a short quiescence after lets the
    // fresh prompt paint before we reveal.
    tv.onPtyData = { [weak self] slice in
      guard let self = self, let load = self.loads[paneID] else { return }
      if !load.sawMarker {
        self.appendToScanBuffer(slice, of: load)
        guard load.scanBuffer.contains(Self.readyToken) else { return }
        load.sawMarker = true
      }
      self.scheduleSettle(for: paneID)
    }

    // Login shell lands in $HOME; cd into the session's worktree so the quick
    // terminal opens where the user is working. `clear` wipes the login
    // banner so a fresh shell looks clean, then the bootstrap prints the
    // ready marker. Done once at creation — never on show/hide, so scrollback
    // survives toggling. The kernel buffers this until the shell reads it, so
    // it runs only after rc files finish sourcing. The loading overlay blocks
    // input until then so typed-ahead characters can't interleave with the
    // buffered command and break the `cd` path.
    let cdPrefix = workingDirectory.map { "cd \(shellEscape($0)) && " } ?? ""
    tv.send(txt: "\(cdPrefix)clear; \(Self.readyMarkerCommand)\r")

    // Hard ceiling so the overlay never sticks if the marker never arrives.
    loads[paneID]?.maxTimer = Timer.scheduledTimer(
      withTimeInterval: Self.maxLoad, repeats: false
    ) { [weak self] _ in
      self?.finishLoading(for: paneID)
    }
  }

  /// Shell command that emits `readyToken` inside an unused OSC sequence —
  /// invisible in the terminal but present in the raw byte stream. The token
  /// is split across printf's format and `%s` argument so the shell's echo of
  /// the typed line never contains it literally (which would match early).
  private static let readyMarkerCommand =
    "printf '\\033]5379;DFQT_%s\\007' 'READY'"

  // MARK: - Loading lifecycle

  /// Append the printable ASCII of `slice` to the load's rolling scan buffer,
  /// capped so it stays cheap to search. Non-printable bytes (the marker's
  /// surrounding ESC/BEL) are dropped, which is fine — the token is ASCII.
  private func appendToScanBuffer(_ slice: ArraySlice<UInt8>, of load: LoadState) {
    for byte in slice where byte >= 0x20 && byte < 0x7F {
      load.scanBuffer.append(Character(UnicodeScalar(byte)))
    }
    if load.scanBuffer.count > 256 {
      load.scanBuffer = String(load.scanBuffer.suffix(256))
    }
  }

  /// (Re)arm the quiescence timer: once the marker has been seen, when PTY
  /// output then stays quiet for `settleQuiet`, the shell is ready.
  private func scheduleSettle(for paneID: UUID) {
    guard let load = loads[paneID], load.sawMarker else { return }
    load.settleTimer?.invalidate()
    load.settleTimer = Timer.scheduledTimer(
      withTimeInterval: Self.settleQuiet, repeats: false
    ) { [weak self] _ in
      self?.finishLoading(for: paneID)
    }
  }

  /// Shell is ready: stop watching, fade out the overlay, and hand focus to
  /// the terminal if this pane is the one that should have it.
  private func finishLoading(for paneID: UUID) {
    guard let load = loads.removeValue(forKey: paneID) else { return }
    load.settleTimer?.invalidate()
    load.maxTimer?.invalidate()
    load.terminalView.onPtyData = nil
    load.overlay.fadeOut { [weak self] in
      self?.focusIfStillWanted(paneID: paneID, terminalView: load.terminalView)
    }
  }

  private func focusIfStillWanted(paneID: UUID, terminalView: ClaudeTerminalView) {
    guard let win = window, win.isKeyWindow,
      let sessionID = currentlyInstalledSessionID,
      let state = sessionStates[sessionID],
      let tab = state.activeTab,
      tab.lastFocusedPaneID == paneID
    else { return }
    win.makeFirstResponder(terminalView)
  }

  /// Abandon loading without revealing (shell exited, session deleted).
  private func cancelLoading(for paneID: UUID) {
    guard let load = loads.removeValue(forKey: paneID) else { return }
    load.settleTimer?.invalidate()
    load.maxTimer?.invalidate()
    load.overlay.removeFromSuperview()
  }

  /// Anchor the window near the top-center of the main window's screen so it
  /// behaves like a drop-down quick terminal.
  private func positionAtTop(of win: NSWindow) {
    let screen = NSApp.mainWindow?.screen ?? win.screen ?? NSScreen.main
    guard let frame = screen?.visibleFrame else { return }
    let size = win.frame.size
    let x = frame.midX - size.width / 2
    let y = frame.maxY - size.height - 20
    win.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
  }
}

/// Quote a path so it survives a single-line shell command.
private func shellEscape(_ path: String) -> String {
  "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
