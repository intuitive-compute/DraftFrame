import AppKit

public final class DFAppDelegate: NSObject, NSApplicationDelegate {
  var windowController: DFWindowController?

  override public init() {
    super.init()
  }

  public func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)

    // Set dock icon from bundled image
    if let iconPath = findAppIcon(),
      let icon = NSImage(contentsOfFile: iconPath)
    {
      NSApp.applicationIconImage = icon
    }

    // Request notification permissions and start observing session state
    NotificationManager.shared.requestAuthorization()

    // Request voice transcription permissions
    VoiceManager.shared.requestAuthorization()

    buildMenuBar()

    let wc = DFWindowController()
    wc.showWindow(nil)
    wc.window?.makeKeyAndOrderFront(nil)
    windowController = wc
  }

  public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    // Save session state before quitting
    SessionPersistence.shared.saveSessions()

    // Close all sessions cleanly
    let sessions = SessionManager.shared.sessions
    for i in (0..<sessions.count).reversed() {
      sessions[i].jsonlWatcher?.stop()
    }

    // Check if there are draftframe-managed worktrees to clean up
    let worktrees = WorktreeManager.shared.listWorktrees()
    let managedWorktrees = worktrees.filter { wt in
      !wt.isBare && wt.branch.hasPrefix("draftframe/")
    }

    if !managedWorktrees.isEmpty {
      let alert = NSAlert()
      alert.messageText = "Clean up worktrees?"
      alert.informativeText =
        "There are \(managedWorktrees.count) draftframe-managed worktree(s). Remove them before quitting?"
      alert.alertStyle = .informational
      alert.addButton(withTitle: "Remove Worktrees")
      alert.addButton(withTitle: "Keep Worktrees")

      let response = alert.runModal()
      if response == .alertFirstButtonReturn {
        for wt in managedWorktrees {
          let name = (wt.path as NSString).lastPathComponent
          try? WorktreeManager.shared.removeWorktree(name: name)
        }
      }
    }

    return .terminateNow
  }

  // MARK: - Menu Bar

  private func buildMenuBar() {
    let mainMenu = NSMenu()

    // App menu
    let appMenuItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "About DraftFrame", action: #selector(showAbout), keyEquivalent: "")
    appMenu.addItem(NSMenuItem.separator())
    appMenu.addItem(
      withTitle: "Quit DraftFrame", action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q")
    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)

    // File menu
    let fileMenuItem = NSMenuItem()
    let fileMenu = NSMenu(title: "File")
    fileMenu.addItem(
      withTitle: "Open Project…", action: #selector(menuOpenProject), keyEquivalent: "o")
    fileMenu.addItem(NSMenuItem.separator())
    fileMenu.addItem(
      withTitle: "New Session", action: #selector(menuNewSession), keyEquivalent: "t")
    fileMenu.addItem(
      withTitle: "New Session with Worktree", action: #selector(menuNewWorktreeSession),
      keyEquivalent: "n")
    fileMenu.addItem(NSMenuItem.separator())
    fileMenu.addItem(
      withTitle: "Close Session", action: #selector(menuCloseSession), keyEquivalent: "w")
    fileMenuItem.submenu = fileMenu
    mainMenu.addItem(fileMenuItem)

    // View menu
    let viewMenuItem = NSMenuItem()
    let viewMenu = NSMenu(title: "View")
    viewMenu.addItem(
      withTitle: "Toggle Dashboard", action: #selector(menuToggleDashboard), keyEquivalent: "d")
    let sidebarItem = NSMenuItem(
      title: "Toggle Sidebar", action: #selector(menuToggleSidebar), keyEquivalent: "\\")
    viewMenu.addItem(sidebarItem)
    viewMenuItem.submenu = viewMenu
    mainMenu.addItem(viewMenuItem)

    // Session menu
    let sessionMenuItem = NSMenuItem()
    let sessionMenu = NSMenu(title: "Session")
    sessionMenu.addItem(
      withTitle: "Rename Session", action: #selector(menuRenameSession), keyEquivalent: "")
    sessionMenu.addItem(
      withTitle: "Restart Session", action: #selector(menuRestartSession), keyEquivalent: "")
    sessionMenuItem.submenu = sessionMenu
    mainMenu.addItem(sessionMenuItem)

    // Help menu
    let helpMenuItem = NSMenuItem()
    let helpMenu = NSMenu(title: "Help")
    helpMenu.addItem(withTitle: "About DraftFrame", action: #selector(showAbout), keyEquivalent: "")
    helpMenuItem.submenu = helpMenu
    mainMenu.addItem(helpMenuItem)

    NSApp.mainMenu = mainMenu
  }

  // MARK: - Menu Actions

  @objc private func menuOpenProject() {
    windowController?.promptOpenProject()
  }

  @objc private func menuNewSession() {
    let count = SessionManager.shared.sessions.count + 1
    windowController?.terminalPane.createNewSession(name: "session-\(count)")
  }

  @objc private func menuNewWorktreeSession() {
    ShortcutManager.shared.onNewSessionWithWorktree?()
  }

  @objc private func menuCloseSession() {
    let idx = SessionManager.shared.activeSessionIndex
    if idx >= 0 {
      SessionManager.shared.closeSession(at: idx)
    }
  }

  @objc private func menuToggleDashboard() {
    windowController?.dashboard.toggle()
  }

  @objc private func menuToggleSidebar() {
    windowController?.toggleSidebar()
  }

  @objc private func menuRenameSession() {
    let idx = SessionManager.shared.activeSessionIndex
    windowController?.terminalPane.promptRenameSession(at: idx)
  }

  @objc private func menuRestartSession() {
    guard let session = SessionManager.shared.activeSession else { return }
    SessionManager.shared.restartSession(id: session.id)
  }

  private func findAppIcon() -> String? {
    // Look for AppIcon.png relative to the executable
    let execPath = CommandLine.arguments[0]
    let execDir = (execPath as NSString).deletingLastPathComponent

    // Check next to executable
    let beside = (execDir as NSString).appendingPathComponent("AppIcon.png")
    if FileManager.default.fileExists(atPath: beside) { return beside }

    // Check in Sources/DraftFrame/ (dev mode)
    var search = execDir
    for _ in 0..<10 {
      let candidate = (search as NSString).appendingPathComponent("Sources/DraftFrame/AppIcon.png")
      if FileManager.default.fileExists(atPath: candidate) { return candidate }
      search = (search as NSString).deletingLastPathComponent
      if search == "/" { break }
    }

    return nil
  }

  @objc private func showAbout() {
    let alert = NSAlert()
    alert.messageText = "DraftFrame"
    alert.informativeText =
      "A multi-session terminal for Claude Code.\n\nManage parallel Claude sessions with worktree isolation, live status tracking, and a built-in toolkit."
    alert.alertStyle = .informational
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }
}
