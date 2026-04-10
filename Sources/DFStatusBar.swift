import AppKit

/// Bottom status bar: branch, tokens, cost.
final class DFStatusBar: NSView {

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.surface1.cgColor
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

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

        let branch = mono("main")
        let tokens = mono("35.0K↓ 9.2K↑")
        let cost = mono("$0.97")
        let model = mono("sonnet")

        for v in [branch, tokens, cost, model] { addSubview(v) }

        NSLayoutConstraint.activate([
            border.topAnchor.constraint(equalTo: topAnchor),
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.heightAnchor.constraint(equalToConstant: 1),

            branchIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            branchIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            branchIcon.widthAnchor.constraint(equalToConstant: 12),

            branch.leadingAnchor.constraint(equalTo: branchIcon.trailingAnchor, constant: 4),
            branch.centerYAnchor.constraint(equalTo: centerYAnchor),

            cost.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            cost.centerYAnchor.constraint(equalTo: centerYAnchor),

            tokens.trailingAnchor.constraint(equalTo: cost.leadingAnchor, constant: -16),
            tokens.centerYAnchor.constraint(equalTo: centerYAnchor),

            model.trailingAnchor.constraint(equalTo: tokens.leadingAnchor, constant: -16),
            model.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func mono(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = Theme.mono(11)
        l.textColor = Theme.text3
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }
}
