import AppKit

/// Registers global keyboard shortcuts for the app.
final class ShortcutManager {
  static let shared = ShortcutManager()

  /// Callback closures set by the window controller.
  var onNewSession: (() -> Void)?
  var onCloseSession: (() -> Void)?
  var onSwitchSession: ((Int) -> Void)?
  var onToggleDashboard: (() -> Void)?
  var onNewSessionWithWorktree: (() -> Void)?
  var onToggleSidebar: (() -> Void)?
  var onToggleEditor: (() -> Void)?
  var onToggleQuickTerminal: (() -> Void)?

  private var keyDownMonitor: Any?
  private var keyUpMonitor: Any?
  private var flagsMonitor: Any?

  private init() {}

  func install() {
    guard keyDownMonitor == nil else { return }
    keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self = self else { return event }
      return self.handleKeyDown(event) ? nil : event
    }
    // Monitor flagsChanged to detect Cmd+Shift+V release (key-up for modifiers)
    flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
      guard let self = self else { return event }
      self.handleFlagsChanged(event)
      return event
    }
  }

  func uninstall() {
    if let m = keyDownMonitor {
      NSEvent.removeMonitor(m)
      keyDownMonitor = nil
    }
    if let m = flagsMonitor {
      NSEvent.removeMonitor(m)
      flagsMonitor = nil
    }
  }

  private func handleKeyDown(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

    // Cmd+T: new session
    if flags == .command, event.keyCode == 17 {  // 't'
      onNewSession?()
      return true
    }

    // Cmd+W: close session
    if flags == .command, event.keyCode == 13 {  // 'w'
      onCloseSession?()
      return true
    }

    // Cmd+D: toggle dashboard
    if flags == .command, event.keyCode == 2 {  // 'd'
      onToggleDashboard?()
      return true
    }

    // Cmd+N: new session with worktree
    if flags == .command, event.keyCode == 45 {  // 'n'
      onNewSessionWithWorktree?()
      return true
    }

    // Cmd+\: toggle sidebar
    if flags == .command, event.keyCode == 42 {  // '\'
      onToggleSidebar?()
      return true
    }

    // Cmd+E: toggle editor/inspector
    if flags == .command, event.keyCode == 14 {  // 'e'
      onToggleEditor?()
      return true
    }

    // Cmd+` : toggle floating quick terminal
    if flags == .command, event.keyCode == 50 {  // '`'
      onToggleQuickTerminal?()
      return true
    }

    // Cmd+Shift+V: push-to-talk voice transcription (start on key down)
    if flags == [.command, .shift], event.keyCode == 9 {  // 'v'
      if !event.isARepeat && !VoiceManager.shared.isListening {
        VoiceManager.shared.startListening()
      }
      return true
    }

    // Cmd+1 through Cmd+9: switch to session N
    if flags == .command {
      let digitKeyCodes: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5,
        22: 6, 26: 7, 28: 8, 25: 9,
      ]
      if let sessionNum = digitKeyCodes[event.keyCode] {
        onSwitchSession?(sessionNum - 1)
        return true
      }
    }

    return false
  }

  /// Detect when Cmd or Shift is released while voice is listening — stop transcription.
  private func handleFlagsChanged(_ event: NSEvent) {
    guard VoiceManager.shared.isListening else { return }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    // If either Cmd or Shift was released, stop listening
    if !flags.contains(.command) || !flags.contains(.shift) {
      VoiceManager.shared.stopListening()
    }
  }
}
