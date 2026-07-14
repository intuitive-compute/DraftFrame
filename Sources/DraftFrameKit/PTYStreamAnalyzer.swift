import Foundation

/// Analyzes raw PTY byte stream in real-time to detect agent session state.
/// Strips ANSI escape sequences and tracks alternate buffer mode, frame boundaries,
/// and content patterns.
final class PTYStreamAnalyzer {

  /// Which agent's TUI this stream carries. Selects the marker set used for
  /// state classification and banner detection, so one agent's markers can
  /// never misclassify the other's session.
  var agent: AgentKind = .claude

  var onStateChange: ((SessionState) -> Void)?
  var onContextWindowChange: ((Int) -> Void)?
  /// Fired once, the first time we positively identify Claude Code's TUI in
  /// the stream — used to dismiss the startup loading overlay. Claude renders
  /// in the main screen buffer (no alternate-screen switch to key off of), so
  /// we detect it by the markers it paints: see `detectClaudeReady`.
  var onClaudeReady: (() -> Void)?
  /// Guards `onClaudeReady` so it fires at most once per (re)start.
  private var claudeReadyFired = false
  /// Fired when the TUI reveals the active model. Codex prints
  /// "model:   gpt-5.6-sol   /model to change" in its startup banner —
  /// the only model signal available before the first turn is written to
  /// the rollout. Fires only when `agent == .codex`.
  var onModelDetected: ((String) -> Void)?
  private var lastDetectedModel: String?

  private(set) var state: SessionState = .idle
  private var lastContextWindow: Int = 0

  // ANSI parser state
  private var inEscape = false
  private var escapeBuffer: [UInt8] = []

  // Alternate buffer tracking (Claude's TUI uses alternate screen)
  private(set) var alternateBufferActive = false

  private var frameTimer: DispatchWorkItem?

  // Rolling recent text (last ~2000 chars of plaintext). Every char appended
  // here is single-scalar ASCII, so `recentTextCount` stays an exact mirror
  // of `recentText.count` without the O(n) grapheme walk per chunk.
  private var recentText = ""
  private var recentTextCount = 0
  private let recentTextLimit = 2000

  func feed(_ bytes: ArraySlice<UInt8>) {
    var appendedCount = 0
    for byte in bytes {
      if inEscape {
        processEscapeByte(byte)
      } else if byte == 0x1B {  // ESC
        inEscape = true
        escapeBuffer = [byte]
      } else {
        // Regular printable character or control char
        if byte >= 0x20 && byte < 0x7F {
          recentText.append(Character(UnicodeScalar(byte)))
          appendedCount += 1
        } else if byte == 0x0A {  // newline
          recentText.append("\n")
          appendedCount += 1
        } else if byte == 0x0D {  // carriage return
          // ignore CR (we use LF for newlines)
        }
        // Other control chars (BEL, BS, TAB, etc.) — ignore for analysis
      }
    }
    recentTextCount += appendedCount

    // Detect 1M context banner before the rolling buffer trims it away.
    // The banner is among the first bytes Claude Code prints, but TUI
    // animation can flood the buffer and push it out before analyzeFrame
    // (debounced 50ms) gets a chance to look.
    if appendedCount > 0 {
      detectContextWindowFromBanner(appendedCount: appendedCount)
    }

    // Trim lazily at 2x the limit so the O(n) suffix copy is amortized
    // across many chunks instead of paid on every one.
    if recentTextCount > recentTextLimit * 2 {
      recentText = String(recentText.suffix(recentTextLimit))
      recentTextCount = recentText.count
    }

    // Debounce frame analysis — run 50ms after last data chunk
    frameTimer?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.analyzeFrame()
    }
    frameTimer = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
  }

  // MARK: - ANSI Escape Sequence Parser

  private func processEscapeByte(_ byte: UInt8) {
    escapeBuffer.append(byte)

    // ESC [ ... <final byte> — CSI sequence
    if escapeBuffer.count == 2 && byte == 0x5B {  // [
      return  // start of CSI, keep reading
    }

    // ESC ] ... BEL/ST — OSC sequence
    if escapeBuffer.count == 2 && byte == 0x5D {  // ]
      return  // start of OSC, keep reading
    }

    // Inside CSI sequence — wait for final byte (0x40-0x7E)
    if escapeBuffer.count >= 3 && escapeBuffer[1] == 0x5B {
      if byte >= 0x40 && byte <= 0x7E {
        // CSI sequence complete — check for important ones
        checkCSISequence()
        endEscape()
      }
      return
    }

    // Inside OSC sequence — wait for BEL (0x07) or ST (ESC \)
    if escapeBuffer.count >= 3 && escapeBuffer[1] == 0x5D {
      if byte == 0x07 {  // BEL terminates OSC
        endEscape()
      } else if byte == 0x5C && escapeBuffer.count >= 2
        && escapeBuffer[escapeBuffer.count - 2] == 0x1B
      {  // ESC \ terminates OSC
        endEscape()
      }
      // Keep reading OSC content (don't let it grow unbounded)
      if escapeBuffer.count > 256 {
        endEscape()  // bail on absurdly long sequences
      }
      return
    }

    // Simple two-byte escape (ESC + single char) — e.g., ESC M, ESC 7, ESC 8
    if escapeBuffer.count == 2 {
      endEscape()
      return
    }

    // Safety: if escape buffer gets too long, bail
    if escapeBuffer.count > 64 {
      endEscape()
    }
  }

  private func checkCSISequence() {
    // Extract parameter string (bytes between '[' and final byte)
    guard escapeBuffer.count >= 3 else { return }
    let paramBytes = escapeBuffer[2..<(escapeBuffer.count - 1)]
    let finalByte = escapeBuffer.last!
    let paramStr = String(
      paramBytes.compactMap { byte -> Character? in
        guard let scalar = Unicode.Scalar(UInt32(byte)) else { return nil }
        return Character(scalar)
      })

    // Detect alternate buffer switch
    // CSI ? 1049 h = enter alternate buffer
    // CSI ? 1049 l = leave alternate buffer
    if paramStr == "?1049" {
      if finalByte == 0x68 {  // 'h'
        alternateBufferActive = true
        // Belt-and-suspenders: if a future Claude version ever does take over
        // the alternate screen, treat that as the ready signal too.
        fireClaudeReady()
      } else if finalByte == 0x6C {  // 'l'
        alternateBufferActive = false
        // Claude exited — immediate state change
        updateState(.idle)
      }
    }
  }

  private func endEscape() {
    inEscape = false
    escapeBuffer = []
  }

  // MARK: - Frame Analysis

  private func analyzeFrame() {
    // Look at the most recent content (last ~500 chars) for bottom-of-screen indicators
    let recentLower = String(recentText.suffix(500)).lowercased()

    detectClaudeReady(recentLower)
    detectModelBanner(recentLower)

    guard let newState = classify(recentLower) else {
      // Can't determine — keep current state
      return
    }
    updateState(newState)
  }

  /// Map the recent plaintext to a session state, or nil when no marker is
  /// decisive. Each agent's TUI gets its own marker set.
  private func classify(_ recentLower: String) -> SessionState? {
    switch agent {
    case .claude: return classifyClaude(recentLower)
    case .codex: return classifyCodex(recentLower)
    }
  }

  private func classifyClaude(_ recentLower: String) -> SessionState? {
    // Permission prompts — highest priority
    if recentLower.contains("allow") && recentLower.contains("deny") {
      return .needsAttention
    }
    if recentLower.contains("[y/n]") || recentLower.contains("(y/n)") {
      return .needsAttention
    }
    if recentLower.contains("do you want to proceed") {
      return .needsAttention
    }

    // "esc to interrupt" = Claude is actively working RIGHT NOW
    if recentLower.contains("esc to interrupt") || recentLower.contains("esc to cancel") {
      return recentLower.contains("thinking") ? .thinking : .generating
    }

    // Claude's prompt marker — waiting for user
    // Use the very recent text (last ~100 chars) to detect the active prompt
    if String(recentText.suffix(100)).contains("/effort")
      || String(recentText.suffix(50)).contains("> ")
    {
      // Claude is showing its UI but not working — at the input prompt
      // "/effort" appears in Claude's bottom bar, ">" is the prompt
      return .userInput
    }

    return shellPromptState(recentLower)
  }

  private func classifyCodex(_ recentLower: String) -> SessionState? {
    // Codex's approval overlay — its options are full sentences ("Yes,
    // proceed", "No, and tell Codex what to do differently"), not y/n.
    if recentLower.contains("yes, proceed")
      || recentLower.contains("tell codex what to do differently")
    {
      return .needsAttention
    }

    // "esc to interrupt" = Codex is actively working RIGHT NOW. Codex
    // repaints its idle footer ("? for shortcuts") over the working row when
    // a turn ends, and both markers can linger in the rolling buffer — so
    // whichever painted most recently decides.
    let workingIdx = [
      recentLower.range(of: "esc to interrupt", options: .backwards),
      recentLower.range(of: "esc to cancel", options: .backwards),
    ].compactMap { $0?.lowerBound }.max()
    let idleFooterIdx =
      recentLower.range(of: "? for shortcuts", options: .backwards)?.lowerBound

    if let working = workingIdx, idleFooterIdx == nil || idleFooterIdx! < working {
      return recentLower.contains("thinking") ? .thinking : .generating
    }
    if idleFooterIdx != nil {
      // The idle footer outlived the working row — at the input prompt.
      return .userInput
    }

    return shellPromptState(recentLower)
  }

  /// Shell prompt — no agent running.
  private func shellPromptState(_ recentLower: String) -> SessionState? {
    if recentLower.hasSuffix("$ ") || recentLower.hasSuffix("% ") || recentLower.contains("❯") {
      return .idle
    }
    return nil
  }

  private func updateState(_ newState: SessionState) {
    guard newState != state else { return }
    state = newState
    onStateChange?(newState)
  }

  /// Detect that Claude Code's TUI has painted (as opposed to the bare login
  /// shell that runs first during the `clear && claude` bootstrap). Claude
  /// renders in the main buffer, so we look for strings only its UI prints:
  /// the bottom status bar (`/effort`, the shortcuts hint) and the working
  /// indicator. The login shell's prompt contains none of these, so this
  /// won't fire on the shell that precedes Claude.
  private func detectClaudeReady(_ recentLower: String) {
    guard !claudeReadyFired else { return }
    if recentLower.contains("/effort")
      || recentLower.contains("esc to interrupt")
      || recentLower.contains("esc to cancel")
      || recentLower.contains("? for shortcuts")
    {
      fireClaudeReady()
    }
  }

  private func fireClaudeReady() {
    guard !claudeReadyFired else { return }
    claudeReadyFired = true
    onClaudeReady?()
  }

  // Lazy capture with a boundary lookahead: TUI repaints can butt two
  // paints of the banner together with no separator once cursor-movement
  // sequences are stripped ("…-solmodel: gpt-…"), and a greedy capture
  // would run across the seam.
  private static let modelBannerRegex = try! NSRegularExpression(
    pattern: #"model:\s+([a-z0-9][a-z0-9._-]*?)(?=[\s/]|$)"#)

  /// Pull the model id out of a "model: <id>" banner line. Takes the last
  /// match in the window (freshest paint) and re-fires only on change.
  /// Codex-only: Claude never prints this banner, and this runs on every
  /// analyzed frame, so skip the regex when nobody is listening.
  private func detectModelBanner(_ recentLower: String) {
    guard agent == .codex, onModelDetected != nil else { return }
    guard recentLower.contains("model:") else { return }
    let ns = recentLower as NSString
    let matches = Self.modelBannerRegex.matches(
      in: recentLower, range: NSRange(location: 0, length: ns.length))
    guard let match = matches.last else { return }
    let model = ns.substring(with: match.range(at: 1))
    guard model != lastDetectedModel else { return }
    lastDetectedModel = model
    onModelDetected?(model)
  }

  private static let oneMillionBanner = "(1M context)"

  /// Promote the cap to 1M if Claude Code's banner ever printed
  /// `(1M context)` in this session's output. We don't try to demote — TUI
  /// rendering recycles the buffer too aggressively to reliably observe the
  /// inverse, and a fresh DraftFrame session restarts the analyzer anyway.
  /// Scans only the newly appended tail (plus banner-length overlap for a
  /// marker split across chunks) — the rest of the rolling buffer was
  /// already scanned when its bytes arrived.
  private func detectContextWindowFromBanner(appendedCount: Int) {
    guard lastContextWindow != 1_000_000 else { return }
    let scanLength = appendedCount + Self.oneMillionBanner.count
    if recentText.suffix(scanLength).contains(Self.oneMillionBanner) {
      lastContextWindow = 1_000_000
      onContextWindowChange?(1_000_000)
    }
  }

  /// Reset the analyzer (e.g., when restarting a session).
  func reset() {
    state = .idle
    alternateBufferActive = false
    claudeReadyFired = false
    lastDetectedModel = nil
    inEscape = false
    escapeBuffer = []
    recentText = ""
    recentTextCount = 0
    lastContextWindow = 0
  }
}
