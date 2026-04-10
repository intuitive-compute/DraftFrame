import AppKit

final class DFWindowController: NSWindowController, NSSplitViewDelegate {

    let sidebar = DFSidebar()
    let terminalPane = DFTerminalPane()
    let codeEditor = DFCodeEditor()
    let sessionBar = DFSessionBar()
    let statusBar = DFStatusBar()
    let dashboard = DFDashboard()
    private var splitView: NSSplitView!

    // Sidebar: min 180, max 350, default 220
    private let sidebarMinWidth: CGFloat = 180
    private let sidebarMaxWidth: CGFloat = 350
    private let sidebarDefaultWidth: CGFloat = 220

    // Editor: min 300, max 700, default 400
    private let editorMinWidth: CGFloat = 300
    private let editorMaxWidth: CGFloat = 700
    private let editorDefaultWidth: CGFloat = 400
    private var editorVisible = false

    // Session bar: min 250, max 400, default 300
    private let sessionBarMinWidth: CGFloat = 250
    private let sessionBarMaxWidth: CGFloat = 400
    private let sessionBarDefaultWidth: CGFloat = 300

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Draftframe"
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

        // Main horizontal split: sidebar | terminal | session bar
        splitView = ThemedSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.translatesAutoresizingMaskIntoConstraints = false

        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(terminalPane)
        splitView.addArrangedSubview(codeEditor)
        splitView.addArrangedSubview(sessionBar)

        // Editor starts hidden
        codeEditor.isHidden = true

        // Set initial widths via holding priorities
        sidebar.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        terminalPane.setContentHuggingPriority(.defaultLow, for: .horizontal)
        codeEditor.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        sessionBar.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        // Vertical: splitView on top, status bar on bottom
        let vStack = NSStackView(views: [splitView, statusBar])
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

        // Set initial pane widths after layout is established
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.splitView.setPosition(self.sidebarDefaultWidth, ofDividerAt: 0)
            // With editor hidden, divider 1 goes directly to session bar boundary
            let terminalEnd = self.splitView.frame.width - self.sessionBarDefaultWidth
            self.splitView.setPosition(terminalEnd, ofDividerAt: 1)
        }

        // Listen for editor toggle
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleToggleEditor),
            name: .toggleEditorPane, object: nil
        )
    }

    // MARK: - NSSplitViewDelegate

    /// Returns the index of a divider based on which panes are visible.
    /// Layout: sidebar(0) | terminal(1) | editor(2) | sessionBar(3)
    /// When editor is hidden, NSSplitView skips it, so dividers shift.
    private var sessionBarDividerIndex: Int {
        return editorVisible ? 2 : 1
    }
    private var editorDividerIndex: Int { return 1 } // only valid when editorVisible

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        if dividerIndex == 0 {
            return sidebarMinWidth
        } else if editorVisible && dividerIndex == 1 {
            // Between terminal and editor: terminal min
            return sidebarMinWidth + 200
        } else {
            // Between (editor or terminal) and session bar
            if editorVisible {
                return sidebarMinWidth + 200 + editorMinWidth
            } else {
                return sidebarMinWidth + 200
            }
        }
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        let totalWidth = splitView.frame.width
        if dividerIndex == 0 {
            return sidebarMaxWidth
        } else if editorVisible && dividerIndex == 1 {
            // Terminal/editor divider: leave room for editor min + session bar min
            return totalWidth - editorMinWidth - sessionBarMinWidth - splitView.dividerThickness
        } else {
            return totalWidth - sessionBarMinWidth
        }
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        return false
    }

    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        let totalWidth = splitView.frame.width
        if dividerIndex == 0 {
            return min(max(proposedPosition, sidebarMinWidth), sidebarMaxWidth)
        } else if editorVisible && dividerIndex == 1 {
            // Clamp: leave room for editor min + session bar
            let maxPos = totalWidth - editorMinWidth - sessionBarMinWidth - splitView.dividerThickness
            return min(max(proposedPosition, sidebarMinWidth + 200), maxPos)
        } else {
            // Session bar divider
            let sessionBarWidth = totalWidth - proposedPosition
            let clampedWidth = min(max(sessionBarWidth, sessionBarMinWidth), sessionBarMaxWidth)
            return totalWidth - clampedWidth
        }
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        let newWidth = splitView.frame.width
        let dividerThickness = splitView.dividerThickness
        let height = splitView.frame.height

        var sidebarWidth = sidebar.frame.width
        sidebarWidth = min(max(sidebarWidth, sidebarMinWidth), sidebarMaxWidth)

        var sessionBarWidth = sessionBar.frame.width
        sessionBarWidth = min(max(sessionBarWidth, sessionBarMinWidth), sessionBarMaxWidth)

        if editorVisible {
            var editorWidth = codeEditor.frame.width
            editorWidth = min(max(editorWidth, editorMinWidth), editorMaxWidth)

            let terminalWidth = newWidth - sidebarWidth - editorWidth - sessionBarWidth - (dividerThickness * 3)
            var x: CGFloat = 0

            sidebar.frame = NSRect(x: x, y: 0, width: sidebarWidth, height: height)
            x += sidebarWidth + dividerThickness

            terminalPane.frame = NSRect(x: x, y: 0, width: max(terminalWidth, 200), height: height)
            x += max(terminalWidth, 200) + dividerThickness

            codeEditor.frame = NSRect(x: x, y: 0, width: editorWidth, height: height)
            x += editorWidth + dividerThickness

            sessionBar.frame = NSRect(x: x, y: 0, width: sessionBarWidth, height: height)
        } else {
            let terminalWidth = newWidth - sidebarWidth - sessionBarWidth - (dividerThickness * 2)

            sidebar.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: height)
            terminalPane.frame = NSRect(x: sidebarWidth + dividerThickness, y: 0,
                                         width: max(terminalWidth, 200), height: height)
            sessionBar.frame = NSRect(x: newWidth - sessionBarWidth, y: 0,
                                       width: sessionBarWidth, height: height)
        }
    }

    /// Custom divider color matching Theme.surface3.
    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                   forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        return proposedEffectiveRect
    }

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
        if editorVisible {
            // Hide editor
            codeEditor.isHidden = true
            editorVisible = false

            // Re-layout: just sidebar | terminal | sessionBar
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.splitView.adjustSubviews()
                let terminalEnd = self.splitView.frame.width - self.sessionBarDefaultWidth
                self.splitView.setPosition(terminalEnd, ofDividerAt: 1)
            }
        } else {
            // Show editor
            codeEditor.isHidden = false
            editorVisible = true

            // Layout: sidebar | terminal | editor | sessionBar
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.splitView.adjustSubviews()
                let totalWidth = self.splitView.frame.width
                let sessionBarPos = totalWidth - self.sessionBarDefaultWidth
                let editorStart = sessionBarPos - self.editorDefaultWidth
                // Divider 1: between terminal and editor
                self.splitView.setPosition(editorStart, ofDividerAt: 1)
                // Divider 2: between editor and session bar
                self.splitView.setPosition(sessionBarPos, ofDividerAt: 2)
            }
        }
    }

    /// Show the editor pane (does nothing if already visible).
    func showEditor() {
        if !editorVisible {
            toggleEditor()
        }
    }

    // MARK: - Sidebar Toggle

    private var sidebarCollapsed = false
    private var savedSidebarWidth: CGFloat = 220

    func toggleSidebar() {
        if sidebarCollapsed {
            // Restore sidebar
            sidebar.isHidden = false
            splitView.setPosition(savedSidebarWidth, ofDividerAt: 0)
            sidebarCollapsed = false
        } else {
            // Collapse sidebar
            savedSidebarWidth = sidebar.frame.width
            splitView.setPosition(0, ofDividerAt: 0)
            sidebar.isHidden = true
            sidebarCollapsed = true
        }
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
                // User cancelled — open in home directory as fallback
                self?.openProject(at: NSHomeDirectory())
                return
            }
            self?.openProject(at: url.path)
        }
    }

    func openProject(at path: String) {
        // Set the project directory
        SessionManager.shared.projectDir = path
        FileManager.default.changeCurrentDirectoryPath(path)

        // Detect git repo for worktree support
        WorktreeManager.shared.detectRepoRoot(from: path)

        // Update window title
        let dirName = (path as NSString).lastPathComponent
        window?.title = "Draftframe — \(dirName)"

        // Check for saved sessions to restore
        if SessionPersistence.shared.hasSavedSessions(for: path) {
            let alert = NSAlert()
            alert.messageText = "Restore previous sessions?"
            alert.informativeText = "Saved sessions were found for this project. Would you like to restore them?"
            alert.addButton(withTitle: "Restore")
            alert.addButton(withTitle: "Start Fresh")

            if let win = window {
                alert.beginSheetModal(for: win) { [weak self] response in
                    if response == .alertFirstButtonReturn {
                        SessionPersistence.shared.restoreSessions(for: path)
                    } else {
                        SessionPersistence.shared.clearSavedSessions()
                        self?.terminalPane.createNewSession(name: dirName, worktreePath: path)
                    }
                }
            } else {
                terminalPane.createNewSession(name: dirName, worktreePath: path)
            }
        } else {
            // No saved sessions — create the first Claude session
            terminalPane.createNewSession(name: dirName, worktreePath: path)
        }
    }
}

// MARK: - Themed Split View

/// NSSplitView subclass that draws dividers in Theme.surface3.
final class ThemedSplitView: NSSplitView {
    override var dividerColor: NSColor {
        return Theme.surface3
    }
}
