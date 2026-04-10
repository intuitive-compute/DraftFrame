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

    private init() {
        loadConfig()
    }

    /// Load commands from ~/.config/draftframe/toolkit.json
    func loadConfig() {
        let configPath = NSHomeDirectory() + "/.config/draftframe/toolkit.json"

        if let data = FileManager.default.contents(atPath: configPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
            commands = json.compactMap { entry in
                guard let name = entry["name"], let cmd = entry["command"] else { return nil }
                return ToolkitCommand(name: name, command: cmd, icon: entry["icon"] ?? "terminal")
            }
        }

        // If no config or empty, use defaults
        if commands.isEmpty {
            commands = [
                ToolkitCommand(name: "Run Tests", command: "npm test", icon: "checkmark.circle"),
                ToolkitCommand(name: "Build", command: "npm run build", icon: "hammer"),
                ToolkitCommand(name: "Lint", command: "npm run lint", icon: "wand.and.stars"),
            ]
        }
    }

    /// Run a toolkit command in the given directory, returning the Process.
    @discardableResult
    func runCommand(_ command: ToolkitCommand, inDirectory dir: String?, completion: @escaping (String, Int32) -> Void) -> Process {
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
