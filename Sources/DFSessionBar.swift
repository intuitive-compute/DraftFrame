import AppKit

/// Right sidebar: session cards with live status.
final class DFSessionBar: NSView {

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.surface1.cgColor
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

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

        // Mock session cards
        let card1 = SessionCard(name: "main", status: .generating, model: "opus", cost: 0.42)
        let card2 = SessionCard(name: "fix-tests", status: .thinking, model: "sonnet", cost: 0.07)
        let card3 = SessionCard(name: "api-docs", status: .idle, model: "sonnet", cost: 0.15)

        let stack = NSStackView(views: [card1, card2, card3])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            sep.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            sep.leadingAnchor.constraint(equalTo: leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: trailingAnchor),
            sep.heightAnchor.constraint(equalToConstant: 1),
            stack.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
    }
}

// MARK: - Session Card

enum SessionStatus {
    case generating, thinking, userInput, needsAttention, idle

    var color: NSColor {
        switch self {
        case .generating:     return Theme.green
        case .thinking:       return Theme.yellow
        case .userInput:      return Theme.accent
        case .needsAttention: return Theme.red
        case .idle:           return Theme.cyan
        }
    }

    var label: String {
        switch self {
        case .generating:     return "Generating"
        case .thinking:       return "Thinking"
        case .userInput:      return "Input"
        case .needsAttention: return "Attention"
        case .idle:           return "Idle"
        }
    }
}

final class SessionCard: NSView {

    init(name: String, status: SessionStatus, model: String, cost: Double) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = Theme.surface2.cgColor
        layer?.cornerRadius = 8

        // Avatar
        let avatar = PixelAvatar(seed: name)
        avatar.translatesAutoresizingMaskIntoConstraints = false

        // Name
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = Theme.mono(12, weight: .medium)
        nameLabel.textColor = Theme.text1
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        // Status dot + label
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = status.color.cgColor
        dot.layer?.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false

        let statusLabel = NSTextField(labelWithString: status.label)
        statusLabel.font = Theme.mono(9, weight: .medium)
        statusLabel.textColor = status.color
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        // Model
        let modelLabel = NSTextField(labelWithString: model)
        modelLabel.font = Theme.mono(9)
        modelLabel.textColor = Theme.text3
        modelLabel.translatesAutoresizingMaskIntoConstraints = false

        // Cost
        let costLabel = NSTextField(labelWithString: String(format: "$%.2f", cost))
        costLabel.font = Theme.mono(11)
        costLabel.textColor = Theme.text2
        costLabel.translatesAutoresizingMaskIntoConstraints = false

        for v in [avatar, nameLabel, dot, statusLabel, modelLabel, costLabel] {
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

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
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
