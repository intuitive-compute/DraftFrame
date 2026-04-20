import AppKit
import SwiftTerm

/// Subclass of LocalProcessTerminalView that intercepts raw PTY data.
/// dataReceived(slice:) is the only `open` method in the data path.
class ClaudeTerminalView: LocalProcessTerminalView {
  var onPtyData: ((ArraySlice<UInt8>) -> Void)?

  override init(frame: NSRect) {
    super.init(frame: frame)
    registerForDraggedTypes([.fileURL])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func dataReceived(slice: ArraySlice<UInt8>) {
    onPtyData?(slice)
    // While the user is parked above the bottom (reading back through
    // output), new PTY data would normally snap the viewport back down.
    // Capture their row before super runs and restore it directly on the
    // buffer — **not** via scrollTo(), which forces a second full redraw
    // and makes the selection highlight flicker.
    if stickyScrollGuardActive {
      let savedYDisp = terminal.buffer.yDisp
      super.dataReceived(slice: slice)
      terminal.buffer.yDisp = savedYDisp
    } else {
      super.dataReceived(slice: slice)
    }
  }

  // MARK: - Sticky scroll guard

  /// Tracks whether the user has scrolled above the bottom of the buffer.
  /// Flipped by `scrolled(source:position:)`; consulted by `dataReceived`.
  private var stickyScrollGuardActive = false

  /// How close to the bottom we treat as "at bottom" — leaves headroom for
  /// floating-point rounding since `scrollPosition` is a computed Double.
  private static let atBottomThreshold: Double = 0.999

  open override func scrolled(source: TerminalView, position: Double) {
    super.scrolled(source: source, position: position)
    stickyScrollGuardActive = position < Self.atBottomThreshold
  }

  override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
    NSLog(
      "[ClaudeTerminalView] processTerminated exitCode=%@",
      exitCode.map(String.init) ?? "nil")
    super.processTerminated(source, exitCode: exitCode)
  }

  // MARK: - Keyboard

  private var keyMonitor: Any?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil && keyMonitor == nil {
      keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self = self, self.window?.firstResponder === self else { return event }
        // Any keypress releases the sticky scroll guard so the viewport
        // follows the cursor when the user starts typing or submits.
        self.stickyScrollGuardActive = false
        // Shift+Enter: send newline (LF) instead of carriage return (CR)
        // so Claude Code inserts a line break rather than submitting.
        if event.keyCode == 36 && event.modifierFlags.contains(.shift) {
          self.send(txt: "\n")
          return nil
        }
        return event
      }
      installMouseMonitor()
    } else if window == nil, let monitor = keyMonitor {
      NSEvent.removeMonitor(monitor)
      keyMonitor = nil
      removeMouseMonitor()
    }
  }

  // MARK: - Cmd+Click PR/Issue References

  /// Regex matching `#123` or `owner/repo#123` patterns.
  private static let prPattern = try! NSRegularExpression(
    pattern: #"(?:[\w.-]+/[\w.-]+)?#\d+"#)

  private var mouseMonitor: Any?

  private func installMouseMonitor() {
    guard mouseMonitor == nil else { return }
    mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
      guard let self = self,
        self.window?.firstResponder === self,
        event.modifierFlags.contains(.command)
      else { return event }

      if let url = self.prURLAtClick(event: event) {
        NSWorkspace.shared.open(url)
        return nil
      }
      return event
    }
  }

  private func removeMouseMonitor() {
    if let monitor = mouseMonitor {
      NSEvent.removeMonitor(monitor)
      mouseMonitor = nil
    }
  }

  private func prURLAtClick(event: NSEvent) -> URL? {
    // Convert window coordinates to view coordinates, then to a grid column.
    let localPoint = convert(event.locationInWindow, from: nil)
    guard bounds.contains(localPoint) else { return nil }

    let term = getTerminal()
    guard term.rows > 0, term.cols > 0 else { return nil }

    // Derive cell dimensions from the view bounds and terminal grid size.
    let cellWidth = bounds.width / CGFloat(term.cols)
    let cellHeight = bounds.height / CGFloat(term.rows)
    let col = Int(localPoint.x / cellWidth)
    let row = Int((bounds.height - localPoint.y) / cellHeight)
    guard row >= 0, row < term.rows else { return nil }
    guard let line = term.getLine(row: row) else { return nil }

    let text = line.translateToString(trimRight: true)
    let nsText = text as NSString
    let matches = Self.prPattern.matches(
      in: text, range: NSRange(location: 0, length: nsText.length))

    for match in matches {
      guard match.range.location != NSNotFound else { continue }
      let matchStart = match.range.location
      let matchEnd = matchStart + match.range.length
      guard col >= matchStart, col < matchEnd else { continue }

      let matched = nsText.substring(with: match.range)
      if let url = resolveGitHubURL(for: matched) {
        return url
      }
    }
    return nil
  }

  /// Turn `#123` or `owner/repo#123` into a GitHub pull URL.
  private func resolveGitHubURL(for ref: String) -> URL? {
    if ref.contains("/") {
      // Fully qualified: owner/repo#123
      let parts = ref.split(separator: "#", maxSplits: 1)
      guard parts.count == 2, let number = Int(parts[1]) else { return nil }
      return URL(string: "https://github.com/\(parts[0])/pull/\(number)")
    }

    // Bare #123 — resolve from the session's git remote
    guard let number = Int(ref.dropFirst()) else { return nil }
    guard let slug = gitHubSlug() else { return nil }
    return URL(string: "https://github.com/\(slug)/pull/\(number)")
  }

  /// Derive `owner/repo` from the git remote of the active session's worktree.
  private func gitHubSlug() -> String? {
    let dir =
      SessionManager.shared.activeSession?.worktreePath
      ?? SessionManager.shared.projectDir
    guard let dir = dir else { return nil }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    proc.arguments = ["-C", dir, "remote", "get-url", "origin"]
    proc.environment = ProcessInfo.processInfo.environment
      .filter { !$0.key.hasPrefix("GIT_") }
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    do {
      try proc.run()
      proc.waitUntilExit()
      guard proc.terminationStatus == 0 else { return nil }
    } catch { return nil }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard
      let raw = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    else { return nil }

    return Self.parseGitHubSlug(from: raw)
  }

  /// Extract `owner/repo` from a GitHub remote URL.
  static func parseGitHubSlug(from remote: String) -> String? {
    // SSH:   git@github.com:owner/repo.git
    // HTTPS: https://github.com/owner/repo.git
    let patterns = [
      #"github\.com[:/]([\w.\-]+/[\w.\-]+?)(?:\.git)?$"#
    ]
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      let range = NSRange(remote.startIndex..., in: remote)
      if let match = regex.firstMatch(in: remote, range: range),
        let slugRange = Range(match.range(at: 1), in: remote)
      {
        return String(remote[slugRange])
      }
    }
    return nil
  }

  // MARK: - Drag and Drop

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [
      .urlReadingFileURLsOnly: true
    ]
    guard
      sender.draggingPasteboard.canReadObject(
        forClasses: [NSURL.self],
        options: options
      )
    else {
      return []
    }
    return .copy
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [
      .urlReadingFileURLsOnly: true
    ]
    guard
      let urls = sender.draggingPasteboard.readObjects(
        forClasses: [NSURL.self],
        options: options
      ) as? [URL]
    else {
      return false
    }

    let paths = urls.map { $0.path }
    guard !paths.isEmpty else { return false }

    // Send paths as a bracketed paste so Claude Code treats the drop the
    // same way iTerm2 does — it detects image file paths and renders them
    // as [Image #N], and attaches other files as context.
    let text = paths.joined(separator: " ")
    if terminal.bracketedPasteMode {
      send(data: EscapeSequences.bracketedPasteStart[0...])
      send(txt: text)
      send(data: EscapeSequences.bracketedPasteEnd[0...])
    } else {
      send(txt: text)
    }
    return true
  }
}
