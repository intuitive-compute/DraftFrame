import AppKit
import SwiftTerm

/// Subclass of LocalProcessTerminalView that intercepts raw PTY data.
/// dataReceived(slice:) is the only `open` method in the data path.
class ClaudeTerminalView: LocalProcessTerminalView {
    var onPtyData: ((ArraySlice<UInt8>) -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        onPtyData?(slice)
        super.dataReceived(slice: slice)
    }
}
