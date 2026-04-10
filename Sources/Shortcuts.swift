import AppKit

/// Registers global keyboard shortcuts for the app.
final class ShortcutManager {
    static let shared = ShortcutManager()

    /// Callback closures set by the window controller.
    var onNewSession: (() -> Void)?
    var onCloseSession: (() -> Void)?
    var onSwitchSession: ((Int) -> Void)?
    var onToggleDashboard: (() -> Void)?
    var onNewSessionWithWorktree: (() -> Void)?
    var onToggleSidebar: (() -> Void)?

    private var monitor: Any?

    private init() {}

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            return self.handleKeyDown(event) ? nil : event
        }
    }

    func uninstall() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Cmd+T: new session
        if flags == .command, event.keyCode == 17 { // 't'
            onNewSession?()
            return true
        }

        // Cmd+W: close session
        if flags == .command, event.keyCode == 13 { // 'w'
            onCloseSession?()
            return true
        }

        // Cmd+D: toggle dashboard
        if flags == .command, event.keyCode == 2 { // 'd'
            onToggleDashboard?()
            return true
        }

        // Cmd+N: new session with worktree
        if flags == .command, event.keyCode == 45 { // 'n'
            onNewSessionWithWorktree?()
            return true
        }

        // Cmd+\: toggle sidebar
        if flags == .command, event.keyCode == 42 { // '\'
            onToggleSidebar?()
            return true
        }

        // Cmd+1 through Cmd+9: switch to session N
        if flags == .command {
            let digitKeyCodes: [UInt16: Int] = [
                18: 1, 19: 2, 20: 3, 21: 4, 23: 5,
                22: 6, 26: 7, 28: 8, 25: 9,
            ]
            if let sessionNum = digitKeyCodes[event.keyCode] {
                onSwitchSession?(sessionNum - 1)
                return true
            }
        }

        return false
    }
}
