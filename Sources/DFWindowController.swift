import AppKit

final class DFWindowController: NSWindowController, NSSplitViewDelegate {

    let sidebar = DFSidebar()
    let terminalPane = DFTerminalPane()
    let sessionBar = DFSessionBar()
    let statusBar = DFStatusBar()
    let dashboard = DFDashboard()
    private var splitView: NSSplitView!

    // Sidebar: min 180, max 350, default 220
    private let sidebarMinWidth: CGFloat = 180
    private let sidebarMaxWidth: CGFloat = 350
    private let sidebarDefaultWidth: CGFloat = 220

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

        // Create initial session after a brief delay so the window is visible
        DispatchQueue.main.async { [weak self] in
            self?.terminalPane.ensureInitialSession()
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
        splitView.addArrangedSubview(sessionBar)

        // Set initial widths via holding priorities
        sidebar.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        terminalPane.setContentHuggingPriority(.defaultLow, for: .horizontal)
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
            let terminalEnd = self.splitView.frame.width - self.sessionBarDefaultWidth
            self.splitView.setPosition(terminalEnd, ofDividerAt: 1)
        }
    }

    // MARK: - NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        if dividerIndex == 0 {
            // Left divider: sidebar minimum
            return sidebarMinWidth
        } else {
            // Right divider: terminal needs at least some space
            return sidebarMinWidth + 200
        }
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        let totalWidth = splitView.frame.width
        if dividerIndex == 0 {
            // Left divider: sidebar maximum
            return sidebarMaxWidth
        } else {
            // Right divider: session bar minimum constrains from the right
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
            // Clamp sidebar
            return min(max(proposedPosition, sidebarMinWidth), sidebarMaxWidth)
        } else {
            // Clamp session bar (measured from right edge)
            let sessionBarWidth = totalWidth - proposedPosition
            let clampedWidth = min(max(sessionBarWidth, sessionBarMinWidth), sessionBarMaxWidth)
            return totalWidth - clampedWidth
        }
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        let newWidth = splitView.frame.width
        let dividerThickness = splitView.dividerThickness

        // Get current sidebar and session bar widths, clamped
        var sidebarWidth = sidebar.frame.width
        sidebarWidth = min(max(sidebarWidth, sidebarMinWidth), sidebarMaxWidth)

        var sessionBarWidth = sessionBar.frame.width
        sessionBarWidth = min(max(sessionBarWidth, sessionBarMinWidth), sessionBarMaxWidth)

        // Terminal gets remaining space
        let terminalWidth = newWidth - sidebarWidth - sessionBarWidth - (dividerThickness * 2)
        let height = splitView.frame.height

        sidebar.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: height)
        terminalPane.frame = NSRect(x: sidebarWidth + dividerThickness, y: 0,
                                     width: max(terminalWidth, 200), height: height)
        sessionBar.frame = NSRect(x: newWidth - sessionBarWidth, y: 0,
                                   width: sessionBarWidth, height: height)
    }

    /// Custom divider color matching Theme.surface3.
    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                   forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        return proposedEffectiveRect
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
}

// MARK: - Themed Split View

/// NSSplitView subclass that draws dividers in Theme.surface3.
final class ThemedSplitView: NSSplitView {
    override var dividerColor: NSColor {
        return Theme.surface3
    }
}
