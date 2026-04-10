import AppKit
import SwiftTerm

/// Center pane: multi-tab terminal using SwiftTerm LocalProcessTerminalView.
/// Each tab is a separate session managed by SessionManager.
final class DFTerminalPane: NSView {

    private let tabBar = NSView()
    private let tabStack = NSStackView()
    private let terminalContainer = NSView()
    private var tabButtons: [NSButton] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg.cgColor
        setupUI()

        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionsChanged),
            name: .sessionsDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(activeSessionChanged),
            name: .activeSessionDidChange, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupUI() {
        // Tab bar at top
        tabBar.wantsLayer = true
        tabBar.layer?.backgroundColor = Theme.surface1.cgColor
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabBar)

        // Tab bar bottom border
        let tabBorder = NSView()
        tabBorder.wantsLayer = true
        tabBorder.layer?.backgroundColor = Theme.surface3.cgColor
        tabBorder.translatesAutoresizingMaskIntoConstraints = false
        tabBar.addSubview(tabBorder)

        // Scrollable tab stack
        tabStack.orientation = .horizontal
        tabStack.spacing = 0
        tabStack.alignment = .centerY
        tabStack.translatesAutoresizingMaskIntoConstraints = false
        tabBar.addSubview(tabStack)

        // New tab "+" button
        let addBtn = NSButton(title: "+", target: self, action: #selector(addTabClicked))
        addBtn.translatesAutoresizingMaskIntoConstraints = false
        addBtn.isBordered = false
        addBtn.font = Theme.mono(14, weight: .medium)
        addBtn.contentTintColor = Theme.text3
        tabBar.addSubview(addBtn)

        // Terminal container
        terminalContainer.wantsLayer = true
        terminalContainer.layer?.backgroundColor = Theme.bg.cgColor
        terminalContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalContainer)

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 30),

            tabBorder.bottomAnchor.constraint(equalTo: tabBar.bottomAnchor),
            tabBorder.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor),
            tabBorder.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor),
            tabBorder.heightAnchor.constraint(equalToConstant: 1),

            tabStack.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor, constant: 4),
            tabStack.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor),
            tabStack.trailingAnchor.constraint(lessThanOrEqualTo: addBtn.leadingAnchor, constant: -4),

            addBtn.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor, constant: -8),
            addBtn.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor),
            addBtn.widthAnchor.constraint(equalToConstant: 24),

            terminalContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            terminalContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Tab Management

    @objc private func addTabClicked() {
        createNewSession()
    }

    func createNewSession(name: String? = nil, worktreePath: String? = nil) {
        SessionManager.shared.createSession(name: name, worktreePath: worktreePath)
    }

    /// Ensure there's at least one session on first display.
    func ensureInitialSession() {
        if SessionManager.shared.sessions.isEmpty {
            SessionManager.shared.createSession(name: "main")
        }
    }

    @objc private func sessionsChanged() {
        rebuildTabs()
    }

    @objc private func activeSessionChanged() {
        showActiveTerminal()
        updateTabHighlights()
    }

    private func rebuildTabs() {
        // Remove old tab buttons
        for btn in tabButtons {
            tabStack.removeArrangedSubview(btn)
            btn.removeFromSuperview()
        }
        tabButtons.removeAll()

        let sessions = SessionManager.shared.sessions
        for (i, session) in sessions.enumerated() {
            let btn = NSButton(title: "", target: self, action: #selector(tabClicked(_:)))
            btn.tag = i
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.isBordered = false
            btn.wantsLayer = true
            btn.layer?.cornerRadius = 4

            // Attributed title with session name
            let isActive = i == SessionManager.shared.activeSessionIndex
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Theme.mono(11, weight: isActive ? .medium : .regular),
                .foregroundColor: isActive ? Theme.text1 : Theme.text3,
            ]
            btn.attributedTitle = NSAttributedString(string: " \(session.name) ", attributes: attrs)

            if isActive {
                btn.layer?.backgroundColor = Theme.surface2.cgColor
            } else {
                btn.layer?.backgroundColor = NSColor.clear.cgColor
            }

            btn.heightAnchor.constraint(equalToConstant: 24).isActive = true

            tabStack.addArrangedSubview(btn)
            tabButtons.append(btn)
        }

        showActiveTerminal()
    }

    @objc private func tabClicked(_ sender: NSButton) {
        SessionManager.shared.switchTo(index: sender.tag)
    }

    private func updateTabHighlights() {
        let activeIdx = SessionManager.shared.activeSessionIndex
        for (i, btn) in tabButtons.enumerated() {
            let isActive = i == activeIdx
            let session = SessionManager.shared.sessions[i]
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Theme.mono(11, weight: isActive ? .medium : .regular),
                .foregroundColor: isActive ? Theme.text1 : Theme.text3,
            ]
            btn.attributedTitle = NSAttributedString(string: " \(session.name) ", attributes: attrs)
            btn.layer?.backgroundColor = isActive ? Theme.surface2.cgColor : NSColor.clear.cgColor
        }
    }

    private func showActiveTerminal() {
        // Remove all terminal views from container
        for sub in terminalContainer.subviews {
            sub.removeFromSuperview()
        }

        guard let session = SessionManager.shared.activeSession,
              let tv = session.terminalView else { return }

        tv.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.addSubview(tv)

        NSLayoutConstraint.activate([
            tv.topAnchor.constraint(equalTo: terminalContainer.topAnchor),
            tv.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor),
            tv.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor),
            tv.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor),
        ])

        window?.makeFirstResponder(tv)
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        if let tv = SessionManager.shared.activeSession?.terminalView {
            window?.makeFirstResponder(tv)
        }
        return true
    }
}
