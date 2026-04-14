import Foundation

/// Analyzes raw PTY byte stream in real-time to detect Claude Code session state.
/// Strips ANSI escape sequences and tracks alternate buffer mode, frame boundaries,
/// and content patterns.
final class PTYStreamAnalyzer {

  var onStateChange: ((SessionState) -> Void)?

  private(set) var state: SessionState = .idle

  // ANSI parser state
  private var inEscape = false
  private var escapeBuffer: [UInt8] = []

  // Alternate buffer tracking (Claude's TUI uses alternate screen)
  private(set) var alternateBufferActive = false

  // Frame text — reset on screen clear or frame boundary
  private var frameText = ""
  private var frameTimer: DispatchWorkItem?

  // Rolling recent text (last ~2000 chars of plaintext)
  private var recentText = ""
  private let recentTextLimit = 2000

  func feed(_ bytes: ArraySlice<UInt8>) {
    for byte in bytes {
      if inEscape {
        processEscapeByte(byte)
      } else if byte == 0x1B {  // ESC
        inEscape = true
        escapeBuffer = [byte]
      } else {
        // Regular printable character or control char
        if byte >= 0x20 && byte < 0x7F {
          let char = Character(UnicodeScalar(byte))
          frameText.append(char)
          recentText.append(char)
        } else if byte == 0x0A {  // newline
          frameText.append("\n")
          recentText.append("\n")
        } else if byte == 0x0D {  // carriage return
          // ignore CR (we use LF for newlines)
        }
        // Other control chars (BEL, BS, TAB, etc.) — ignore for analysis
      }
    }

    // Trim recent text buffer
    if recentText.count > recentTextLimit {
      recentText = String(recentText.suffix(recentTextLimit))
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
        frameText = ""  // fresh frame
      } else if finalByte == 0x6C {  // 'l'
        alternateBufferActive = false
        frameText = ""
        // Claude exited — immediate state change
        updateState(.idle)
      }
    }

    // Detect screen clear: CSI 2 J
    if paramStr == "2" && finalByte == 0x4A {  // 'J'
      frameText = ""  // new frame
    }

    // Detect cursor home: CSI H (no params)
    if paramStr.isEmpty && finalByte == 0x48 {  // 'H'
      // Often precedes a full redraw, but don't clear yet
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

    let newState: SessionState

    // Permission prompts — highest priority
    if recentLower.contains("allow") && recentLower.contains("deny") {
      newState = .needsAttention
    } else if recentLower.contains("[y/n]") || recentLower.contains("(y/n)") {
      newState = .needsAttention
    } else if recentLower.contains("do you want to proceed") {
      newState = .needsAttention
    }
    // "esc to interrupt" = Claude is actively working RIGHT NOW
    else if recentLower.contains("esc to interrupt") || recentLower.contains("esc to cancel") {
      if recentLower.contains("thinking") {
        newState = .thinking
      } else {
        newState = .generating
      }
    }
    // Claude's prompt marker — waiting for user
    // Use the very recent text (last ~100 chars) to detect the active prompt
    else if String(recentText.suffix(100)).contains("/effort")
      || String(recentText.suffix(50)).contains("> ")
    {
      // Claude is showing its UI but not working — at the input prompt
      // "/effort" appears in Claude's bottom bar, ">" is the prompt
      newState = .userInput
    }
    // Shell prompt — Claude not running
    else if recentLower.hasSuffix("$ ") || recentLower.hasSuffix("% ") || recentLower.contains("❯")
    {
      newState = .idle
    } else {
      // Can't determine — keep current state
      return
    }

    updateState(newState)
  }

  private func updateState(_ newState: SessionState) {
    guard newState != state else { return }
    state = newState
    onStateChange?(newState)
  }

  /// Reset the analyzer (e.g., when restarting a session).
  func reset() {
    state = .idle
    alternateBufferActive = false
    inEscape = false
    escapeBuffer = []
    frameText = ""
    recentText = ""
  }
}
