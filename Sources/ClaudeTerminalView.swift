import AppKit
import SwiftTerm

/// Subclass of LocalProcessTerminalView that:
///   1. intercepts raw PTY data (dataReceived(slice:) is the only `open` method
///      in the data path), and
///   2. accepts file drag-and-drop — dropped files are inserted into the shell
///      as quoted paths so tools like Claude Code can reference them.
class ClaudeTerminalView: LocalProcessTerminalView {
    var onPtyData: ((ArraySlice<UInt8>) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        onPtyData?(slice)
        super.dataReceived(slice: slice)
    }

    override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        NSLog("[ClaudeTerminalView] processTerminated exitCode=%@",
              exitCode.map(String.init) ?? "nil")
        super.processTerminated(source, exitCode: exitCode)
    }

    // MARK: - File drag-and-drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasFileURLs(sender) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasFileURLs(sender) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = fileURLs(from: sender), !urls.isEmpty else { return false }
        // Join multiple paths with spaces; trailing space lets the user keep
        // typing after the drop.
        let txt = urls.map { shellEscapePath($0.path) }.joined(separator: " ") + " "
        send(txt: txt)
        return true
    }

    private func hasFileURLs(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
    }

    private func fileURLs(from sender: NSDraggingInfo) -> [URL]? {
        sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
    }
}

/// Single-quote a path so it survives as a shell argument, escaping embedded
/// single quotes via the standard `'\''` idiom.
private func shellEscapePath(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
