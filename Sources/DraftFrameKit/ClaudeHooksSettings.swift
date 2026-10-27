import AppKit

/// User-facing glue between the hooks preference, the installer, and the
/// event listener: toggling, the explanation shown before opting in, and
/// the health report surfaced in Settings and the Help menu.
@MainActor
enum ClaudeHooksSettings {

  static let explanation =
    "DraftFrame can add hooks to ~/.claude/settings.json so Claude Code reports "
    + "each session's status directly: when it is working, waiting for a "
    + "permission, or finished. This replaces terminal parsing with exact events "
    + "and binds each tab to its own transcript for accurate per-tab cost.\n\n"
    + "The hooks run a small script that forwards events to DraftFrame over a local "
    + "socket. It exits immediately in Claude Code sessions launched outside "
    + "DraftFrame. Only DraftFrame's entries are added or removed; your own hooks "
    + "are left untouched. You can turn this off at any time in Settings."

  /// Enable or disable, installing or uninstalling accordingly. Returns the
  /// installer error, if any; the preference tracks what actually happened.
  @discardableResult
  static func setEnabled(_ enabled: Bool) -> Error? {
    do {
      if enabled {
        try ClaudeHooks.install()
      } else {
        try ClaudeHooks.uninstall()
      }
      AppSettings.claudeHooksEnabled = enabled
      return nil
    } catch {
      AppSettings.claudeHooksEnabled = enabled && ClaudeHooks.status().isInstalled
      return error
    }
  }

  static func presentError(_ error: Error) {
    let alert = NSAlert()
    alert.messageText = "Could not update Claude Code hooks"
    alert.informativeText = error.localizedDescription
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }

  /// One-line summary for the Settings window.
  static func summaryLine() -> String {
    let status = ClaudeHooks.status()
    let server = HookEventServer.shared
    var parts: [String] = []
    if status.isInstalled {
      parts.append("Installed")
    } else if status.isPartiallyInstalled {
      parts.append("Partially installed")
    } else {
      parts.append("Not installed")
    }
    parts.append(server.isListening ? "socket listening" : "socket not listening")
    if let last = server.lastEventAt {
      parts.append("last event \(ago(last))")
    } else {
      parts.append("no events yet")
    }
    return parts.joined(separator: " · ")
  }

  /// Full report for the Help menu.
  static func healthReport() -> String {
    let status = ClaudeHooks.status()
    let server = HookEventServer.shared
    var lines: [String] = []
    let preference = AppSettings.claudeHooksEnabled ? "enabled" : "disabled (opt in via Settings)"
    lines.append("Preference: " + preference)
    let script = status.scriptCurrent ? "current" : status.scriptExists ? "outdated" : "missing"
    lines.append("Bridge script: " + script)
    if status.settingsCorrupt {
      lines.append("settings.json: not valid JSON, cannot be edited")
    } else if status.missingEvents.isEmpty {
      lines.append("settings.json: all \(ClaudeHooks.eventNames.count) events wired")
    } else if status.installedEvents.isEmpty {
      lines.append("settings.json: no DraftFrame entries")
    } else {
      lines.append("settings.json: missing " + status.missingEvents.joined(separator: ", "))
    }
    lines.append("netcat (/usr/bin/nc): " + (status.netcatAvailable ? "available" : "missing"))
    if let path = server.socketPath, server.isListening {
      lines.append("Socket: listening at \(path)")
    } else {
      lines.append("Socket: not listening")
    }
    lines.append("Events received: \(server.eventCount)")
    if let last = server.lastEventAt { lines.append("Last event: \(ago(last))") }
    if server.rejectedCount > 0 { lines.append("Unparseable messages: \(server.rejectedCount)") }

    let bound = SessionManager.shared.sessions.filter(\.isHookDriven).count
    let claude = SessionManager.shared.sessions.filter { $0.agent == .claude }.count
    lines.append("Tabs reporting through hooks: \(bound) of \(claude) Claude Code tabs")
    if AppSettings.claudeHooksEnabled, status.isInstalled, server.eventCount == 0, claude > 0 {
      lines.append(
        "\nNo events yet: hooks apply to sessions started after installation. "
          + "Restart a session (Session > Restart Session) to pick them up.")
    }
    return lines.joined(separator: "\n")
  }

  private static func ago(_ date: Date) -> String {
    let s = Int(Date().timeIntervalSince(date))
    if s < 60 { return "\(s)s ago" }
    if s < 3600 { return "\(s / 60)m ago" }
    return "\(s / 3600)h ago"
  }
}
