import AppKit

/// Left sidebar: worktrees and toolkit.
final class DFSidebar: NSView {

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.surface1.cgColor
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

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

        let mainBranch = makeRow(icon: "arrow.triangle.branch", text: "main", detail: "base")
        addSubview(mainBranch)

        // Toolkit section
        let toolkitSep = separator()
        addSubview(toolkitSep)
        let toolkitHeader = label("TOOLKIT", size: 9, color: Theme.text3, weight: .medium)
        toolkitHeader.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toolkitHeader)

        let testRow = makeRow(icon: "checkmark.circle", text: "Run Tests", detail: nil)
        let buildRow = makeRow(icon: "hammer", text: "Build", detail: nil)
        let lintRow = makeRow(icon: "wand.and.stars", text: "Lint", detail: nil)
        addSubview(testRow)
        addSubview(buildRow)
        addSubview(lintRow)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),

            sep.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            sep.leadingAnchor.constraint(equalTo: leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: trailingAnchor),

            worktreesHeader.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 12),
            worktreesHeader.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),

            mainBranch.topAnchor.constraint(equalTo: worktreesHeader.bottomAnchor, constant: 6),
            mainBranch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            mainBranch.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            mainBranch.heightAnchor.constraint(equalToConstant: 28),

            toolkitSep.topAnchor.constraint(equalTo: mainBranch.bottomAnchor, constant: 12),
            toolkitSep.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolkitSep.trailingAnchor.constraint(equalTo: trailingAnchor),

            toolkitHeader.topAnchor.constraint(equalTo: toolkitSep.bottomAnchor, constant: 12),
            toolkitHeader.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),

            testRow.topAnchor.constraint(equalTo: toolkitHeader.bottomAnchor, constant: 6),
            testRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            testRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            testRow.heightAnchor.constraint(equalToConstant: 28),

            buildRow.topAnchor.constraint(equalTo: testRow.bottomAnchor, constant: 2),
            buildRow.leadingAnchor.constraint(equalTo: testRow.leadingAnchor),
            buildRow.trailingAnchor.constraint(equalTo: testRow.trailingAnchor),
            buildRow.heightAnchor.constraint(equalToConstant: 28),

            lintRow.topAnchor.constraint(equalTo: buildRow.bottomAnchor, constant: 2),
            lintRow.leadingAnchor.constraint(equalTo: testRow.leadingAnchor),
            lintRow.trailingAnchor.constraint(equalTo: testRow.trailingAnchor),
            lintRow.heightAnchor.constraint(equalToConstant: 28),
        ])
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
}
