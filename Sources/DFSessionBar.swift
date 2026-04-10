import AppKit

/// Right sidebar: session cards with live status, driven by SessionManager.
final class DFSessionBar: NSView {

    private let cardStack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.surface1.cgColor
        buildUI()

        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionsChanged),
            name: .sessionsDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionsChanged),
            name: .activeSessionDidChange, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func sessionsChanged() {
        refreshCards()
    }

    private func buildUI() {
        let title = NSTextField(labelWithString: "SESSIONS")
        title.font = Theme.mono(10, weight: .medium)
        title.textColor = Theme.text3
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)

        let sep = NSView()
        sep.wantsLayer = true
        sep.layer?.backgroundColor = Theme.surface3.cgColor
        sep.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sep)

        cardStack.orientation = .vertical
        cardStack.spacing = 6
        cardStack.alignment = .leading
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cardStack)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 38),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            sep.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            sep.leadingAnchor.constraint(equalTo: leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: trailingAnchor),
            sep.heightAnchor.constraint(equalToConstant: 1),
            cardStack.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 8),
            cardStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            cardStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
    }

    private func refreshCards() {
        // Remove existing cards
        for view in cardStack.arrangedSubviews {
            cardStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let sessions = SessionManager.shared.sessions
        let activeIdx = SessionManager.shared.activeSessionIndex

        if sessions.isEmpty {
            let empty = NSTextField(labelWithString: "No sessions.\nCmd+T to create one.")
            empty.font = Theme.mono(10)
            empty.textColor = Theme.text3
            empty.maximumNumberOfLines = 2
            empty.translatesAutoresizingMaskIntoConstraints = false
            cardStack.addArrangedSubview(empty)
            return
        }

        for (i, session) in sessions.enumerated() {
            let card = SessionCard(session: session, isActive: i == activeIdx, index: i)
            card.translatesAutoresizingMaskIntoConstraints = false
            card.widthAnchor.constraint(equalToConstant: 284).isActive = true
            cardStack.addArrangedSubview(card)
        }
    }
}

// MARK: - Session Card (Live Data)

final class SessionCard: NSView {

    private let session: Session
    private let index: Int
    private var glowLayer: CALayer?

    init(session: Session, isActive: Bool, index: Int) {
        self.session = session
        self.index = index
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = Theme.surface2.cgColor
        layer?.cornerRadius = 8

        if isActive {
            layer?.borderColor = Theme.selectedBorder.cgColor
            layer?.borderWidth = 1
        }

        // Pulsing border glow for attention/input states
        let needsPulse = session.state == .needsAttention || session.state == .userInput
        if needsPulse {
            let glow = CALayer()
            glow.cornerRadius = 8
            glow.borderWidth = 1.5
            glow.borderColor = session.state.color.cgColor
            glow.frame = bounds
            glow.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer?.addSublayer(glow)
            glowLayer = glow

            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.3
            pulse.toValue = 1.0
            pulse.duration = 1.4
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glow.add(pulse, forKey: "borderPulse")
        }

        buildCard()

        // Click to switch
        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        addGestureRecognizer(click)

        // Double-click to rename
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(doubleClicked))
        doubleClick.numberOfClicksRequired = 2
        addGestureRecognizer(doubleClick)

        // On macOS, single-click fires alongside double-click; the session
        // switch is idempotent so this is acceptable behavior.
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func clicked() {
        SessionManager.shared.switchTo(index: index)
    }

    @objc private func doubleClicked() {
        let alert = NSAlert()
        alert.messageText = "Rename Session"
        alert.informativeText = "Enter a new name for \"\(session.name)\":"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        input.stringValue = session.name
        alert.accessoryView = input

        guard let win = window else { return }
        alert.beginSheetModal(for: win) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self = self else { return }
            let newName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty else { return }
            self.session.name = newName
            NotificationCenter.default.post(name: .sessionsDidChange, object: nil)
        }
    }

    private func buildCard() {
        // Avatar
        let avatar = PixelAvatar(seed: session.name)
        avatar.translatesAutoresizingMaskIntoConstraints = false

        // Name
        let nameLabel = NSTextField(labelWithString: session.name)
        nameLabel.font = Theme.mono(12, weight: .medium)
        nameLabel.textColor = Theme.text1
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        // Status dot + label
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = session.state.color.cgColor
        dot.layer?.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false

        // Breathing pulse on the dot for attention/input states
        if session.state == .needsAttention || session.state == .userInput {
            let dotPulse = CABasicAnimation(keyPath: "opacity")
            dotPulse.fromValue = 0.35
            dotPulse.toValue = 1.0
            dotPulse.duration = 1.4
            dotPulse.autoreverses = true
            dotPulse.repeatCount = .infinity
            dotPulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.layer?.add(dotPulse, forKey: "dotPulse")

            // Soft glow shadow behind the dot
            dot.layer?.shadowColor = session.state.color.cgColor
            dot.layer?.shadowOffset = .zero
            dot.layer?.shadowRadius = 6
            dot.layer?.shadowOpacity = 0.8
            dot.layer?.masksToBounds = false
        }

        let statusLabel = NSTextField(labelWithString: session.state.label)
        statusLabel.font = Theme.mono(9, weight: .medium)
        statusLabel.textColor = session.state.color
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        // Model
        let modelLabel = NSTextField(labelWithString: session.model)
        modelLabel.font = Theme.mono(9)
        modelLabel.textColor = Theme.text3
        modelLabel.translatesAutoresizingMaskIntoConstraints = false

        // Cost
        let costLabel = NSTextField(labelWithString: String(format: "$%.2f", session.cost))
        costLabel.font = Theme.mono(11)
        costLabel.textColor = Theme.text2
        costLabel.translatesAutoresizingMaskIntoConstraints = false

        for v in [avatar, nameLabel, dot, statusLabel, modelLabel, costLabel] as [NSView] {
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 56),

            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            avatar.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            avatar.widthAnchor.constraint(equalToConstant: 32),
            avatar.heightAnchor.constraint(equalToConstant: 32),

            nameLabel.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 8),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),

            costLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            costLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),

            dot.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 8),
            dot.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 5),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),

            statusLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 4),
            statusLabel.centerYAnchor.constraint(equalTo: dot.centerYAnchor),

            modelLabel.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 8),
            modelLabel.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
        ])
    }
}

// MARK: - Pixel Avatar

final class PixelAvatar: NSView {
    let seed: String

    init(seed: String) {
        self.seed = seed
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let grid = 6
        let cellW = bounds.width / CGFloat(grid)
        let cellH = bounds.height / CGFloat(grid)

        var hash: UInt64 = 5381
        for byte in seed.utf8 { hash = ((hash &<< 5) &+ hash) &+ UInt64(byte) }

        let hue = CGFloat(hash % 360) / 360.0
        let colors = [
            NSColor(hue: hue, saturation: 0.6, brightness: 0.9, alpha: 1),
            NSColor(hue: (hue + 0.15).truncatingRemainder(dividingBy: 1), saturation: 0.5, brightness: 0.7, alpha: 1),
            Theme.surface2,
        ]

        var rng = hash
        for row in 0..<grid {
            for col in 0..<(grid / 2 + 1) {
                rng = rng &* 6364136223846793005 &+ 1442695040888963407
                let c = colors[Int(rng >> 32) % colors.count]
                ctx.setFillColor(c.cgColor)
                ctx.fill(CGRect(x: CGFloat(col) * cellW, y: CGFloat(row) * cellH, width: cellW, height: cellH))
                let mirror = grid - 1 - col
                if mirror != col {
                    ctx.fill(CGRect(x: CGFloat(mirror) * cellW, y: CGFloat(row) * cellH, width: cellW, height: cellH))
                }
            }
        }
    }
}
