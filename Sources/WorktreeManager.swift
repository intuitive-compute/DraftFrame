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

    /// Detect the git repo root from the current directory or home.
    private(set) var repoRoot: String?

    /// Base directory for draftframe worktrees.
    private var worktreeBase: String? {
        guard let root = repoRoot else { return nil }
        return root + "/.draftframe/worktrees"
    }

    private init() {
        detectRepoRoot()
    }

    /// Find the git repo root. Tries multiple locations.
    func detectRepoRoot(from dir: String? = nil) {
        if let dir = dir {
            if tryDetect(dir) { return }
        }

        // Try CWD (works when launched from terminal)
        let cwd = FileManager.default.currentDirectoryPath
        if tryDetect(cwd) { return }

        // Try the executable's own directory (works for dev builds)
        let execPath = Bundle.main.executablePath ?? ""
        let execDir = (execPath as NSString).deletingLastPathComponent
        if tryDetect(execDir) { return }

        // Walk up from exec dir looking for .git
        var search = execDir
        for _ in 0..<10 {
            search = (search as NSString).deletingLastPathComponent
            if search == "/" { break }
            if tryDetect(search) { return }
        }
    }

    private func tryDetect(_ dir: String) -> Bool {
        guard FileManager.default.fileExists(atPath: dir) else { return false }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", dir, "rev-parse", "--show-toplevel"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let root = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let root = root, !root.isEmpty {
                    repoRoot = root
                    try? FileManager.default.createDirectory(
                        atPath: root + "/.draftframe/worktrees",
                        withIntermediateDirectories: true
                    )
                    return true
                }
            }
        } catch {}
        return false
    }

    /// Create a new worktree.
    func createWorktree(name: String, baseBranch: String? = nil) throws -> String {
        guard let base = worktreeBase, let root = repoRoot else {
            throw WorktreeError.creationFailed("Not in a git repository. Open a terminal in a git repo first.")
        }

        let worktreePath = "\(base)/\(name)"
        let branchName = "draftframe/\(name)"

        // Detect default branch if not specified
        let resolvedBase = baseBranch ?? detectDefaultBranch(in: root) ?? "main"

        // Create the branch and worktree
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["worktree", "add", "-b", branchName, worktreePath, resolvedBase]
        proc.currentDirectoryURL = URL(fileURLWithPath: root)
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
                proc2.arguments = ["-C", root, "worktree", "add", worktreePath, branchName]
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

    private func detectDefaultBranch(in dir: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", dir, "branch", "--show-current"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let branch = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (branch?.isEmpty == false) ? branch : nil
        } catch { return nil }
    }

    /// List all worktrees by parsing `git worktree list --porcelain`.
    func listWorktrees() -> [Worktree] {
        guard let root = repoRoot else { return [] }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", root, "worktree", "list", "--porcelain"]
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
        guard let base = worktreeBase, let root = repoRoot else {
            throw WorktreeError.removeFailed("Not in a git repository")
        }
        let worktreePath = "\(base)/\(name)"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", root, "worktree", "remove", worktreePath, "--force"]
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
