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
    } else if window == nil, let monitor = keyMonitor {
      NSEvent.removeMonitor(monitor)
      keyMonitor = nil
    }
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
