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
    super.dataReceived(slice: slice)
  }

  override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
    NSLog(
      "[ClaudeTerminalView] processTerminated exitCode=%@",
      exitCode.map(String.init) ?? "nil")
    super.processTerminated(source, exitCode: exitCode)
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

    // Send each path to the terminal, space-separated and shell-escaped.
    let escaped = paths.map { path in
      path.contains(" ") ? "'\(path)'" : path
    }
    send(txt: escaped.joined(separator: " "))
    return true
  }
}
