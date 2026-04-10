import AppKit

final class DFWindowController: NSWindowController {

    let sidebar = DFSidebar()
    let terminalPane = DFTerminalPane()
    let sessionBar = DFSessionBar()
    let statusBar = DFStatusBar()
    let dashboard = DFDashboard()

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
        let hStack = NSStackView(views: [sidebar, terminalPane, sessionBar])
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

            sidebar.widthAnchor.constraint(equalToConstant: 220),
            sessionBar.widthAnchor.constraint(equalToConstant: 300),
            statusBar.heightAnchor.constraint(equalToConstant: 28),

            // Dashboard fills the entire content area
            dashboard.topAnchor.constraint(equalTo: contentView.topAnchor),
            dashboard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            dashboard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            dashboard.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
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
