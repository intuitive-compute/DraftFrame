import AppKit
import SwiftTerm

/// Subclass of LocalProcessTerminalView that intercepts raw PTY data.
/// dataReceived(slice:) is the only `open` method in the data path.
class ClaudeTerminalView: LocalProcessTerminalView {
  var onPtyData: ((ArraySlice<UInt8>) -> Void)?
  var onProcessExit: ((Int32?) -> Void)?

  override init(frame: NSRect) {
    super.init(frame: frame)
    registerForDraggedTypes([.fileURL])
    // SwiftTerm cancels the active selection on every PTY feed and on every
    // linefeed when allowMouseReporting is true (its default). Claude Code's
    // TUI streams continuously, so leaving this on means selection drops
    // within milliseconds of the model starting to think or stream. We don't
    // need raw mouse forwarding into Claude — it's keyboard-driven, and our
    // Cmd+Click PR refs and trackpad-scroll translation use independent
    // local event monitors.
    allowMouseReporting = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func dataReceived(slice: ArraySlice<UInt8>) {
    onPtyData?(slice)
    // While the user is parked above the bottom (reading back through
    // output), new PTY data would normally snap the viewport back down:
    // SwiftTerm's internal handling calls scrollTo(newBottom) as lines are
    // appended, which both renders the view at the bottom and (via the
    // scrolled() delegate) trips our sticky-scroll guard off — so every
    // subsequent chunk would also jump. Save the user's row, suppress
    // guard updates for any scrolled() callbacks fired from inside super,
    // then re-render at the saved row with scrollTo() so the user's
    // viewport actually moves back. The flicker concern from the older
    // direct-yDisp write approach is real but unavoidable: without a
    // re-render the screen sticks at whatever super last drew.
    let savedYDisp = terminal.buffer.yDisp
    let wasGuarded = stickyScrollGuardActive
    suppressGuardUpdates = wasGuarded
    super.dataReceived(slice: slice)
    suppressGuardUpdates = false
    if wasGuarded && terminal.buffer.yDisp != savedYDisp {
      scrollTo(row: savedYDisp)
    }
    // New output may have added/changed/scrolled blockquotes; re-pin the buttons.
    scheduleBlockButtonRefresh()
  }

  // MARK: - Sticky scroll guard

  /// Tracks whether the user has scrolled above the bottom of the buffer.
  /// Flipped by `scrolled(source:position:)`; consulted by `dataReceived`.
  private var stickyScrollGuardActive = false

  /// True while we're inside `dataReceived`; gates out `scrolled()`
  /// callbacks SwiftTerm fires when its own auto-follow walks `yDisp`
  /// to the new bottom. Without this guard, every streaming chunk would
  /// silently unset `stickyScrollGuardActive`.
  private var suppressGuardUpdates = false

  /// How close to the bottom we treat as "at bottom" — leaves headroom for
  /// floating-point rounding since `scrollPosition` is a computed Double.
  private static let atBottomThreshold: Double = 0.999

  open override func scrolled(source: TerminalView, position: Double) {
    super.scrolled(source: source, position: position)
    // Scrolling moves blockquotes to new rows; re-pin the copy buttons.
    scheduleBlockButtonRefresh()
    if suppressGuardUpdates { return }
    stickyScrollGuardActive = position < Self.atBottomThreshold
  }

  /// True for keys SwiftTerm (or AppKit) routes to local scrollback
  /// navigation on the primary buffer rather than sending to the PTY.
  /// We must not snap-to-bottom for these or PageUp would visibly bounce
  /// to the bottom before scrolling up.
  private static func isLocalScrollKey(_ event: NSEvent) -> Bool {
    switch event.specialKey {
    case .some(.pageUp), .some(.pageDown), .some(.home), .some(.end):
      return true
    default:
      return false
    }
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
    onProcessExit?(exitCode)
  }

  // MARK: - Keyboard

  private var keyMonitor: Any?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil && keyMonitor == nil {
      keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        // Match on event.window too — a hidden quick terminal keeps its
        // first-responder status, and without this check its monitor would
        // swallow keystrokes typed into other windows.
        guard let self = self, event.window === self.window,
          self.window?.firstResponder === self
        else { return event }
        // A PTY input keypress releases the sticky scroll guard and snaps
        // the viewport to the bottom. SwiftTerm's `send()` already calls
        // `ensureCaretIsVisible`, but that's a no-op when the user has only
        // scrolled up a row or two and the cursor is still inside the
        // viewport — Ink redraws Claude's input field at rows near yBase
        // that fall just below the visible region, so typed characters
        // land in the buffer invisibly. Force yDisp back to yBase here.
        // Skip for PageUp/PageDown/Home/End so SwiftTerm's local scroll
        // navigation on the primary buffer still works, and skip for
        // ⌘-modified shortcuts (⌘C, ⌘V, ⌘A, …) which AppKit dispatches
        // via menu items rather than the PTY — those should leave the
        // user's scroll position alone.
        if !Self.isLocalScrollKey(event)
          && !event.modifierFlags.contains(.command)
        {
          self.stickyScrollGuardActive = false
          if self.scrollPosition < 1.0 {
            self.scroll(toPosition: 1.0)
          }
        }
        // Shift+Enter: send newline (LF) instead of carriage return (CR)
        // so Claude Code inserts a line break rather than submitting.
        if event.keyCode == 36 && event.modifierFlags.contains(.shift) {
          self.send(txt: "\n")
          return nil
        }
        return event
      }
      installMouseMonitor()
      scheduleBlockButtonRefresh()
    } else if window == nil, let monitor = keyMonitor {
      NSEvent.removeMonitor(monitor)
      keyMonitor = nil
      removeMouseMonitor()
    }
  }

  open override func layout() {
    super.layout()
    // A resize reflows the buffer and moves blockquotes; re-pin the buttons.
    scheduleBlockButtonRefresh()
  }

  // Trackpad/wheel events are intentionally left to SwiftTerm's default
  // handling on the alternate screen. We previously translated them to
  // PageUp/PageDown so Claude Code's TUI would scroll its transcript view,
  // but that opted users into Claude Code's auto-follow-on-stream behavior:
  // any scroll-up would snap back down as soon as the model emitted another
  // token. iTerm2 avoids this by never telling the app the user scrolled,
  // and we now match that. Users can still scroll the transcript explicitly
  // with the PageUp/PageDown keys (fn+↑/fn+↓ on compact Mac keyboards).

  // MARK: - Cmd+Click PR/Issue References and file paths

  /// Regex matching `#123` or `owner/repo#123` patterns.
  private static let prPattern = try! NSRegularExpression(
    pattern: #"(?:[\w.-]+/[\w.-]+)?#\d+"#)

  private var mouseMonitor: Any?
  private var mouseMovedMonitor: Any?

  /// Cmd+click opens PR/issue refs and file paths. SwiftTerm declares `mouseUp`
  /// as `public` (not `open`), so we can't override it from this module; instead
  /// we intercept the click with an app-wide local event monitor that fires
  /// before SwiftTerm's own `mouseUp`. This matters because SwiftTerm's default
  /// `requestOpenLink` feeds the raw matched text to `NSWorkspace.open`, which
  /// fails with Finder error -50 for schemeless file paths. Returning `nil`
  /// consumes the click; returning the event lets SwiftTerm handle web links.
  private func installMouseMonitor() {
    guard mouseMonitor == nil else { return }
    mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
      guard let self = self,
        event.modifierFlags.contains(.command),
        event.window === self.window,
        self.window?.isKeyWindow == true
      else { return event }

      // bounds-checked: returns nil when the click isn't on this view.
      guard let (text, col) = self.lineAndColumn(at: event) else { return event }
      let token = self.tokenAtClick(in: text, col: col)
      NSLog(
        "[ClaudeTerminalView] cmd+click col=%d len=%d token=%@ line=|%@|",
        col, (text as NSString).length, token ?? "<none>", text)

      if let url = self.prURL(in: text, col: col) {
        NSWorkspace.shared.open(url)
        return nil
      }
      if let target = self.fileTargetAtClick(in: text, col: col) {
        NSLog(
          "[ClaudeTerminalView] cmd+click opening file: %@ line=%@",
          target.path, target.line.map(String.init) ?? "nil")
        EditorOpener.open(path: target.path, line: target.line, column: target.col)
        return nil
      }
      // Defer only tokens with a scheme NSWorkspace can open (SwiftTerm handles
      // those correctly); consume anything else so SwiftTerm's default handler
      // never feeds a schemeless string to NSWorkspace.open and triggers -50.
      if let token = token, Self.hasOpenableScheme(token) {
        NSLog("[ClaudeTerminalView] cmd+click deferring web link to SwiftTerm: %@", token)
        return event
      }
      NSLog(
        "[ClaudeTerminalView] cmd+click no match; consuming to avoid -50 (token=%@)",
        token ?? "<none>")
      return nil
    }

    // SwiftTerm already installs a `.mouseMoved` tracking area, so these events
    // reach the window without extra setup. We watch them to reveal the copy
    // button for the blockquote under the pointer, never consuming the event.
    guard mouseMovedMonitor == nil else { return }
    mouseMovedMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) {
      [weak self] event in
      guard let self = self, event.window === self.window, self.window?.isKeyWindow == true
      else { return event }
      let p = self.convert(event.locationInWindow, from: nil)
      self.hoverPoint = self.bounds.contains(p) ? p : nil
      self.applyHover()
      return event
    }
  }

  private func removeMouseMonitor() {
    if let monitor = mouseMonitor {
      NSEvent.removeMonitor(monitor)
      mouseMonitor = nil
    }
    if let monitor = mouseMovedMonitor {
      NSEvent.removeMonitor(monitor)
      mouseMovedMonitor = nil
    }
    hoverPoint = nil
    applyHover()
  }

  /// Map a click to the text of the terminal line under it and the column hit.
  private func lineAndColumn(at event: NSEvent) -> (text: String, col: Int)? {
    // Convert window coordinates to view coordinates, then to a grid column.
    lineAndColumn(atLocal: convert(event.locationInWindow, from: nil))
  }

  func lineAndColumn(atLocal localPoint: CGPoint) -> (text: String, col: Int)? {
    guard bounds.contains(localPoint) else { return nil }

    let term = getTerminal()
    guard term.rows > 0, term.cols > 0 else { return nil }

    // Recover SwiftTerm's exact cell dimensions from getOptimalFrameSize():
    // height is cellHeight * rows; width additionally includes the legacy
    // scroller. Deriving cells from `bounds` instead (as this used to)
    // overestimates them by the view's leftover padding, drifting up to a
    // full row/column by the bottom-right of the screen, so clicks there
    // resolved against the wrong line and were swallowed.
    let optimal = getOptimalFrameSize()
    let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
    let cellWidth = (optimal.width - scrollerWidth) / CGFloat(term.cols)
    let cellHeight = optimal.height / CGFloat(term.rows)
    guard cellWidth > 0, cellHeight > 0 else { return nil }

    let col = min(max(0, Int(localPoint.x / cellWidth)), term.cols - 1)
    let row = Int((bounds.height - localPoint.y) / cellHeight)
    guard row >= 0, row < term.rows else { return nil }
    guard let line = term.getLine(row: row) else { return nil }

    return (line.translateToString(trimRight: true), col)
  }

  /// Return a GitHub URL if a PR/issue ref sits under `col` in `text`.
  private func prURL(in text: String, col: Int) -> URL? {
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

  // MARK: - Cmd+Click file paths

  /// Matches whitespace-delimited tokens (candidate paths/links) on a line.
  private static let tokenRegex = try! NSRegularExpression(pattern: #"\S+"#)

  /// Find a file/dir path on the clicked line. We scan every whitespace-delimited
  /// token rather than only the one under the cursor: mapping a pixel to an exact
  /// terminal column is imprecise, so the token nearest the click that resolves
  /// to something real on disk wins. Returns its absolute path plus any
  /// `:line:col` suffix. Existence on disk is the disambiguator, so labels, prose
  /// words, and web URLs don't match.
  private func fileTargetAtClick(in text: String, col: Int)
    -> (path: String, line: Int?, col: Int?)?
  {
    let nsText = text as NSString
    let cwd = sessionWorkingDirectory()
    var best: (path: String, line: Int?, col: Int?, distance: Int)?

    let tokens = Self.tokenRegex.matches(
      in: text, range: NSRange(location: 0, length: nsText.length))
    for token in tokens {
      let raw = nsText.substring(with: token.range)
      for (candidate, line, column) in Self.pathCandidates(from: raw) {
        guard let abs = Self.resolveExistingFile(candidate, cwd: cwd) else { continue }
        let lo = token.range.location
        let hi = lo + token.range.length - 1
        let distance = col < lo ? lo - col : (col > hi ? col - hi : 0)
        if best == nil || distance < best!.distance {
          best = (abs, line, column, distance)
        }
        break  // first resolving candidate for this token
      }
    }
    return best.map { ($0.path, $0.line, $0.col) }
  }

  /// The maximal run of non-whitespace characters under `col`, or nil when the
  /// click landed on whitespace or outside the line's text.
  private func tokenAtClick(in text: String, col: Int) -> String? {
    let nsText = text as NSString
    guard col >= 0, col < nsText.length else { return nil }

    // Surrogate code units (non-BMP chars like emoji) have no scalar and are
    // treated as non-whitespace rather than force-unwrapped.
    let whitespace = CharacterSet.whitespaces
    func isSpace(_ i: Int) -> Bool {
      guard let scalar = UnicodeScalar(nsText.character(at: i)) else { return false }
      return whitespace.contains(scalar)
    }
    guard !isSpace(col) else { return nil }
    var start = col
    while start > 0, !isSpace(start - 1) { start -= 1 }
    var end = col
    while end + 1 < nsText.length, !isSpace(end + 1) { end += 1 }
    return nsText.substring(with: NSRange(location: start, length: end - start + 1))
  }

  /// True if the token carries a scheme NSWorkspace can open directly, so it's
  /// safe to defer to SwiftTerm. Schemeless tokens are consumed by the caller to
  /// keep SwiftTerm's default handler from passing them to `NSWorkspace.open`
  /// (which fails with Finder error -50).
  static func hasOpenableScheme(_ token: String) -> Bool {
    let trimmed =
      token
      .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`()[]{}<>"))
      .lowercased()
    return ["http://", "https://", "ftp://", "ftps://", "ssh://", "file://", "mailto:"]
      .contains { trimmed.hasPrefix($0) }
  }

  /// Progressive interpretations of a clicked token: strip surrounding wrappers,
  /// a trailing `:line(:col)?` suffix (capturing the numbers), and trailing prose
  /// punctuation. The first whose path exists on disk wins.
  static func pathCandidates(from raw: String) -> [(path: String, line: Int?, col: Int?)] {
    var token = raw
    // Strip surrounding wrapper characters in matched-ish pairs.
    let trimSet = CharacterSet(charactersIn: "\"'`()[]{}<>")
    token = token.trimmingCharacters(in: trimSet)
    guard !token.isEmpty else { return [] }

    var out: [(String, Int?, Int?)] = [(token, nil, nil)]

    // `path:line` or `path:line:col` suffix.
    if let m = try? NSRegularExpression(pattern: #"^(.*?):(\d+)(?::(\d+))?$"#),
      let match = m.firstMatch(
        in: token, range: NSRange(token.startIndex..., in: token)),
      let pathRange = Range(match.range(at: 1), in: token),
      let lineRange = Range(match.range(at: 2), in: token)
    {
      let path = String(token[pathRange])
      let line = Int(token[lineRange])
      var col: Int? = nil
      if let cRange = Range(match.range(at: 3), in: token) { col = Int(token[cRange]) }
      if !path.isEmpty { out.append((path, line, col)) }
    }

    // Drop one trailing prose punctuation char (e.g. "see foo.swift.").
    if let last = token.unicodeScalars.last,
      CharacterSet(charactersIn: ".,;!?").contains(last)
    {
      let trimmed = String(token.dropLast())
      if !trimmed.isEmpty { out.append((trimmed, nil, nil)) }
    }

    return out
  }

  /// Resolve a candidate to an absolute path if it exists on disk (file or
  /// directory; directories open in Finder). Expands `~`, treats `/…` as
  /// absolute, and resolves relative paths against `cwd`.
  static func resolveExistingFile(_ candidate: String, cwd: String?) -> String? {
    let expanded = (candidate as NSString).expandingTildeInPath
    let absolute: String
    if expanded.hasPrefix("/") {
      absolute = expanded
    } else if let cwd = cwd {
      absolute = (cwd as NSString).appendingPathComponent(expanded)
    } else {
      return nil
    }
    let standardized = (absolute as NSString).standardizingPath

    guard FileManager.default.fileExists(atPath: standardized) else { return nil }
    return standardized
  }

  /// The working directory for the clicked view's session, resolved by identity so
  /// it's correct even when another session is the globally active one.
  private func sessionWorkingDirectory() -> String? {
    let mgr = SessionManager.shared
    if let session = mgr.sessions.first(where: { $0.terminalView === self }),
      let path = session.worktreePath
    {
      return path
    }
    return mgr.activeSession?.worktreePath ?? mgr.projectDir
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

  /// Derive `owner/repo` from the git remote of the clicked session's worktree.
  private func gitHubSlug() -> String? {
    guard let dir = sessionWorkingDirectory() else { return nil }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    proc.arguments = ["-C", dir, "remote", "get-url", "origin"]
    proc.environment = ProcessInfo.processInfo.environment
      .filter { !$0.key.hasPrefix("GIT_") }
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    let data: Data
    do {
      try proc.run()
      // Read to EOF before waiting so a full pipe buffer can't deadlock us.
      data = pipe.fileHandleForReading.readDataToEndOfFile()
      proc.waitUntilExit()
      guard proc.terminationStatus == 0 else { return nil }
    } catch { return nil }
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

  // MARK: - Blockquote copy buttons
  //
  // Claude renders markdown blockquotes as a left bar glyph (▎) on every quoted
  // row — there's no clean way to select just that text. We scrape the visible
  // buffer for those runs and position a copy-icon button at the top-right of
  // each block, refreshed whenever the buffer changes (streaming) or scrolls; the
  // button for the block under the pointer is revealed on hover. Scraping the
  // screen — not the JSONL session log — keeps it correct regardless of scroll or
  // how far the conversation has moved on (the JSONL only retains the single
  // latest assistant message, which any newer reply overwrites).

  /// A copy button carrying the dequoted text and on-screen rows of its block.
  private final class BlockCopyButton: NSButton {
    var blockText: String = ""
    var blockRange: ClosedRange<Int>?
  }

  /// Reused pool of copy buttons, one per visible block. Positioned by refresh,
  /// but revealed only for the block under the pointer (see `applyHover`).
  private var copyButtons: [BlockCopyButton] = []
  /// How many buttons are currently mapped to a visible block.
  private var activeButtonCount = 0
  /// Trailing-debounce token: only the latest scheduled refresh runs.
  private var blockRefreshToken = 0
  /// Last pointer location in view coords; decides which button to reveal.
  private var hoverPoint: NSPoint?

  private static let copyIcon = NSImage(
    systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy"
  )?.withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
  private static let copiedIcon = NSImage(
    systemSymbolName: "checkmark", accessibilityDescription: "Copied"
  )?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))

  /// Schedule a refresh of the blockquote copy buttons, debounced so it runs on
  /// a *settled* buffer. Claude Code's TUI redraws by clearing then rewriting
  /// cells, so a scan mid-redraw sees bars as NUL; waiting for a brief quiet
  /// period avoids pinning buttons against a transient half-drawn frame.
  func scheduleBlockButtonRefresh() {
    blockRefreshToken &+= 1
    let token = blockRefreshToken
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
      guard let self = self, self.blockRefreshToken == token else { return }
      self.refreshBlockCopyButtons()
    }
  }

  /// Rescan the visible buffer and position a (hidden) copy button at each
  /// blockquote's top-right corner; `applyHover` then reveals the one under the
  /// pointer. Reusing the pool keeps positions correct across stream/scroll.
  private func refreshBlockCopyButtons() {
    let term = getTerminal()
    guard term.rows > 0, term.cols > 0, bounds.width > 0, bounds.height > 0 else { return }
    let lines = (0..<term.rows).map { term.getLine(row: $0)?.translateToString(trimRight: true) }
    let blocks = BlockquoteScanner.allBlocks(in: lines)

    let cellHeight = bounds.height / CGFloat(term.rows)
    let size = NSSize(width: 26, height: 20)
    while copyButtons.count < blocks.count {
      let btn = makeBlockCopyButton()
      addSubview(btn)
      copyButtons.append(btn)
    }
    activeButtonCount = blocks.count
    for (i, button) in copyButtons.enumerated() {
      guard i < blocks.count else {
        button.blockRange = nil
        button.isHidden = true
        continue
      }
      button.blockText = blocks[i].text
      button.blockRange = blocks[i].range
      setBlockButtonIcon(button, Self.copyIcon, color: Theme.accent)
      // View is bottom-origin: the top edge of row r is `height - r*cell`.
      let topY = bounds.height - CGFloat(blocks[i].range.lowerBound) * cellHeight
      button.frame = NSRect(
        x: bounds.width - size.width - 8, y: topY - size.height,
        width: size.width, height: size.height)
    }
    applyHover()
  }

  /// Reveal only the copy button whose block rows (or button frame) contain the
  /// pointer; hide the rest. Cheap — pure visibility toggles, no buffer scan.
  private func applyHover() {
    let term = getTerminal()
    let row: Int? = {
      guard let p = hoverPoint, bounds.contains(p), term.rows > 0 else { return nil }
      return Int((bounds.height - p.y) / (bounds.height / CGFloat(term.rows)))
    }()
    for (i, button) in copyButtons.enumerated() {
      guard i < activeButtonCount, let range = button.blockRange else {
        button.isHidden = true
        continue
      }
      let over =
        (row.map { range.contains($0) } ?? false)
        || (hoverPoint.map { button.frame.contains($0) } ?? false)
      button.isHidden = !over
    }
  }

  private func makeBlockCopyButton() -> BlockCopyButton {
    let btn = BlockCopyButton(
      image: Self.copyIcon ?? NSImage(), target: self,
      action: #selector(blockCopyButtonClicked(_:)))
    btn.isBordered = false
    btn.imagePosition = .imageOnly
    btn.imageScaling = .scaleProportionallyDown
    btn.wantsLayer = true
    btn.bezelStyle = .regularSquare
    btn.contentTintColor = Theme.accent
    btn.layer?.backgroundColor = Theme.surface3.cgColor
    btn.layer?.cornerRadius = 4
    btn.toolTip = "Copy quote"
    btn.isHidden = true
    return btn
  }

  private func setBlockButtonIcon(_ button: NSButton, _ image: NSImage?, color: NSColor) {
    button.image = image
    button.contentTintColor = color
  }

  @objc private func blockCopyButtonClicked(_ sender: BlockCopyButton) {
    guard !sender.blockText.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(sender.blockText, forType: .string)
    setBlockButtonIcon(sender, Self.copiedIcon, color: Theme.green)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self, weak sender] in
      guard let self = self, let sender = sender else { return }
      self.setBlockButtonIcon(sender, Self.copyIcon, color: Theme.accent)
    }
  }

  /// The rendered blockquote whose rows include `point` (for the right-click
  /// menu). `point` is in this view's coordinate space.
  private func blockUnderPoint(_ point: NSPoint) -> (rows: ClosedRange<Int>, text: String)? {
    guard bounds.contains(point) else { return nil }
    let term = getTerminal()
    guard term.rows > 0, term.cols > 0 else { return nil }
    let cellHeight = bounds.height / CGFloat(term.rows)
    let approxRow = Int((bounds.height - point.y) / cellHeight)
    let lines = (0..<term.rows).map { term.getLine(row: $0)?.translateToString(trimRight: true) }
    guard let block = BlockquoteScanner.block(in: lines, at: approxRow) else { return nil }
    return (block.range, block.text)
  }

  // MARK: - Right-click context menu

  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = NSMenu()
    if let (_, text) = blockUnderPoint(convert(event.locationInWindow, from: nil)) {
      let quoteItem = NSMenuItem(
        title: "Copy quote block", action: #selector(copyQuoteBlock(_:)), keyEquivalent: "")
      quoteItem.target = self
      quoteItem.representedObject = text
      menu.addItem(quoteItem)
      menu.addItem(NSMenuItem.separator())
    }
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

  @objc private func copyQuoteBlock(_ sender: NSMenuItem) {
    guard let text = sender.representedObject as? String else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
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
