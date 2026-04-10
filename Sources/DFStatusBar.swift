import AppKit

/// Bottom status bar: live branch, tokens, cost from SessionManager.
final class DFStatusBar: NSView {

    private var branchLabel: NSTextField!
    private var tokensLabel: NSTextField!
    private var costLabel: NSTextField!
    private var modelLabel: NSTextField!
    private var refreshTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.surface1.cgColor
        buildUI()

        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh),
            name: .sessionsDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh),
            name: .activeSessionDidChange, object: nil
        )

        // Periodic refresh for git branch and token counts
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        refreshTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    private func buildUI() {
        // Top border
        let border = NSView()
        border.wantsLayer = true
        border.layer?.backgroundColor = Theme.surface3.cgColor
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)

        let branchIcon = NSImageView()
        if let img = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil) {
            branchIcon.image = img
            branchIcon.contentTintColor = Theme.text3
        }
        branchIcon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(branchIcon)

        branchLabel = mono("main")
        tokensLabel = mono("0K tokens")
        costLabel = mono("$0.00")
        modelLabel = mono("sonnet")

        for v in [branchLabel!, tokensLabel!, costLabel!, modelLabel!] { addSubview(v) }

        // Session count indicator
        let sessionCountLabel = mono("0 sessions")
        sessionCountLabel.identifier = NSUserInterfaceItemIdentifier("sessionCount")
        addSubview(sessionCountLabel)

        NSLayoutConstraint.activate([
            border.topAnchor.constraint(equalTo: topAnchor),
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.heightAnchor.constraint(equalToConstant: 1),

            branchIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            branchIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            branchIcon.widthAnchor.constraint(equalToConstant: 12),

            branchLabel.leadingAnchor.constraint(equalTo: branchIcon.trailingAnchor, constant: 4),
            branchLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            sessionCountLabel.leadingAnchor.constraint(equalTo: branchLabel.trailingAnchor, constant: 16),
            sessionCountLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            costLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            costLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            tokensLabel.trailingAnchor.constraint(equalTo: costLabel.leadingAnchor, constant: -16),
            tokensLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            modelLabel.trailingAnchor.constraint(equalTo: tokensLabel.leadingAnchor, constant: -16),
            modelLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @objc private func refresh() {
        let mgr = SessionManager.shared

        // Branch from active session
        let branch = mgr.currentBranch()
        branchLabel.stringValue = branch

        // Active model
        if let session = mgr.activeSession {
            modelLabel.stringValue = session.model
        }

        // Aggregate tokens
        let totalIn = mgr.totalTokensIn
        let totalOut = mgr.totalTokensOut
        let inStr = formatTokens(totalIn)
        let outStr = formatTokens(totalOut)
        tokensLabel.stringValue = "\(inStr)\u{2193} \(outStr)\u{2191}"

        // Aggregate cost
        costLabel.stringValue = String(format: "$%.2f", mgr.totalCost)

        // Session count
        if let countLabel = viewWithIdentifier("sessionCount") {
            (countLabel as? NSTextField)?.stringValue = "\(mgr.sessions.count) sessions"
        }
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000.0)
        } else if count >= 1000 {
            return String(format: "%.1fK", Double(count) / 1000.0)
        }
        return "\(count)"
    }

    private func mono(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = Theme.mono(11)
        l.textColor = Theme.text3
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    private func viewWithIdentifier(_ id: String) -> NSView? {
        let target = NSUserInterfaceItemIdentifier(id)
        return subviews.first { $0.identifier == target }
    }
}
