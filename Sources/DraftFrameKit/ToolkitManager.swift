import AppKit
import Foundation

/// Manages toolkit commands loaded from config.
///
/// Resolution order:
///   1. `<projectDir>/.draftframe/toolkit.json`  (project-local)
///   2. `~/.config/draftframe/toolkit.json`       (global fallback)
///
/// The active config path is re-evaluated whenever the project directory
/// changes. A file watcher auto-reloads on save.
final class ToolkitManager {
  static let shared = ToolkitManager()

  struct ToolkitCommand {
    let name: String
    let command: String
    let icon: String
  }

  private(set) var commands: [ToolkitCommand] = []

  /// Global fallback config path.
  static let globalConfigPath = NSHomeDirectory() + "/.config/draftframe/toolkit.json"

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
  @objc private func activeSessionChanged() {
    let projectDir = SessionManager.shared.activeSession?.worktreePath
      ?? SessionManager.shared.projectDir
    setProjectDirectory(projectDir)
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
      let projectConfig = (dir as NSString).appendingPathComponent(".draftframe/toolkit.json")
      if FileManager.default.fileExists(atPath: projectConfig) {
        return projectConfig
      }
    }
    return ToolkitManager.globalConfigPath
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
        source.cancel()
        close(fd)
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

  /// Open the project-local toolkit config in the user's default editor.
  /// Creates .draftframe/toolkit.json in the project if it doesn't exist yet.
  func openConfigInEditor() {
    let path: String
    if let dir = currentProjectDir {
      path = (dir as NSString).appendingPathComponent(".draftframe/toolkit.json")
      if !FileManager.default.fileExists(atPath: path) {
        writeDefaults(to: path)
        // Switch to the newly created project config
        activeConfigPath = path
        loadConfig()
        restartWatching()
        NotificationCenter.default.post(name: .toolkitDidChange, object: nil)
      }
    } else {
      path = ToolkitManager.globalConfigPath
    }
    NSWorkspace.shared.open(URL(fileURLWithPath: path))
  }
}

extension Notification.Name {
  static let toolkitDidChange = Notification.Name("DFToolkitDidChange")
}

extension ToolkitManager {
  /// Run a toolkit command in the given directory, returning the Process.
  @discardableResult
  func runCommand(
    _ command: ToolkitCommand, inDirectory dir: String?,
    completion: @escaping (String, Int32) -> Void
  ) -> Process {
    let proc = Process()
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    proc.executableURL = URL(fileURLWithPath: shell)
    proc.arguments = ["-l", "-c", command.command]

    if let dir = dir {
      proc.currentDirectoryURL = URL(fileURLWithPath: dir)
    }

    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe

    proc.terminationHandler = { _ in
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let output = String(data: data, encoding: .utf8) ?? ""
      DispatchQueue.main.async {
        completion(output, proc.terminationStatus)
      }
    }

    do {
      try proc.run()
    } catch {
      DispatchQueue.main.async {
        completion("Failed to run: \(error.localizedDescription)", 1)
      }
    }

    return proc
  }
}
