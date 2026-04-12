import AppKit
import Foundation

/// Manages toolkit commands loaded from config.
final class ToolkitManager {
  static let shared = ToolkitManager()

  struct ToolkitCommand {
    let name: String
    let command: String
    let icon: String
  }

  private(set) var commands: [ToolkitCommand] = []

  /// Path to the user's toolkit config file.
  static let configPath = NSHomeDirectory() + "/.config/draftframe/toolkit.json"

  private var fileWatcherSource: DispatchSourceFileSystemObject?

  private init() {
    loadConfig()
    startWatching()
  }

  deinit {
    fileWatcherSource?.cancel()
  }

  /// Watch toolkit.json for changes and auto-reload.
  private func startWatching() {
    let path = ToolkitManager.configPath
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

  /// Load commands from ~/.config/draftframe/toolkit.json
  /// If the file doesn't exist, write defaults there first.
  func loadConfig() {
    let fm = FileManager.default
    let configPath = ToolkitManager.configPath
    let configDir = (configPath as NSString).deletingLastPathComponent

    // Ensure the config directory exists
    if !fm.fileExists(atPath: configDir) {
      try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
    }

    // If no config file, write defaults
    if !fm.fileExists(atPath: configPath) {
      writeDefaults()
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
      let data = FileManager.default.contents(atPath: configPath),
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

  /// Write the default toolkit config to disk.
  private func writeDefaults() {
    let defaults: [String: Any] = [
      "commands": [
        ["name": "Run Tests", "icon": "checkmark.circle", "command": "npm test"],
        ["name": "Build", "icon": "hammer", "command": "npm run build"],
        ["name": "Lint", "icon": "wand.and.stars", "command": "npm run lint"],
      ]
    ]

    if let data = try? JSONSerialization.data(
      withJSONObject: defaults, options: [.prettyPrinted, .sortedKeys])
    {
      FileManager.default.createFile(atPath: ToolkitManager.configPath, contents: data)
    }
  }

  private func defaultCommands() -> [ToolkitCommand] {
    [
      ToolkitCommand(name: "Run Tests", command: "npm test", icon: "checkmark.circle"),
      ToolkitCommand(name: "Build", command: "npm run build", icon: "hammer"),
      ToolkitCommand(name: "Lint", command: "npm run lint", icon: "wand.and.stars"),
    ]
  }

  /// Open the toolkit config file in the user's default editor.
  func openConfigInEditor() {
    let url = URL(fileURLWithPath: ToolkitManager.configPath)
    NSWorkspace.shared.open(url)
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
