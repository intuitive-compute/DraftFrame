import AppKit
import SwiftTerm

/// Subclass of LocalProcessTerminalView that intercepts raw PTY data.
/// dataReceived(slice:) is the only `open` method in the data path.
class ClaudeTerminalView: LocalProcessTerminalView {
  var onPtyData: ((ArraySlice<UInt8>) -> Void)?

  /// Enable Metal GPU rendering if available, falling back to CoreGraphics.
  func enableMetalIfAvailable() {
    do {
      try setUseMetal(true)
      NSLog("[ClaudeTerminalView] Metal rendering enabled")
    } catch {
      NSLog("[ClaudeTerminalView] Metal unavailable, using CoreGraphics: %@", "\(error)")
    }
  }

  override func dataReceived(slice: ArraySlice<UInt8>) {
    onPtyData?(slice)
    super.dataReceived(slice: slice)
  }

  override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
    NSLog(
      "[ClaudeTerminalView] processTerminated exitCode=%@",
      exitCode.map(String.init) ?? "nil")
    super.processTerminated(source, exitCode: exitCode)
  }
}
