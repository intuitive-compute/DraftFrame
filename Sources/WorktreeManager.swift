import Foundation

/// Manages git worktrees for isolated parallel sessions.
final class WorktreeManager {
    static let shared = WorktreeManager()

    struct Worktree {
        let path: String
        let branch: String
        let head: String
        let isBare: Bool
    }

    /// Base directory for draftframe worktrees.
    private var worktreeBase: String {
        let cwd = FileManager.default.currentDirectoryPath
        return cwd + "/.draftframe/worktrees"
    }

    private init() {
        // Ensure worktree directory exists
        try? FileManager.default.createDirectory(
            atPath: worktreeBase,
            withIntermediateDirectories: true
        )
    }

    /// Create a new worktree.
    func createWorktree(name: String, baseBranch: String = "main") throws -> String {
        let worktreePath = "\(worktreeBase)/\(name)"

        // Create the branch and worktree
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["worktree", "add", "-b", name, worktreePath, baseBranch]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()

        try proc.run()
        proc.waitUntilExit()

        if proc.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "Unknown error"
            // If branch exists, try without -b
            if errMsg.contains("already exists") {
                let proc2 = Process()
                proc2.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                proc2.arguments = ["worktree", "add", worktreePath, name]
                proc2.standardError = Pipe()
                proc2.standardOutput = Pipe()
                try proc2.run()
                proc2.waitUntilExit()
                if proc2.terminationStatus != 0 {
                    throw WorktreeError.creationFailed(errMsg)
                }
            } else {
                throw WorktreeError.creationFailed(errMsg)
            }
        }

        return worktreePath
    }

    /// List all worktrees by parsing `git worktree list --porcelain`.
    func listWorktrees() -> [Worktree] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["worktree", "list", "--porcelain"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var worktrees: [Worktree] = []
        var currentPath = ""
        var currentBranch = ""
        var currentHead = ""
        var currentBare = false

        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("worktree ") {
                if !currentPath.isEmpty {
                    worktrees.append(Worktree(path: currentPath, branch: currentBranch, head: currentHead, isBare: currentBare))
                }
                currentPath = String(line.dropFirst("worktree ".count))
                currentBranch = ""
                currentHead = ""
                currentBare = false
            } else if line.hasPrefix("HEAD ") {
                currentHead = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                let full = String(line.dropFirst("branch ".count))
                // Strip refs/heads/
                if full.hasPrefix("refs/heads/") {
                    currentBranch = String(full.dropFirst("refs/heads/".count))
                } else {
                    currentBranch = full
                }
            } else if line == "bare" {
                currentBare = true
            }
        }

        // Don't forget the last entry
        if !currentPath.isEmpty {
            worktrees.append(Worktree(path: currentPath, branch: currentBranch, head: currentHead, isBare: currentBare))
        }

        return worktrees
    }

    /// Remove a worktree by name.
    func removeWorktree(name: String) throws {
        let worktreePath = "\(worktreeBase)/\(name)"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["worktree", "remove", worktreePath, "--force"]
        proc.standardOutput = Pipe()
        let errPipe = Pipe()
        proc.standardError = errPipe

        try proc.run()
        proc.waitUntilExit()

        if proc.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "Unknown error"
            throw WorktreeError.removeFailed(errMsg)
        }
    }

    enum WorktreeError: Error, LocalizedError {
        case creationFailed(String)
        case removeFailed(String)

        var errorDescription: String? {
            switch self {
            case .creationFailed(let msg): return "Worktree creation failed: \(msg)"
            case .removeFailed(let msg): return "Worktree removal failed: \(msg)"
            }
        }
    }
}
