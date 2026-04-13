import AppKit

final class DFWindowController: NSWindowController {

  let sidebar = DFSidebar()
  let terminalPane = DFTerminalPane()
  let codeEditor = DFCodeEditor()
  let sessionBar = DFSessionBar()
  let statusBar = DFStatusBar()
  let dashboard = DFDashboard()

  private var editorVisible = false

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

    // Sidebar, editor, and session bar get fixed widths; terminal fills the rest
    NSLayoutConstraint.activate([
      sidebar.widthAnchor.constraint(equalToConstant: 220),
      codeEditor.widthAnchor.constraint(equalToConstant: 400),
      sessionBar.widthAnchor.constraint(equalToConstant: 300),
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
}

// MARK: - Themed Split View
