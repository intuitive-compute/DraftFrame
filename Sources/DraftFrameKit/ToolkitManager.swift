import AppKit
import CryptoKit
import Foundation

/// Manages toolkit commands loaded from config.
///
/// Resolution order:
///   1. `~/.config/draftframe/toolkits/<project>-<hash>.json`  (per-project, app data)
///   2. `<projectDir>/.claude/toolkit.json`  (legacy project-local; migrated to 1 on sight)
///   3. `~/.config/draftframe/toolkit.json`  (global fallback)
///
/// Per-project configs live in app data rather than the project tree so they
/// survive worktree cleanup and `git clean`. The active config path is
/// re-evaluated whenever the project directory changes. A file watcher
/// auto-reloads on save.
final class ToolkitManager {
  static let shared = ToolkitManager()

  struct ToolkitCommand {
    var name: String
    var command: String
    var icon: String
  }

  private(set) var commands: [ToolkitCommand] = []

  /// Global fallback config path.
  static let globalConfigPath = NSHomeDirectory() + "/.config/draftframe/toolkit.json"

  /// Directory holding per-project toolkit configs in app data.
  static let toolkitsDir = NSHomeDirectory() + "/.config/draftframe/toolkits"

  /// App-data config path for a project: readable name + stable hash of the
  /// full path, so same-named projects in different locations don't collide.
  static func appDataConfigPath(forProjectDir dir: String) -> String {
    let standardized = URL(fileURLWithPath: dir).standardizedFileURL.path
    let name = (standardized as NSString).lastPathComponent.lowercased()
      .map { $0.isLetter || $0.isNumber ? $0 : "-" }
      .reduce(into: "") { $0.append($1) }
    let digest = SHA256.hash(data: Data(standardized.utf8))
    let short = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    return toolkitsDir + "/\(name)-\(short).json"
  }

  /// The currently active config file path (project-local or global).
  private(set) var activeConfigPath: String = ToolkitManager.globalConfigPath

  /// The project directory we're currently tracking.
  private var currentProjectDir: String?

  private var fileWatcherSource: DispatchSourceFileSystemObject?

  private init() {
    loadConfig()
    startWatching()

    NotificationCenter.default.addObserver(
      self, selector: #selector(activeSessionChanged),
      name: .activeSessionDidChange, object: nil
    )
  }

  deinit {
    fileWatcherSource?.cancel()
    NotificationCenter.default.removeObserver(self)
  }

  /// Re-evaluate which toolkit.json to use when the active session changes.
  /// Keyed by the project dir (not the session's worktree) so every session
  /// of a project shares one toolkit and configs don't die with worktrees.
  @objc private func activeSessionChanged() {
    setProjectDirectory(SessionManager.shared.projectDir)
  }

  /// Update the project directory and reload if the active config path changed.
  func setProjectDirectory(_ dir: String?) {
    guard dir != currentProjectDir else { return }
    currentProjectDir = dir
    let newPath = resolveConfigPath()
    if newPath != activeConfigPath {
      activeConfigPath = newPath
      loadConfig()
      restartWatching()
      NotificationCenter.default.post(name: .toolkitDidChange, object: nil)
    }
  }

  /// Determine which toolkit.json to use.
  private func resolveConfigPath() -> String {
    if let dir = currentProjectDir {
      let appData = Self.appDataConfigPath(forProjectDir: dir)
      if FileManager.default.fileExists(atPath: appData) {
        return appData
      }
      // Legacy project-local config: copy it into app data once, then use
      // the app-data copy from here on.
      let projectConfig = (dir as NSString).appendingPathComponent(".claude/toolkit.json")
      if FileManager.default.fileExists(atPath: projectConfig) {
        migrateLegacyConfig(from: projectConfig, to: appData)
        return appData
      }
    }
    return ToolkitManager.globalConfigPath
  }

  /// Copy a legacy project-local config into app data. The original is left
  /// in place (it may be committed to the repo) but is no longer read.
  private func migrateLegacyConfig(from src: String, to dst: String) {
    let fm = FileManager.default
    try? fm.createDirectory(
      atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try? fm.copyItem(atPath: src, toPath: dst)
  }

  // MARK: - File Watching

  private func restartWatching() {
    fileWatcherSource?.cancel()
    fileWatcherSource = nil
    startWatching()
  }

  /// Watch the active toolkit.json for changes and auto-reload.
  private func startWatching() {
    let path = activeConfigPath
    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else { return }

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd,
      eventMask: [.write, .delete, .rename],
      queue: .main
    )

    source.setEventHandler { [weak self] in
      guard let self = self else { return }
      let flags = source.data
      if flags.contains(.delete) || flags.contains(.rename) {
        // File was replaced (common with editors that save atomically).
        // `cancel()` triggers the cancel handler, which is the sole owner of
        // `close(fd)`. Closing it here too would double-close once the number
        // is reused and crash libdispatch with EV_VANISHED.
        source.cancel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
          self.loadConfig()
          NotificationCenter.default.post(name: .toolkitDidChange, object: nil)
          self.startWatching()
        }
      } else {
        self.loadConfig()
        NotificationCenter.default.post(name: .toolkitDidChange, object: nil)
      }
    }

    source.setCancelHandler {
      close(fd)
    }

    fileWatcherSource = source
    source.resume()
  }

  // MARK: - Config Loading

  /// Load commands from the active toolkit.json.
  func loadConfig() {
    let fm = FileManager.default
    let configPath = activeConfigPath

    // For the global config, ensure directory and defaults exist.
    if configPath == ToolkitManager.globalConfigPath {
      let configDir = (configPath as NSString).deletingLastPathComponent
      if !fm.fileExists(atPath: configDir) {
        try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
      }
      if !fm.fileExists(atPath: configPath) {
        writeDefaults(to: configPath)
      }
    }

    // Parse the config
    if let data = fm.contents(atPath: configPath),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let cmdArray = json["commands"] as? [[String: String]]
    {
      commands = cmdArray.compactMap { entry in
        guard let name = entry["name"], let cmd = entry["command"] else { return nil }
        return ToolkitCommand(name: name, command: cmd, icon: entry["icon"] ?? "terminal")
      }
    }

    // Fallback: try legacy flat-array format for backward compat
    if commands.isEmpty,
      let data = fm.contents(atPath: configPath),
      let json = try? JSONSerialization.jsonObject(with: data) as? [[String: String]]
    {
      commands = json.compactMap { entry in
        guard let name = entry["name"], let cmd = entry["command"] else { return nil }
        return ToolkitCommand(name: name, command: cmd, icon: entry["icon"] ?? "terminal")
      }
    }

    // If still empty (corrupt file?), use in-memory defaults
    if commands.isEmpty {
      commands = defaultCommands()
    }
  }

  /// Write the default toolkit config to a path.
  private func writeDefaults(to path: String) {
    let defaults: [String: Any] = [
      "commands": [
        ["name": "Run Tests", "icon": "checkmark.circle", "command": "npm test"],
        ["name": "Build", "icon": "hammer", "command": "npm run build"],
        ["name": "Lint", "icon": "wand.and.stars", "command": "npm run lint"],
      ]
    ]

    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    if let data = try? JSONSerialization.data(
      withJSONObject: defaults, options: [.prettyPrinted, .sortedKeys])
    {
      FileManager.default.createFile(atPath: path, contents: data)
    }
  }

  private func defaultCommands() -> [ToolkitCommand] {
    [
      ToolkitCommand(name: "Run Tests", command: "npm test", icon: "checkmark.circle"),
      ToolkitCommand(name: "Build", command: "npm run build", icon: "hammer"),
      ToolkitCommand(name: "Lint", command: "npm run lint", icon: "wand.and.stars"),
    ]
  }

  /// Write the given commands to the active toolkit config file.
  func saveConfig(commands: [ToolkitCommand]) {
    let entries: [[String: String]] = commands.map {
      ["name": $0.name, "command": $0.command, "icon": $0.icon]
    }
    let dict: [String: Any] = ["commands": entries]
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
    else { return }

    let path = activeConfigPath
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: path, contents: data)
  }

  /// Ensure a per-project toolkit config exists in app data for the current
  /// project, seeding it from a legacy project-local config when one exists,
  /// otherwise with defaults, and switch to it.
  func ensureProjectConfig() {
    guard let dir = currentProjectDir else { return }
    let path = Self.appDataConfigPath(forProjectDir: dir)
    if !FileManager.default.fileExists(atPath: path) {
      let legacy = (dir as NSString).appendingPathComponent(".claude/toolkit.json")
      if FileManager.default.fileExists(atPath: legacy) {
        migrateLegacyConfig(from: legacy, to: path)
      } else {
        writeDefaults(to: path)
      }
    }
    guard activeConfigPath != path else { return }
    activeConfigPath = path
    loadConfig()
    restartWatching()
    NotificationCenter.default.post(name: .toolkitDidChange, object: nil)
  }

  /// Open the project's toolkit config in the user's default editor.
  /// Creates the app-data config if it doesn't exist yet.
  func openConfigInEditor() {
    ensureProjectConfig()
    NSWorkspace.shared.open(URL(fileURLWithPath: activeConfigPath))
  }
}

extension Notification.Name {
  static let toolkitDidChange = Notification.Name("DFToolkitDidChange")
}

