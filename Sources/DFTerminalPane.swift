import AppKit
import SwiftTerm

/// Center pane: multi-tab terminal using SwiftTerm LocalProcessTerminalView.
/// Each tab is a separate session managed by SessionManager.
final class DFTerminalPane: NSView {

    private let tabBar = NSView()
    private let tabStack = NSStackView()
    private let terminalContainer = NSView()
    /// Each entry is the container view for a tab (holds name button + close button).
    private var tabViews: [NSView] = []

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
        NSLog("[TerminalPane] sessionsChanged notification received, sessions=%d", SessionManager.shared.sessions.count)
        rebuildTabs()
    }

    @objc private func activeSessionChanged() {
        rebuildTabs()
    }

    private func rebuildTabs() {
        // Remove old tab views
        for view in tabViews {
            tabStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        tabViews.removeAll()

        let sessions = SessionManager.shared.sessions
        let canClose = sessions.count > 1

        for (i, session) in sessions.enumerated() {
            let isActive = i == SessionManager.shared.activeSessionIndex

            // Container for the tab (name button + close button)
            let container = NSView()
            container.translatesAutoresizingMaskIntoConstraints = false
            container.wantsLayer = true
            container.layer?.cornerRadius = 4
            if isActive {
                container.layer?.backgroundColor = Theme.surface2.cgColor
                container.layer?.borderColor = Theme.accent.withAlphaComponent(0.5).cgColor
                container.layer?.borderWidth = 1
            } else {
                container.layer?.backgroundColor = NSColor.clear.cgColor
            }

            // Pulsing attention dot on the tab (for non-active sessions needing input)
            let needsAttention = !isActive && (session.state == .needsAttention || session.state == .userInput)
            let tabDot = NSView()
            tabDot.wantsLayer = true
            tabDot.translatesAutoresizingMaskIntoConstraints = false
            tabDot.layer?.cornerRadius = 3
            tabDot.layer?.backgroundColor = session.state.color.cgColor
            tabDot.isHidden = !needsAttention
            container.addSubview(tabDot)

            if needsAttention {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 0.3
                pulse.toValue = 1.0
                pulse.duration = 1.4
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                tabDot.layer?.add(pulse, forKey: "tabDotPulse")

                tabDot.layer?.shadowColor = session.state.color.cgColor
                tabDot.layer?.shadowOffset = .zero
                tabDot.layer?.shadowRadius = 4
                tabDot.layer?.shadowOpacity = 0.7
                tabDot.layer?.masksToBounds = false
            }

            // Name button
            let nameBtn = NSButton(title: "", target: self, action: #selector(tabClicked(_:)))
            nameBtn.tag = i
            nameBtn.translatesAutoresizingMaskIntoConstraints = false
            nameBtn.isBordered = false
            let nameColor: NSColor
            if needsAttention {
                nameColor = session.state.color
            } else {
                nameColor = isActive ? Theme.text1 : Theme.text3
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Theme.mono(11, weight: isActive ? .medium : .regular),
                .foregroundColor: nameColor,
            ]
            nameBtn.attributedTitle = NSAttributedString(string: " \(session.name) ", attributes: attrs)
            container.addSubview(nameBtn)

            // Double-click gesture on name button for rename
            let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(tabDoubleClicked(_:)))
            doubleClick.numberOfClicksRequired = 2
            nameBtn.addGestureRecognizer(doubleClick)

            // Close button (hidden if last remaining tab)
            let closeBtn = NSButton(title: "\u{00D7}", target: self, action: #selector(closeTabClicked(_:)))
            closeBtn.tag = i
            closeBtn.translatesAutoresizingMaskIntoConstraints = false
            closeBtn.isBordered = false
            closeBtn.font = Theme.mono(10)
            closeBtn.contentTintColor = Theme.text3
            closeBtn.isHidden = !canClose
            container.addSubview(closeBtn)

            NSLayoutConstraint.activate([
                container.heightAnchor.constraint(equalToConstant: 24),

                tabDot.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
                tabDot.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                tabDot.widthAnchor.constraint(equalToConstant: 6),
                tabDot.heightAnchor.constraint(equalToConstant: 6),

                nameBtn.leadingAnchor.constraint(equalTo: needsAttention ? tabDot.trailingAnchor : container.leadingAnchor, constant: needsAttention ? 2 : 0),
                nameBtn.centerYAnchor.constraint(equalTo: container.centerYAnchor),

                closeBtn.leadingAnchor.constraint(equalTo: nameBtn.trailingAnchor, constant: -2),
                closeBtn.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
                closeBtn.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                closeBtn.widthAnchor.constraint(equalToConstant: 16),
            ])

            tabStack.addArrangedSubview(container)
            tabViews.append(container)
        }

        showActiveTerminal()
    }

    @objc private func tabClicked(_ sender: NSButton) {
        SessionManager.shared.switchTo(index: sender.tag)
    }

    @objc private func closeTabClicked(_ sender: NSButton) {
        let index = sender.tag
        SessionManager.shared.closeSession(at: index)
    }

    @objc private func tabDoubleClicked(_ sender: NSClickGestureRecognizer) {
        // Find the button that owns this gesture
        guard let nameBtn = sender.view as? NSButton else { return }
        let index = nameBtn.tag
        promptRenameSession(at: index)
    }

    /// Show an alert with a text field to rename the session.
    func promptRenameSession(at index: Int) {
        let sessions = SessionManager.shared.sessions
        guard index >= 0, index < sessions.count else { return }
        let session = sessions[index]

        let alert = NSAlert()
        alert.messageText = "Rename Session"
        alert.informativeText = "Enter a new name for \"\(session.name)\":"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        input.stringValue = session.name
        alert.accessoryView = input

        guard let win = window else { return }
        alert.beginSheetModal(for: win) { response in
            guard response == .alertFirstButtonReturn else { return }
            let newName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty else { return }
            session.name = newName
            NotificationCenter.default.post(name: .sessionsDidChange, object: nil)
        }
    }

    private func updateTabHighlights() {
        // Session state changes affect tab indicators, so do a full rebuild
        // to keep attention dots and colors in sync.
        rebuildTabs()
    }

    private func showActiveTerminal() {
        // Remove all terminal views from container
        for sub in terminalContainer.subviews {
            sub.removeFromSuperview()
        }

        guard let session = SessionManager.shared.activeSession,
              let tv = session.terminalView else {
            NSLog("[TerminalPane] showActiveTerminal: no active session or no terminalView")
            return
        }

        tv.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.addSubview(tv)

        NSLayoutConstraint.activate([
            tv.topAnchor.constraint(equalTo: terminalContainer.topAnchor),
            tv.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor),
            tv.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor),
            tv.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor),
        ])

        window?.makeFirstResponder(tv)

        NSLog("[TerminalPane] showActiveTerminal: self.frame=%@, container.frame=%@, tv.frame=%@",
              NSStringFromRect(self.frame),
              NSStringFromRect(terminalContainer.frame),
              NSStringFromRect(tv.frame))
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        if let tv = SessionManager.shared.activeSession?.terminalView {
            window?.makeFirstResponder(tv)
        }
        return true
    }
}
