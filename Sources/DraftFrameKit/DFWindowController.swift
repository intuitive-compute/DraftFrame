import AppKit

final class DFWindowController: NSWindowController {

  let sidebar = DFSidebar()
  let terminalPane = DFTerminalPane()
  let codeEditor = DFCodeEditor()
  let sessionBar = DFSessionBar()
  let statusBar = DFStatusBar()
  let dashboard = DFDashboard()

  private var editorVisible = false

  /// Width constraint for the sidebar — mutated by the resize handle.
  private var sidebarWidthConstraint: NSLayoutConstraint?

  /// Bounds for the sidebar's resizable width.
  private let sidebarMinWidth: CGFloat = 160
  private let sidebarMaxWidth: CGFloat = 500

  /// UserDefaults key for persisting the sidebar width across launches.
  private let sidebarWidthKey = "DFSidebarWidth"

  init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1400, height: 860),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = "DraftFrame"
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.backgroundColor = Theme.bg
    window.minSize = NSSize(width: 800, height: 400)
    window.center()

    super.init(window: window)
    buildLayout()
    setupShortcuts()

    // Prompt user to open a project directory
    DispatchQueue.main.async { [weak self] in
      self?.promptOpenProject()
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  private func buildLayout() {
    guard let contentView = window?.contentView else { return }
    contentView.wantsLayer = true

    // Main horizontal stack: sidebar | terminal | editor | session bar
    codeEditor.isHidden = true
    let hStack = NSStackView(views: [sidebar, terminalPane, codeEditor, sessionBar])
    hStack.orientation = .horizontal
    hStack.spacing = 1
    hStack.distribution = .fill
    hStack.translatesAutoresizingMaskIntoConstraints = false

    // Vertical: hStack on top, status bar on bottom
    let vStack = NSStackView(views: [hStack, statusBar])
    vStack.orientation = .vertical
    vStack.spacing = 0
    vStack.translatesAutoresizingMaskIntoConstraints = false

    contentView.addSubview(vStack)

    // Dashboard overlay (on top of everything)
    dashboard.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(dashboard)

    NSLayoutConstraint.activate([
      vStack.topAnchor.constraint(equalTo: contentView.topAnchor),
      vStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      vStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      vStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

      statusBar.heightAnchor.constraint(equalToConstant: 28),

      // Dashboard fills the entire content area
      dashboard.topAnchor.constraint(equalTo: contentView.topAnchor),
      dashboard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      dashboard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      dashboard.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
    ])

    // Sidebar width is user-resizable (persisted). Editor and session bar stay
    // fixed. Terminal fills the rest.
    let savedWidth = UserDefaults.standard.object(forKey: sidebarWidthKey) as? Double
    let initialWidth =
      savedWidth.map { CGFloat($0) }
      .map { min(max($0, sidebarMinWidth), sidebarMaxWidth) } ?? 220
    let widthConstraint = sidebar.widthAnchor.constraint(equalToConstant: initialWidth)
    sidebarWidthConstraint = widthConstraint
    NSLayoutConstraint.activate([
      widthConstraint,
      codeEditor.widthAnchor.constraint(equalToConstant: 400),
      sessionBar.widthAnchor.constraint(equalToConstant: 300),
    ])

    // Drag handle on the sidebar's right edge — overlays the border so the
    // user can grab a few pixels either side of the divider to resize.
    let handle = DFSidebarResizeHandle { [weak self] delta in
      self?.adjustSidebarWidth(by: delta)
    }
    handle.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(handle)
    NSLayoutConstraint.activate([
      handle.topAnchor.constraint(equalTo: hStack.topAnchor),
      handle.bottomAnchor.constraint(equalTo: hStack.bottomAnchor),
      handle.centerXAnchor.constraint(equalTo: sidebar.trailingAnchor),
      handle.widthAnchor.constraint(equalToConstant: 6),
    ])

    // Listen for editor toggle
    NotificationCenter.default.addObserver(
      self, selector: #selector(handleToggleEditor),
      name: .toggleEditorPane, object: nil
    )
  }

  // MARK: - NSSplitViewDelegate

  // No NSSplitView delegate needed — using NSStackView with fixed widths

  // MARK: - Editor Toggle

  @objc private func handleToggleEditor(_ notification: Notification) {
    // If "show" key is true, only show (don't toggle off)
    if let show = notification.userInfo?["show"] as? Bool, show {
      showEditor()
    } else {
      toggleEditor()
    }
  }

  func toggleEditor() {
    editorVisible = !editorVisible
    codeEditor.isHidden = !editorVisible
  }

  func showEditor() {
    if !editorVisible { toggleEditor() }
  }

  // MARK: - Sidebar Toggle

  func toggleSidebar() {
    sidebar.isHidden = !sidebar.isHidden
  }

  private func setupShortcuts() {
    let shortcuts = ShortcutManager.shared

    shortcuts.onNewSession = { [weak self] in
      let count = SessionManager.shared.sessions.count + 1
      self?.terminalPane.createNewSession(name: "session-\(count)")
    }

    shortcuts.onCloseSession = {
      let idx = SessionManager.shared.activeSessionIndex
      if idx >= 0 {
        SessionManager.shared.closeSession(at: idx)
      }
    }

    shortcuts.onSwitchSession = { index in
      SessionManager.shared.switchTo(index: index)
    }

    shortcuts.onToggleDashboard = { [weak self] in
      self?.dashboard.toggle()
    }

    shortcuts.onNewSessionWithWorktree = { [weak self] in
      self?.promptNewWorktreeSession()
    }

    shortcuts.onToggleSidebar = { [weak self] in
      self?.toggleSidebar()
    }

    shortcuts.onToggleEditor = { [weak self] in
      self?.toggleEditor()
    }

    shortcuts.onToggleQuickTerminal = {
      DFQuickTerminal.shared.toggle()
    }

    shortcuts.install()
  }

  private func promptNewWorktreeSession() {
    let alert = NSAlert()
    alert.messageText = "New Session with Worktree"
    alert.informativeText = "Enter a branch name for the new worktree:"
    alert.addButton(withTitle: "Create")
    alert.addButton(withTitle: "Cancel")

    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
    input.placeholderString = "feature-name"
    alert.accessoryView = input

    guard let win = window else { return }
    alert.beginSheetModal(for: win) { response in
      guard response == .alertFirstButtonReturn else { return }
      let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else { return }

      do {
        let path = try WorktreeManager.shared.createWorktree(name: name)
        self.terminalPane.createNewSession(name: name, worktreePath: path)
      } catch {
        let errAlert = NSAlert()
        errAlert.messageText = "Worktree Error"
        errAlert.informativeText = error.localizedDescription
        errAlert.runModal()
      }
    }
  }

  // MARK: - Open Project

  func promptOpenProject() {
    let panel = NSOpenPanel()
    panel.title = "Open Project"
    panel.message = "Choose a directory to open with Claude Code"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false

    guard let win = window else { return }
    panel.beginSheetModal(for: win) { [weak self] response in
      guard response == .OK, let url = panel.url else {
        // User cancelled — if no projects open yet, use home as fallback
        if ProjectManager.shared.projects.isEmpty {
          self?.openProject(at: NSHomeDirectory())
        }
        return
      }
      self?.openProject(at: url.path)
    }
  }

  func openProject(at path: String) {
    // Set the project directory
    SessionManager.shared.projectDir = path
    FileManager.default.changeCurrentDirectoryPath(path)

    // Add to persistent project list
    ProjectManager.shared.addProject(path: path)

    // Detect git repo for worktree support
    WorktreeManager.shared.detectRepoRoot(from: path)

    // Update window title
    let dirName = (path as NSString).lastPathComponent
    window?.title = "DraftFrame — \(dirName)"

    // Check for saved sessions to restore
    var shouldRestore = false
    if SessionPersistence.shared.hasSavedSessions(for: path) {
      let alert = NSAlert()
      alert.messageText = "Restore previous sessions?"
      alert.informativeText =
        "Saved sessions were found for this project. Would you like to restore them?"
      alert.addButton(withTitle: "Restore")
      alert.addButton(withTitle: "Start Fresh")
      shouldRestore = alert.runModal() == .alertFirstButtonReturn
    }

    // Create sessions AFTER modal returns so the run loop is free
    DispatchQueue.main.async { [weak self] in
      if shouldRestore {
        SessionPersistence.shared.restoreSessions(for: path)
      } else {
        SessionPersistence.shared.clearSavedSessions()
        self?.terminalPane.createNewSession(name: dirName, worktreePath: path)
      }
    }
  }

  // MARK: - Sidebar Resizing

  /// Called by the resize handle on every drag delta. Clamps to the allowed
  /// range and persists the final width.
  fileprivate func adjustSidebarWidth(by delta: CGFloat) {
    guard let c = sidebarWidthConstraint else { return }
    let newWidth = min(max(c.constant + delta, sidebarMinWidth), sidebarMaxWidth)
    c.constant = newWidth
    UserDefaults.standard.set(Double(newWidth), forKey: sidebarWidthKey)
  }
}

// MARK: - Sidebar Resize Handle

/// Thin draggable strip sitting over the sidebar's right edge. Reports drag
/// deltas (positive = widen sidebar) to a callback and shows a
/// horizontal-resize cursor on hover.
private final class DFSidebarResizeHandle: NSView {
  private let onDrag: (CGFloat) -> Void
  private var lastX: CGFloat = 0

  init(onDrag: @escaping (CGFloat) -> Void) {
    self.onDrag = onDrag
    super.init(frame: .zero)
    // Transparent — we only want hit-testing and cursor behavior.
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .resizeLeftRight)
  }

  override func mouseDown(with event: NSEvent) {
    lastX = event.locationInWindow.x
  }

  override func mouseDragged(with event: NSEvent) {
    let x = event.locationInWindow.x
    let delta = x - lastX
    lastX = x
    if delta != 0 { onDrag(delta) }
  }
}
