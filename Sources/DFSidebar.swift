import AppKit

/// Left sidebar: worktrees and toolkit (functional).
final class DFSidebar: NSView {

    private let worktreeStack = NSStackView()
    private let toolkitStack = NSStackView()
    private var outputPopover: NSPopover?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.surface1.cgColor
        buildUI()

        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshWorktrees),
            name: .sessionsDidChange, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func buildUI() {
        // Title
        let title = label("DRAFTFRAME", size: 10, color: Theme.text3, weight: .medium)
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)

        // Separator
        let sep = separator()
        addSubview(sep)

        // Worktrees section
        let worktreesHeader = label("WORKTREES", size: 9, color: Theme.text3, weight: .medium)
        worktreesHeader.translatesAutoresizingMaskIntoConstraints = false
        addSubview(worktreesHeader)

        worktreeStack.orientation = .vertical
        worktreeStack.spacing = 2
        worktreeStack.alignment = .leading
        worktreeStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(worktreeStack)

        // Add worktree button
        let addWorktreeBtn = makeClickableRow(icon: "plus.circle", text: "New Worktree", detail: nil,
                                                target: self, action: #selector(addWorktreeClicked))
        addSubview(addWorktreeBtn)

        // Toolkit section
        let toolkitSep = separator()
        addSubview(toolkitSep)
        let toolkitHeader = label("TOOLKIT", size: 9, color: Theme.text3, weight: .medium)
        toolkitHeader.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toolkitHeader)

        toolkitStack.orientation = .vertical
        toolkitStack.spacing = 2
        toolkitStack.alignment = .leading
        toolkitStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toolkitStack)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),

            sep.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            sep.leadingAnchor.constraint(equalTo: leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: trailingAnchor),

            worktreesHeader.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 12),
            worktreesHeader.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),

            worktreeStack.topAnchor.constraint(equalTo: worktreesHeader.bottomAnchor, constant: 6),
            worktreeStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            worktreeStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            addWorktreeBtn.topAnchor.constraint(equalTo: worktreeStack.bottomAnchor, constant: 4),
            addWorktreeBtn.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            addWorktreeBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            addWorktreeBtn.heightAnchor.constraint(equalToConstant: 28),

            toolkitSep.topAnchor.constraint(equalTo: addWorktreeBtn.bottomAnchor, constant: 12),
            toolkitSep.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolkitSep.trailingAnchor.constraint(equalTo: trailingAnchor),

            toolkitHeader.topAnchor.constraint(equalTo: toolkitSep.bottomAnchor, constant: 12),
            toolkitHeader.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),

            toolkitStack.topAnchor.constraint(equalTo: toolkitHeader.bottomAnchor, constant: 6),
            toolkitStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            toolkitStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])

        refreshWorktrees()
        refreshToolkit()
    }

    // MARK: - Worktrees

    @objc private func refreshWorktrees() {
        for v in worktreeStack.arrangedSubviews {
            worktreeStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        let worktrees = WorktreeManager.shared.listWorktrees()
        for wt in worktrees {
            let branchName = wt.branch.isEmpty ? "detached" : wt.branch
            let isBase = wt.isBare
            let row = makeClickableRow(icon: "arrow.triangle.branch", text: branchName,
                                       detail: isBase ? "base" : nil,
                                       target: self, action: #selector(worktreeRowClicked(_:)))

            // Store worktree info for context menu
            row.worktreeName = branchName
            row.worktreePath = wt.path
            row.isBaseWorktree = isBase

            // Add right-click context menu
            let menu = NSMenu()
            if !isBase {
                let removeItem = NSMenuItem(title: "Remove Worktree", action: #selector(removeWorktreeFromMenu(_:)), keyEquivalent: "")
                removeItem.target = self
                removeItem.representedObject = wt
                menu.addItem(removeItem)

                menu.addItem(NSMenuItem.separator())
            }
            let openFinderItem = NSMenuItem(title: "Show in Finder", action: #selector(showWorktreeInFinder(_:)), keyEquivalent: "")
            openFinderItem.target = self
            openFinderItem.representedObject = wt.path
            menu.addItem(openFinderItem)

            let copyPathItem = NSMenuItem(title: "Copy Path", action: #selector(copyWorktreePath(_:)), keyEquivalent: "")
            copyPathItem.target = self
            copyPathItem.representedObject = wt.path
            menu.addItem(copyPathItem)

            row.menu = menu

            row.heightAnchor.constraint(equalToConstant: 28).isActive = true
            worktreeStack.addArrangedSubview(row)
        }

        // If no worktrees found, show at least "main"
        if worktrees.isEmpty {
            let row = makeRow(icon: "arrow.triangle.branch", text: "main", detail: "base")
            row.heightAnchor.constraint(equalToConstant: 28).isActive = true
            worktreeStack.addArrangedSubview(row)
        }
    }

    @objc private func worktreeRowClicked(_ sender: AnyObject) {
        // Click on worktree row — switch to that session if one exists
        guard let row = sender as? ClickableRow, let path = row.worktreePath else { return }
        let sessions = SessionManager.shared.sessions
        if let idx = sessions.firstIndex(where: { $0.worktreePath == path }) {
            SessionManager.shared.switchTo(index: idx)
        }
    }

    @objc private func removeWorktreeFromMenu(_ sender: NSMenuItem) {
        guard let wt = sender.representedObject as? WorktreeManager.Worktree else { return }

        let alert = NSAlert()
        alert.messageText = "Remove Worktree?"
        alert.informativeText = "This will remove the worktree at:\n\(wt.path)\n\nAny uncommitted changes will be lost."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        guard let win = window else { return }
        alert.beginSheetModal(for: win) { response in
            guard response == .alertFirstButtonReturn else { return }

            // Close any session using this worktree
            let sessions = SessionManager.shared.sessions
            if let idx = sessions.firstIndex(where: { $0.worktreePath == wt.path }) {
                SessionManager.shared.closeSession(at: idx)
            }

            // Extract the worktree name from the path
            let name = (wt.path as NSString).lastPathComponent
            do {
                try WorktreeManager.shared.removeWorktree(name: name)
            } catch {
                let errAlert = NSAlert()
                errAlert.messageText = "Remove Failed"
                errAlert.informativeText = error.localizedDescription
                errAlert.runModal()
            }
            self.refreshWorktrees()
        }
    }

    @objc private func showWorktreeInFinder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    @objc private func copyWorktreePath(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    @objc private func addWorktreeClicked() {
        let alert = NSAlert()
        alert.messageText = "New Worktree"
        alert.informativeText = "Enter a name for the new worktree branch:"
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
                // Create a session in the worktree
                SessionManager.shared.createSession(name: name, worktreePath: path)
                self.refreshWorktrees()
            } catch {
                let errAlert = NSAlert()
                errAlert.messageText = "Worktree Error"
                errAlert.informativeText = error.localizedDescription
                errAlert.runModal()
            }
        }
    }

    // MARK: - Toolkit

    private func refreshToolkit() {
        for v in toolkitStack.arrangedSubviews {
            toolkitStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        let commands = ToolkitManager.shared.commands
        for (i, cmd) in commands.enumerated() {
            let row = makeClickableRow(icon: cmd.icon, text: cmd.name, detail: nil,
                                        target: self, action: #selector(toolkitCommandClicked(_:)))
            row.toolkitIndex = i
            row.heightAnchor.constraint(equalToConstant: 28).isActive = true
            toolkitStack.addArrangedSubview(row)
        }
    }

    @objc private func toolkitCommandClicked(_ sender: AnyObject) {
        let commands = ToolkitManager.shared.commands
        let idx = (sender as? ClickableRow)?.toolkitIndex ?? 0
        guard idx >= 0, idx < commands.count else { return }
        let cmd = commands[idx]

        // Run in active session's worktree directory
        let dir = SessionManager.shared.activeSession?.worktreePath

        // Show popover with "Running..."
        let popover = NSPopover()
        popover.behavior = .transient
        let vc = NSViewController()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        container.wantsLayer = true

        let statusLabel = NSTextField(labelWithString: "Running \(cmd.name)...")
        statusLabel.font = Theme.mono(11)
        statusLabel.textColor = Theme.text2
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusLabel)

        let outputLabel = NSTextField(wrappingLabelWithString: "")
        outputLabel.font = Theme.mono(10)
        outputLabel.textColor = Theme.text1
        outputLabel.translatesAutoresizingMaskIntoConstraints = false
        outputLabel.maximumNumberOfLines = 20
        container.addSubview(outputLabel)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            outputLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            outputLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            outputLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            outputLabel.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -10),
        ])

        vc.view = container
        popover.contentViewController = vc
        popover.contentSize = NSSize(width: 300, height: 200)
        let senderView = sender as? NSView ?? self
        popover.show(relativeTo: senderView.bounds, of: senderView, preferredEdge: .maxX)
        self.outputPopover = popover

        ToolkitManager.shared.runCommand(cmd, inDirectory: dir) { output, exitCode in
            let status = exitCode == 0 ? "Completed successfully" : "Failed (exit \(exitCode))"
            statusLabel.stringValue = status
            statusLabel.textColor = exitCode == 0 ? Theme.green : Theme.red
            // Show last ~500 chars of output
            let trimmed = output.count > 500 ? String(output.suffix(500)) : output
            outputLabel.stringValue = trimmed
        }
    }

    // MARK: - Helpers

    private func label(_ text: String, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = Theme.mono(size, weight: weight)
        l.textColor = color
        return l
    }

    private func separator() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = Theme.surface3.cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return v
    }

    private func makeRow(icon: String, text: String, detail: String?) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let img = NSImageView()
        if let sysImg = NSImage(systemSymbolName: icon, accessibilityDescription: nil) {
            img.image = sysImg
            img.contentTintColor = Theme.text2
        }
        img.translatesAutoresizingMaskIntoConstraints = false

        let lbl = label(text, size: 12, color: Theme.text1)
        lbl.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(img)
        row.addSubview(lbl)

        NSLayoutConstraint.activate([
            img.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 4),
            img.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            img.widthAnchor.constraint(equalToConstant: 14),
            img.heightAnchor.constraint(equalToConstant: 14),
            lbl.leadingAnchor.constraint(equalTo: img.trailingAnchor, constant: 6),
            lbl.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])

        if let detail = detail {
            let d = label(detail, size: 10, color: Theme.text3)
            d.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(d)
            d.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -4).isActive = true
            d.centerYAnchor.constraint(equalTo: row.centerYAnchor).isActive = true
        }

        return row
    }

    private func makeClickableRow(icon: String, text: String, detail: String?,
                                   target: AnyObject?, action: Selector) -> ClickableRow {
        let row = ClickableRow(target: target, action: action)
        row.translatesAutoresizingMaskIntoConstraints = false

        let img = NSImageView()
        if let sysImg = NSImage(systemSymbolName: icon, accessibilityDescription: nil) {
            img.image = sysImg
            img.contentTintColor = Theme.text2
        }
        img.translatesAutoresizingMaskIntoConstraints = false

        let lbl = label(text, size: 12, color: Theme.text1)
        lbl.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(img)
        row.addSubview(lbl)

        NSLayoutConstraint.activate([
            img.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 4),
            img.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            img.widthAnchor.constraint(equalToConstant: 14),
            img.heightAnchor.constraint(equalToConstant: 14),
            lbl.leadingAnchor.constraint(equalTo: img.trailingAnchor, constant: 6),
            lbl.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])

        if let detail = detail {
            let d = label(detail, size: 10, color: Theme.text3)
            d.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(d)
            d.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -4).isActive = true
            d.centerYAnchor.constraint(equalTo: row.centerYAnchor).isActive = true
        }

        return row
    }
}

/// A view that acts like a button — sends action on click.
final class ClickableRow: NSView {
    weak var target: AnyObject?
    var action: Selector?
    var toolkitIndex: Int = 0
    var worktreeName: String?
    var worktreePath: String?
    var isBaseWorktree: Bool = false

    init(target: AnyObject?, action: Selector?) {
        self.target = target
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = Theme.surface3.cgColor
    }

    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
        if let action = action {
            NSApp.sendAction(action, to: target, from: self)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = Theme.surface2.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        ))
    }
}
