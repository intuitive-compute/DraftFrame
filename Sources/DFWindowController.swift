import AppKit

final class DFWindowController: NSWindowController {

    let sidebar = DFSidebar()
    let terminalPane = DFTerminalPane()
    let sessionBar = DFSessionBar()
    let statusBar = DFStatusBar()

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
        NSLayoutConstraint.activate([
            vStack.topAnchor.constraint(equalTo: contentView.topAnchor),
            vStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            vStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            vStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            sidebar.widthAnchor.constraint(equalToConstant: 220),
            sessionBar.widthAnchor.constraint(equalToConstant: 300),
            statusBar.heightAnchor.constraint(equalToConstant: 28),
        ])
    }
}
