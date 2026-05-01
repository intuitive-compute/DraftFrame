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

  // MARK: - Live Dictation (NSTextInputClient)
  //
  // Required to make macOS system Dictation deliver text to the terminal.
  // SwiftTerm's default NSTextInputClient stubs (`selectedRange`/`markedRange`
  // returning {NSNotFound, 0}, `attributedSubstring` returning nil, missing
  // geometry probes) make macOS 14+ dictation abort before showing the mic
  // UI. The overrides below supply the minimum stable values the probe
  // needs, plus a streaming `setMarkedText` that writes the composition to
  // the PTY live with backspace revisions — SwiftTerm's default is a no-op.

  /// Synthetic caret offset. Terminals have no document offset, but
  /// dictation's geometry probe rejects any NSNotFound location outright.
  private static let cursorLocation: Int = 0

  override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
  override func isAccessibilityElement() -> Bool { true }
  override func accessibilityValue() -> Any? { "" }
  override func accessibilitySelectedText() -> String? { "" }
  override func accessibilityNumberOfCharacters() -> Int { 0 }
  override func accessibilityInsertionPointLineNumber() -> Int { 0 }

  override func accessibilityVisibleCharacterRange() -> NSRange {
    NSRange(location: 0, length: 0)
  }

  override func accessibilitySelectedTextRange() -> NSRange {
    NSRange(location: Self.cursorLocation, length: 0)
  }

  /// Dictation sometimes commits by setting the AX value/selected-text
  /// instead of calling `insertText`; forward both into the PTY.
  override func setAccessibilityValue(_ accessibilityValue: Any?) {
    forwardDictatedCommit(accessibilityValue)
  }
  override func setAccessibilitySelectedText(_ accessibilitySelectedText: String?) {
    forwardDictatedCommit(accessibilitySelectedText)
  }
  override func setAccessibilitySelectedTextRange(_ range: NSRange) {}

  override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
    let name = NSStringFromSelector(selector)
    if name == "setAccessibilityValue:"
      || name == "setAccessibilitySelectedText:"
      || name == "setAccessibilitySelectedTextRange:"
    {
      return true
    }
    return super.isAccessibilitySelectorAllowed(selector)
  }

  override func selectedRange() -> NSRange {
    NSRange(location: Self.cursorLocation, length: 0)
  }

  override func attributedSubstring(
    forProposedRange range: NSRange, actualRange: NSRangePointer?
  ) -> NSAttributedString? {
    actualRange?.pointee = NSRange(location: Self.cursorLocation, length: 0)
    return NSAttributedString(string: "")
  }

  override func characterIndex(for point: NSPoint) -> Int {
    Self.cursorLocation
  }

  override func firstRect(
    forCharacterRange range: NSRange, actualRange: NSRangePointer?
  ) -> NSRect {
    var r = super.firstRect(forCharacterRange: range, actualRange: actualRange)
    if range.length == 0 { r.size.width = 0 }
    return r
  }

  override func validAttributesForMarkedText() -> [NSAttributedString.Key] {
    [.foregroundColor, .backgroundColor, .underlineStyle, .underlineColor]
  }

  // macOS 14+ probes these via reflection as part of its geometry pass.
  // Must return screen coordinates; a nil/0 return makes the probe abort.

  @objc func attributedString() -> NSAttributedString {
    NSAttributedString(string: "")
  }

  @objc func windowLevel() -> Int {
    window?.level.rawValue ?? NSWindow.Level.normal.rawValue
  }

  @objc func unionRectInVisibleSelectedRange() -> NSRect {
    firstRect(forCharacterRange: selectedRange(), actualRange: nil)
  }

  /// Deliberate coordinate-space mismatch with NSView's usual
  /// `documentVisibleRect`: dictation expects screen coords here.
  @objc var documentVisibleRect: NSRect {
    guard let win = window else { return visibleRect }
    return win.convertToScreen(convert(visibleRect, to: nil))
  }

  private var markedCompositionLength: Int = 0

  private static func extractString(_ any: Any?) -> String {
    guard let any = any else { return "" }
    if let s = any as? String { return s }
    if let s = any as? NSString { return s as String }
    if let s = any as? NSAttributedString { return s.string }
    return ""
  }

  private func forwardDictatedCommit(_ any: Any?) {
    let s = Self.extractString(any)
    guard !s.isEmpty else { return }
    insertText(s, replacementRange: NSRange(location: NSNotFound, length: 0))
  }

  private func sendBackspaces(_ count: Int) {
    guard count > 0 else { return }
    // 0x7F (DEL) matches what SwiftTerm's keyDown path emits for Backspace.
    send(txt: String(repeating: "\u{7F}", count: count))
  }

  override func hasMarkedText() -> Bool {
    markedCompositionLength > 0
  }

  override func markedRange() -> NSRange {
    NSRange(location: Self.cursorLocation, length: markedCompositionLength)
  }

  override func setMarkedText(
    _ string: Any, selectedRange: NSRange, replacementRange: NSRange
  ) {
    let newText = Self.extractString(string)
    sendBackspaces(markedCompositionLength)
    if !newText.isEmpty {
      send(txt: newText)
    }
    markedCompositionLength = newText.count

    super.setMarkedText(
      string, selectedRange: selectedRange, replacementRange: replacementRange)
  }

  override func unmarkText() {
    markedCompositionLength = 0
    super.unmarkText()
  }

  override func insertText(_ string: Any, replacementRange: NSRange) {
    let newText = Self.extractString(string)
    // Skip the erase+reinsert cycle when dictation commits exactly the text
    // we already streamed — avoids a visible flicker.
    if markedCompositionLength > 0 && newText.count == markedCompositionLength {
      markedCompositionLength = 0
      return
    }
    sendBackspaces(markedCompositionLength)
    markedCompositionLength = 0
    super.insertText(string, replacementRange: replacementRange)
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
      installScrollMonitor()
    } else if window == nil, let monitor = keyMonitor {
      NSEvent.removeMonitor(monitor)
      keyMonitor = nil
      removeMouseMonitor()
      removeScrollMonitor()
    }
  }

  // MARK: - Alt-screen scroll translation
  //
  // Claude Code's fullscreen TUI (and other alt-screen apps like less/vim)
  // own the screen directly — there's no scrollback to move through on the
  // alternate buffer. SwiftTerm's built-in scrollWheel drives its own
  // scrollback regardless, which does nothing visible on alt-screen. Claude
  // Code binds transcript scrolling to PageUp/PageDown (Up/Down in the
  // input box cycles prompt history), so translate wheel events to those
  // via a local event monitor — we can't subclass-override `scrollWheel`
  // because SwiftTerm declared it non-open.

  private var scrollMonitor: Any?
  private var altScrollAccumulator: CGFloat = 0

  /// Floor for per-page trackpad gesture distance so tiny twitches don't
  /// trigger a page jump on high-DPI displays with small font sizes.
  private static let minPreciseScrollStep: CGFloat = 24
  /// Ceiling on pages emitted per single wheel event — a hard fling
  /// otherwise sends a double-digit burst that scrolls past everything.
  private static let maxPagesPerEvent = 3

  private func installScrollMonitor() {
    guard scrollMonitor == nil else { return }
    scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
      [weak self] event in
      guard let self = self,
        event.window === self.window,
        self.terminal?.isCurrentBufferAlternate == true
      else { return event }

      let localPoint = self.convert(event.locationInWindow, from: nil)
      guard self.bounds.contains(localPoint) else { return event }

      let dy = event.scrollingDeltaY
      guard dy != 0 else { return nil }

      // Each step emits one PageUp/PageDown, which Claude Code's TUI treats
      // as half-a-viewport of transcript scroll. Require ~2 line-heights of
      // trackpad gesture per page so a small nudge doesn't leap pages.
      let lineHeight = max(
        self.bounds.height / max(CGFloat(self.terminal.rows), 1), 1)
      let perStep: CGFloat =
        event.hasPreciseScrollingDeltas
        ? max(lineHeight * 2, Self.minPreciseScrollStep) : 1
      self.altScrollAccumulator += dy
      let rawSteps = Int(
        (self.altScrollAccumulator / perStep).rounded(.towardZero))
      guard rawSteps != 0 else { return nil }
      self.altScrollAccumulator -= CGFloat(rawSteps) * perStep

      let cap = Self.maxPagesPerEvent
      let steps = max(-cap, min(cap, rawSteps))
      let seq: [UInt8] =
        steps > 0 ? EscapeSequences.cmdPageUp : EscapeSequences.cmdPageDown
      let count = abs(steps)
      var bytes: [UInt8] = []
      bytes.reserveCapacity(seq.count * count)
      for _ in 0..<count { bytes.append(contentsOf: seq) }
      self.send(bytes)
      return nil
    }
  }

  private func removeScrollMonitor() {
    if let monitor = scrollMonitor {
      NSEvent.removeMonitor(monitor)
      scrollMonitor = nil
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

  // MARK: - Right-click context menu

  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = NSMenu()
    let copyItem = NSMenuItem(
      title: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
    copyItem.target = self
    let pasteItem = NSMenuItem(
      title: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
    pasteItem.target = self
    menu.addItem(copyItem)
    menu.addItem(pasteItem)
    menu.addItem(NSMenuItem.separator())
    let selectAllItem = NSMenuItem(
      title: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
    selectAllItem.target = self
    menu.addItem(selectAllItem)
    return menu
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
