import AppKit
import SwiftTerm

/// Subclass of LocalProcessTerminalView that intercepts raw PTY data
/// before it reaches the terminal emulator. This gives us real-time
/// access to every byte Claude Code writes.
class ClaudeTerminalView: LocalProcessTerminalView {
    var onPtyData: ((ArraySlice<UInt8>) -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        onPtyData?(slice)
        super.dataReceived(slice: slice)
    }
}
