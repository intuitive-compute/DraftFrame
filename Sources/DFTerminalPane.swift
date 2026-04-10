import AppKit
import SwiftTerm

/// Center pane: a real terminal using SwiftTerm's LocalProcessTerminalView.
final class DFTerminalPane: NSView {

    private var terminalView: LocalProcessTerminalView!

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg.cgColor
        setupTerminal()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupTerminal() {
        terminalView = LocalProcessTerminalView(frame: bounds)
        terminalView.translatesAutoresizingMaskIntoConstraints = false

        // Colors
        terminalView.nativeForegroundColor = Theme.text1
        terminalView.nativeBackgroundColor = Theme.bg
        terminalView.selectedTextBackgroundColor = Theme.selected
        terminalView.caretColor = Theme.accent

        // Font
        terminalView.font = Theme.mono(13)

        addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Start the shell
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let home = NSHomeDirectory()
        terminalView.startProcess(executable: shell,
                                  args: ["--login"],
                                  environment: nil,
                                  execName: nil)
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(terminalView)
        return true
    }
}
