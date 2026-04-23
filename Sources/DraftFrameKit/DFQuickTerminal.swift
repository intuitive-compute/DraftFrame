import AppKit
import SwiftTerm

/// Floating quick-terminal window — a plain shell rooted at the current
/// project directory. Toggled with Cmd+` (backtick). The shell persists
/// across show/hide so commands in progress keep running.
final class DFQuickTerminal {
  static let shared = DFQuickTerminal()

  private var window: NSWindow?
  private var terminalView: ClaudeTerminalView?

  private init() {}

  /// Show the quick terminal if hidden, hide it if currently visible and key.
  /// If visible but not key (user clicked the main window), re-focus it
  /// instead of hiding — avoids requiring a double Cmd+` to get it back.
  func toggle() {
    if let win = window, win.isVisible {
      if win.isKeyWindow {
        win.orderOut(nil)
      } else {
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let tv = terminalView {
          win.makeFirstResponder(tv)
        }
      }
    } else {
      show()
    }
  }

  func show() {
    if window == nil {
      buildWindow()
    }
    guard let win = window else { return }
    positionAtTop(of: win)
    win.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    if let tv = terminalView {
      win.makeFirstResponder(tv)
      // cd to the active session's directory so the quick terminal always
      // reflects the project the user is currently working in.
      let dir =
        SessionManager.shared.activeSession?.worktreePath
        ?? SessionManager.shared.projectDir
      if let dir = dir {
        tv.send(txt: "cd \(shellEscape(dir)) && clear\r")
      }
    }
  }

  func hide() {
    window?.orderOut(nil)
  }

  // MARK: - Window setup

  private func buildWindow() {
    let contentRect = NSRect(x: 0, y: 0, width: 900, height: 340)
    let win = NSWindow(
      contentRect: contentRect,
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    win.title = "Quick Terminal"
    win.titlebarAppearsTransparent = true
    win.titleVisibility = .hidden
    win.backgroundColor = Theme.bg
    win.isMovableByWindowBackground = false
    win.hidesOnDeactivate = true
    win.level = .normal
    win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    win.isReleasedWhenClosed = false
    win.minSize = NSSize(width: 500, height: 200)

    let container = NSView(frame: contentRect)
    container.wantsLayer = true
    container.layer?.backgroundColor = Theme.bg.cgColor
    win.contentView = container

    // Inset the terminal below the transparent titlebar so content doesn't
    // render behind the traffic lights.
    let titlebarInset: CGFloat = 28
    let tv = ClaudeTerminalView(frame: .zero)
    tv.translatesAutoresizingMaskIntoConstraints = false
    tv.nativeForegroundColor = Theme.text1
    tv.nativeBackgroundColor = Theme.bg
    tv.selectedTextBackgroundColor = Theme.selected
    tv.caretColor = Theme.accent
    tv.font = Theme.mono(13)
    container.addSubview(tv)
    NSLayoutConstraint.activate([
      tv.topAnchor.constraint(equalTo: container.topAnchor, constant: titlebarInset),
      tv.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
      tv.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
      tv.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
    ])
    terminalView = tv

    startShell(in: tv)

    self.window = win
  }

  private func startShell(in tv: ClaudeTerminalView) {
    let parentEnv = ProcessInfo.processInfo.environment
    let shell = SessionManager.resolveShellPath(parentEnv: parentEnv)

    // Match the PATH composition used for Claude sessions so tools installed
    // via Homebrew are available here too.
    let homebrewPaths = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]
    let inheritedPath = parentEnv["PATH"] ?? ""
    let inheritedParts = inheritedPath.split(separator: ":").map(String.init)
    let composedPath = (homebrewPaths.filter { !inheritedParts.contains($0) } + inheritedParts)
      .joined(separator: ":")

    var envDict: [String: String] = [
      "TERM": "xterm-256color",
      "COLORTERM": "truecolor",
      "LANG": parentEnv["LANG"] ?? "en_US.UTF-8",
      "PATH": composedPath,
      "SHELL": shell,
      "HOME": parentEnv["HOME"] ?? NSHomeDirectory(),
      "USER": parentEnv["USER"] ?? NSUserName(),
      "LOGNAME": parentEnv["LOGNAME"] ?? NSUserName(),
    ]
    for key in ["LC_ALL", "LC_CTYPE", "TMPDIR", "TZ", "DISPLAY"] {
      if let v = parentEnv[key] { envDict[key] = v }
    }
    let env: [String] = envDict.map { "\($0.key)=\($0.value)" }

    tv.startProcess(
      executable: shell,
      args: ["--login"],
      environment: env,
      execName: nil)

    // cd into the current project directory so the quick terminal opens
    // rooted where the user is working.
    if let dir = SessionManager.shared.projectDir {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        tv.send(txt: "cd \(shellEscape(dir)) && clear\r")
      }
    }
  }

  /// Anchor the window near the top-center of the main window's screen so it
  /// behaves like a drop-down quick terminal.
  private func positionAtTop(of win: NSWindow) {
    let screen = NSApp.mainWindow?.screen ?? win.screen ?? NSScreen.main
    guard let frame = screen?.visibleFrame else { return }
    let size = win.frame.size
    let x = frame.midX - size.width / 2
    let y = frame.maxY - size.height - 20
    win.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
  }
}

/// Quote a path so it survives a single-line shell command.
private func shellEscape(_ path: String) -> String {
  "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
