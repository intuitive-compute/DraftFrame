import Foundation

/// Installs, removes, and health-checks DraftFrame's Claude Code hook entries.
///
/// Claude Code runs the configured `hooks` in `~/.claude/settings.json` as
/// shell commands with a JSON payload on stdin. DraftFrame installs one
/// managed command per lifecycle event that forwards the payload to the
/// running app over a Unix socket (see `HookEventServer`). The command is a
/// small bridge script in Application Support; every managed settings entry
/// is recognised by that script's path (`marker`), so uninstall touches only
/// DraftFrame's entries and user-authored hooks are never rewritten.
///
/// Installation is opt-in because it edits a user-global file; see
/// `AppSettings.claudeHooksEnabled` and the Settings window.
enum ClaudeHooks {

  /// Lifecycle events DraftFrame subscribes to, and whether each runs
  /// asynchronously. Session boundaries stay synchronous so the payload is
  /// delivered before the process moves on (SessionEnd fires right before
  /// exit); the chatty mid-turn events run in the background so they can
  /// never delay a tool call or the prompt returning.
  static let events: [(name: String, async: Bool)] = [
    ("SessionStart", false),
    ("UserPromptSubmit", true),
    ("PreToolUse", true),
    ("PostToolUse", true),
    ("Notification", true),
    ("Stop", true),
    ("SessionEnd", false),
  ]

  static var eventNames: [String] { events.map(\.name) }

  /// Substring every managed command contains. Matching on the bridge path
  /// rather than a custom JSON key keeps the entries valid under Claude
  /// Code's settings schema.
  static let marker = "DraftFrame/hook-bridge.sh"

  /// Environment variable DraftFrame sets on every session shell. The bridge
  /// forwards it so the app can map an event to its tab without guessing.
  static let tabEnvVar = "DRAFTFRAME_SESSION_ID"
  /// Environment variable naming the socket the bridge should write to.
  /// Lets a QA instance or a second app instance use its own socket.
  static let socketEnvVar = "DRAFTFRAME_HOOK_SOCKET"

  static var supportDir: String {
    NSHomeDirectory() + "/Library/Application Support/DraftFrame"
  }
  static var bridgeScriptPath: String { supportDir + "/hook-bridge.sh" }
  static var defaultSocketPath: String { supportDir + "/hooks.sock" }
  static var settingsPath: String { NSHomeDirectory() + "/.claude/settings.json" }

  /// The bridge script. Always exits 0: a non-zero exit would surface as a
  /// hook error inside Claude Code, and exit 2 would block the action.
  /// Bails before reading stdin when the tab variable is unset so sessions
  /// launched outside DraftFrame pay only the shell spawn.
  static let bridgeScript = """
    #!/bin/sh
    # DraftFrame hook bridge. Managed by DraftFrame; edits are overwritten.
    # Forwards the Claude Code hook payload on stdin to the running DraftFrame
    # app over a Unix socket so session status and transcript binding come
    # from Claude Code itself instead of terminal parsing. Exits 0 always so
    # it can never block or slow Claude Code.
    [ -n "$\(tabEnvVar)" ] || exit 0
    sock="${\(socketEnvVar):-$HOME/Library/Application Support/DraftFrame/hooks.sock}"
    [ -S "$sock" ] || exit 0
    payload=$(cat)
    [ -n "$payload" ] || exit 0
    printf '{"tab":"%s","ppid":%s,"event":%s}\\n' "$\(tabEnvVar)" "${PPID:-0}" "$payload" \\
      | nc -U -w 1 "$sock" >/dev/null 2>&1
    exit 0
    """ + "\n"

  /// The `command` string written into settings.json. Quoted because the
  /// Application Support path contains a space.
  static var hookCommand: String { "'\(bridgeScriptPath)'" }

  // MARK: - Status

  struct Status {
    /// The bridge script exists on disk with the current contents.
    var scriptCurrent = false
    /// Events that have a managed entry in settings.json.
    var installedEvents: Set<String> = []
    /// settings.json exists but is not a JSON object.
    var settingsCorrupt = false
    /// `nc` (the socket client the bridge shells out to) is available.
    var netcatAvailable = false

    var missingEvents: [String] {
      ClaudeHooks.eventNames.filter { !installedEvents.contains($0) }
    }
    /// Fully installed: script current and every event wired.
    var isInstalled: Bool { scriptCurrent && missingEvents.isEmpty }
    /// Some managed entries exist (possibly stale or partial).
    var isPartiallyInstalled: Bool { !installedEvents.isEmpty || scriptExists }
    var scriptExists: Bool { FileManager.default.fileExists(atPath: ClaudeHooks.bridgeScriptPath) }
  }

  static func status() -> Status {
    var s = Status()
    if let existing = try? String(contentsOfFile: bridgeScriptPath, encoding: .utf8) {
      s.scriptCurrent = existing == bridgeScript
    }
    switch readSettings() {
    case .success(let settings):
      s.installedEvents = managedEvents(in: settings["hooks"] as? [String: Any])
    case .failure:
      s.settingsCorrupt = true
    }
    s.netcatAvailable = FileManager.default.isExecutableFile(atPath: "/usr/bin/nc")
    return s
  }

  // MARK: - Install / uninstall

  enum InstallError: LocalizedError {
    case settingsUnreadable(String)

    var errorDescription: String? {
      switch self {
      case .settingsUnreadable(let path):
        return "\(path) exists but is not valid JSON; fix or remove it and try again."
      }
    }
  }

  /// Write the bridge script and merge the managed entries into settings.json.
  /// Idempotent: existing managed entries are replaced, everything else in
  /// the file is preserved.
  static func install() throws {
    let fm = FileManager.default
    try fm.createDirectory(atPath: supportDir, withIntermediateDirectories: true)
    try bridgeScript.write(toFile: bridgeScriptPath, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bridgeScriptPath)

    var settings = try readSettings().get()
    settings["hooks"] = merging(
      hooks: settings["hooks"] as? [String: Any], command: hookCommand)
    try writeSettings(settings)
  }

  /// Remove every managed entry from settings.json and delete the script.
  /// User-authored hooks on the same events are left in place.
  static func uninstall() throws {
    var settings = try readSettings().get()
    if let hooks = settings["hooks"] as? [String: Any] {
      if let remaining = removingManaged(hooks: hooks) {
        settings["hooks"] = remaining
      } else {
        settings.removeValue(forKey: "hooks")
      }
      try writeSettings(settings)
    }
    try? FileManager.default.removeItem(atPath: bridgeScriptPath)
  }

  /// Re-run `install` when the preference is on but the installation has
  /// drifted (script updated with the app, entries removed by hand).
  static func repairIfNeeded() {
    guard AppSettings.claudeHooksEnabled, !status().isInstalled else { return }
    do {
      try install()
    } catch {
      NSLog("[ClaudeHooks] repair failed: %@", error.localizedDescription)
    }
  }

  // MARK: - Pure merge helpers (tested directly)

  /// A managed entry group: one matcher-less group holding the bridge command.
  static func managedGroup(command: String, async: Bool) -> [String: Any] {
    var hook: [String: Any] = ["type": "command", "command": command, "timeout": 5]
    if async { hook["async"] = true }
    return ["hooks": [hook]]
  }

  /// `hooks` with DraftFrame's groups added (or refreshed) on every managed
  /// event. Other groups, including user hooks on the same events, are kept.
  static func merging(hooks: [String: Any]?, command: String) -> [String: Any] {
    var result = removingManaged(hooks: hooks ?? [:]) ?? [:]
    for event in events {
      // Don't clobber a value we don't understand (not an array of groups).
      if let existing = result[event.name], !(existing is [[String: Any]]) { continue }
      var groups = result[event.name] as? [[String: Any]] ?? []
      groups.append(managedGroup(command: command, async: event.async))
      result[event.name] = groups
    }
    return result
  }

  /// `hooks` with every managed group removed. Returns nil when nothing is
  /// left so the caller can drop the key entirely.
  static func removingManaged(hooks: [String: Any]) -> [String: Any]? {
    var result: [String: Any] = [:]
    for (event, value) in hooks {
      guard let groups = value as? [[String: Any]] else {
        result[event] = value
        continue
      }
      let kept = groups.filter { !isManaged(group: $0) }
      if !kept.isEmpty { result[event] = kept }
    }
    return result.isEmpty ? nil : result
  }

  /// Events that currently carry a managed group.
  static func managedEvents(in hooks: [String: Any]?) -> Set<String> {
    guard let hooks else { return [] }
    var out: Set<String> = []
    for (event, value) in hooks {
      guard let groups = value as? [[String: Any]] else { continue }
      if groups.contains(where: isManaged(group:)) { out.insert(event) }
    }
    return out
  }

  static func isManaged(group: [String: Any]) -> Bool {
    guard let hooks = group["hooks"] as? [[String: Any]] else { return false }
    return hooks.contains { ($0["command"] as? String)?.contains(marker) == true }
  }

  // MARK: - settings.json I/O

  private static func readSettings() -> Result<[String: Any], Error> {
    guard let data = FileManager.default.contents(atPath: settingsPath) else {
      return .success([:])
    }
    if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
      return .success([:])
    }
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return .failure(InstallError.settingsUnreadable(settingsPath))
    }
    return .success(obj)
  }

  private static func writeSettings(_ settings: [String: Any]) throws {
    let dir = (settingsPath as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(
      withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try data.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
  }
}
