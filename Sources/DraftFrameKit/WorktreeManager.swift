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

  /// The path component that identifies draftframe-managed worktrees.
  static let worktreeSubpath = "/.claude/worktrees"

  /// Base directory for draftframe worktrees.
  private var worktreeBase: String? {
    guard let root = repoRoot else { return nil }
    return root + Self.worktreeSubpath
  }

  /// Whether a path is a draftframe-managed worktree (lives under
  /// `<repo>/.claude/worktrees/`). Resolves symlinks before checking.
  static func isManagedWorktree(_ path: String) -> Bool {
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    return resolved.contains(worktreeSubpath + "/")
  }

  /// Resolve the git repo root for an arbitrary path.
  static func repoRoot(at path: String) -> String? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    proc.arguments = ["-C", path, "rev-parse", "--show-toplevel"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    do {
      try proc.run()
      proc.waitUntilExit()
      guard proc.terminationStatus == 0 else { return nil }
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      return String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
      return nil
    }
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
        let root = String(data: data, encoding: .utf8)?.trimmingCharacters(
          in: .whitespacesAndNewlines)
        if let root = root, !root.isEmpty {
          repoRoot = root
          try? FileManager.default.createDirectory(
            atPath: root + Self.worktreeSubpath,
            withIntermediateDirectories: true
          )
          return true
        }
      }
    } catch {}
    return false
  }

  /// Create a new worktree using the singleton's repo root.
  func createWorktree(name: String, baseBranch: String? = nil) throws -> String {
    guard let root = repoRoot else {
      throw WorktreeError.creationFailed(
        "Not in a git repository. Open a terminal in a git repo first.")
    }
    return try createWorktree(repoRoot: root, name: name, baseBranch: baseBranch)
  }

  /// Create a new worktree in the specified repo.
  func createWorktree(repoRoot root: String, name: String, baseBranch: String? = nil) throws
    -> String
  {
    let base = root + Self.worktreeSubpath
    try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)

    let worktreePath = "\(base)/\(name)"
    let branchName = name

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

  /// Create a worktree that checks out an existing branch. Tries the local
  /// branch first; when the branch only exists on origin, creates a local
  /// tracking branch from it. The worktree directory flattens any `/` in the
  /// branch name so it stays a single path component.
  func createWorktree(repoRoot root: String, checkoutBranch branch: String) throws -> String {
    let base = root + Self.worktreeSubpath
    try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)

    let dirName = branch.replacingOccurrences(of: "/", with: "-")
    let worktreePath = "\(base)/\(dirName)"

    let localError = runGit(
      ["-C", root, "worktree", "add", worktreePath, branch], in: root)
    guard let localError = localError else { return worktreePath }

    // Fall back to a remote-only branch on origin.
    let remoteError = runGit(
      ["-C", root, "worktree", "add", "--track", "-b", branch, worktreePath, "origin/\(branch)"],
      in: root)
    if remoteError == nil { return worktreePath }

    throw WorktreeError.creationFailed(localError)
  }

  /// Environment for git subprocesses: GIT_* vars scrubbed (a stray
  /// GIT_DIR/GIT_WORK_TREE inherited from the launching session would
  /// redirect git to the wrong repo) and terminal prompting disabled so a
  /// network command can never hang waiting for credentials.
  private static func gitEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
      .filter { !$0.key.hasPrefix("GIT_") }
    env["GIT_TERMINAL_PROMPT"] = "0"
    return env
  }

  /// Run git with `args`; returns nil on success, stderr text on failure.
  private func runGit(_ args: [String], in dir: String) -> String? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    proc.arguments = args
    proc.environment = Self.gitEnvironment()
    proc.currentDirectoryURL = URL(fileURLWithPath: dir)
    let errPipe = Pipe()
    proc.standardError = errPipe
    proc.standardOutput = FileHandle.nullDevice
    let errData: Data
    do {
      try proc.run()
      // Read to EOF before waiting — stderr past the 64KB pipe buffer would
      // otherwise deadlock git against waitUntilExit().
      errData = errPipe.fileHandleForReading.readDataToEndOfFile()
      proc.waitUntilExit()
    } catch {
      return error.localizedDescription
    }
    guard proc.terminationStatus != 0 else { return nil }
    return String(data: errData, encoding: .utf8) ?? "Unknown error"
  }

  /// Run git with `args`; returns trimmed stdout on success, nil on failure.
  private func gitOutput(_ args: [String], in dir: String) -> String? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    proc.arguments = args
    proc.environment = Self.gitEnvironment()
    proc.currentDirectoryURL = URL(fileURLWithPath: dir)
    let outPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = FileHandle.nullDevice
    let data: Data
    do {
      try proc.run()
      data = outPipe.fileHandleForReading.readDataToEndOfFile()
      proc.waitUntilExit()
    } catch {
      return nil
    }
    guard proc.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Detect a repo's default branch: the remote HEAD when the clone recorded
  /// one (refs/remotes/origin/HEAD), else a local `main` or `master`.
  func defaultBranch(repoRoot root: String) -> String? {
    if let ref = gitOutput(
      ["-C", root, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: root),
      let name = ref.split(separator: "/", maxSplits: 1).last.map(String.init),
      !name.isEmpty
    {
      return name
    }
    for name in ["main", "master"]
    where gitOutput(
      ["-C", root, "rev-parse", "--verify", "--quiet", "refs/heads/\(name)"], in: root) != nil
    {
      return name
    }
    return nil
  }

  /// Fast-forward `branch` (the repo's default branch) from its remote.
  /// Returns nil on success, or a user-facing error message on failure.
  ///
  /// When the branch is checked out somewhere — the main repo or a worktree —
  /// the pull runs from that checkout so the working tree advances with the
  /// ref, and git itself reports why a plain pull isn't safe there (dirty
  /// checkout, diverged history). When it isn't checked out anywhere, the
  /// ref is fast-forwarded directly via `git fetch <remote> <branch>:<branch>`,
  /// which touches no working tree and refuses non-fast-forward updates.
  func pullDefaultBranch(repoRoot root: String, branch: String) -> String? {
    let remote =
      gitOutput(["-C", root, "config", "--get", "branch.\(branch).remote"], in: root) ?? "origin"

    if let checkout = listWorktrees(repoRoot: root)
      .first(where: { !$0.isBare && $0.branch == branch })
    {
      return runGit(["-C", checkout.path, "pull", "--ff-only", remote, branch], in: checkout.path)
    }
    return runGit(["-C", root, "fetch", remote, "\(branch):\(branch)"], in: root)
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
      let branch = String(data: data, encoding: .utf8)?.trimmingCharacters(
        in: .whitespacesAndNewlines)
      return (branch?.isEmpty == false) ? branch : nil
    } catch { return nil }
  }

  /// List all worktrees by parsing `git worktree list --porcelain`.
  func listWorktrees() -> [Worktree] {
    guard let root = repoRoot else { return [] }
    return listWorktrees(repoRoot: root)
  }

  /// List the worktrees of the repo rooted at `root`.
  func listWorktrees(repoRoot root: String) -> [Worktree] {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    proc.arguments = ["-C", root, "worktree", "list", "--porcelain"]
    proc.environment = Self.gitEnvironment()
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice

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
          worktrees.append(
            Worktree(
              path: currentPath, branch: currentBranch, head: currentHead, isBare: currentBare))
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
      worktrees.append(
        Worktree(path: currentPath, branch: currentBranch, head: currentHead, isBare: currentBare))
    }

    return worktrees
  }

  /// Remove the worktree at the given path from the repo rooted at `repoRoot`.
  /// Git accepts either a path or the worktree's name (the last path component,
  /// as stored in `.git/worktrees/<name>/`) — we pass the name, which sidesteps
  /// path mismatches from symlinks or stale admin entries.
  ///
  /// `repoRoot` must be the main repo for this worktree (not DraftFrame's own
  /// repo or some other project's repo). Callers in multi-project contexts
  /// must pass the right value; this does not consult `self.repoRoot`.
  func removeWorktree(repoRoot root: String, path: String) throws {
    let name = (path as NSString).lastPathComponent

    // Scrub GIT_* env vars so a stray GIT_DIR/GIT_WORK_TREE inherited from
    // launchd doesn't redirect git to the wrong repo.
    let env = ProcessInfo.processInfo.environment
      .filter { !$0.key.hasPrefix("GIT_") }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    proc.arguments = ["-C", root, "worktree", "remove", "--force", name]
    proc.environment = env
    proc.currentDirectoryURL = URL(fileURLWithPath: root)
    proc.standardOutput = Pipe()
    let errPipe = Pipe()
    proc.standardError = errPipe

    NSLog(
      "[WorktreeManager] removeWorktree: repoRoot=%@ path=%@ name=%@",
      root, path, name)

    try proc.run()
    proc.waitUntilExit()

    if proc.terminationStatus != 0 {
      let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
      let errMsg = String(data: errData, encoding: .utf8) ?? "Unknown error"
      let listing = debugWorktreeListing(root: root, env: env)
      NSLog("[WorktreeManager] removeWorktree failed: %@\nListing:\n%@", errMsg, listing)

      // Worktree removal failed — try to at least clean up the branch
      // so it doesn't linger in the project view.
      deleteBranch(name: name, repoRoot: root, env: env)

      throw WorktreeError.removeFailed(
        "\(errMsg)\n\nDraftFrame repoRoot: \(root)\nTarget name: \(name)\n\nGit's view of worktrees:\n\(listing)"
      )
    }
  }

  /// Rename a managed worktree: renames its checked-out branch to `newName`
  /// and moves its directory to `<repo>/.claude/worktrees/<newName>`.
  /// Returns the worktree's new path.
  ///
  /// `repoRoot` must be the main repo for this worktree; this does not
  /// consult `self.repoRoot`.
  func renameWorktree(repoRoot root: String, worktree: Worktree, newName: String) throws -> String {
    let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      throw WorktreeError.renameFailed("The new name is empty.")
    }
    guard !name.contains("/") else {
      throw WorktreeError.renameFailed("The new name can't contain \"/\".")
    }
    let newPath = root + Self.worktreeSubpath + "/" + name
    // Compare symlink-resolved paths: git reports realpaths (e.g. /private/var
    // on macOS) while callers may hold the unresolved spelling.
    let resolvedNew = URL(fileURLWithPath: newPath).resolvingSymlinksInPath().path
    let resolvedOld = URL(fileURLWithPath: worktree.path).resolvingSymlinksInPath().path
    guard resolvedNew != resolvedOld else { return worktree.path }
    guard !FileManager.default.fileExists(atPath: newPath) else {
      throw WorktreeError.renameFailed("\(newPath) already exists.")
    }

    // Rename the branch first — `git branch -m` validates the new name and
    // fails cleanly if a branch by that name already exists, leaving the
    // worktree untouched.
    let oldBranch = worktree.branch
    if !oldBranch.isEmpty, oldBranch != name {
      if let err = runGit(["-C", root, "branch", "-m", oldBranch, name], in: root) {
        throw WorktreeError.renameFailed(err)
      }
    }

    if let err = runGit(["-C", root, "worktree", "move", worktree.path, newPath], in: root) {
      // Best-effort roll back the branch rename so a failed move doesn't
      // leave the branch and directory names out of sync.
      if !oldBranch.isEmpty, oldBranch != name {
        _ = runGit(["-C", root, "branch", "-m", name, oldBranch], in: root)
      }
      throw WorktreeError.renameFailed(err)
    }

    return newPath
  }

  /// Pull the branch checked out in the repo's primary worktree — the branch
  /// new worktrees are based on when none is specified. Fast-forward only, so
  /// a diverged local branch fails with git's explanation instead of silently
  /// creating a merge commit.
  func pull(repoRoot root: String) throws {
    // Scrub GIT_* env vars so a stray GIT_DIR/GIT_WORK_TREE inherited from
    // the launching session doesn't redirect git to the wrong repo.
    let env = ProcessInfo.processInfo.environment
      .filter { !$0.key.hasPrefix("GIT_") }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    proc.arguments = ["-C", root, "pull", "--ff-only"]
    proc.environment = env
    proc.standardOutput = FileHandle.nullDevice
    let errPipe = Pipe()
    proc.standardError = errPipe

    do {
      try proc.run()
    } catch {
      throw WorktreeError.pullFailed(error.localizedDescription)
    }
    // Read to EOF before waiting — stderr past the 64KB pipe buffer would
    // otherwise deadlock git against waitUntilExit().
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()

    if proc.terminationStatus != 0 {
      let errMsg = String(data: errData, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw WorktreeError.pullFailed(
        (errMsg?.isEmpty == false) ? errMsg! : "git pull exited with a non-zero status")
    }
  }

  /// Best-effort `git branch -D <name>`. Silently ignores failures (the
  /// branch may already be gone, or it may be checked out elsewhere).
  private func deleteBranch(name: String, repoRoot root: String, env: [String: String]) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    proc.arguments = ["-C", root, "branch", "-D", name]
    proc.environment = env
    proc.currentDirectoryURL = URL(fileURLWithPath: root)
    proc.standardOutput = Pipe()
    proc.standardError = Pipe()
    do {
      try proc.run()
      proc.waitUntilExit()
      if proc.terminationStatus == 0 {
        NSLog("[WorktreeManager] deleted branch %@", name)
      } else {
        NSLog(
          "[WorktreeManager] branch delete skipped for %@ (may not exist or is checked out)", name)
      }
    } catch {
      NSLog("[WorktreeManager] branch delete failed for %@: %@", name, error.localizedDescription)
    }
  }

  /// Run `git worktree list --porcelain` and return its combined output, for
  /// diagnostic error messages.
  private func debugWorktreeListing(root: String, env: [String: String]) -> String {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    proc.arguments = ["-C", root, "worktree", "list", "--porcelain"]
    proc.environment = env
    proc.currentDirectoryURL = URL(fileURLWithPath: root)
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe
    do {
      try proc.run()
      proc.waitUntilExit()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      return String(data: data, encoding: .utf8) ?? "(no output)"
    } catch {
      return "(failed to run: \(error.localizedDescription))"
    }
  }

  enum WorktreeError: Error, LocalizedError {
    case creationFailed(String)
    case removeFailed(String)
    case renameFailed(String)
    case pullFailed(String)

    var errorDescription: String? {
      switch self {
      case .creationFailed(let msg): return "Worktree creation failed: \(msg)"
      case .removeFailed(let msg): return "Worktree removal failed: \(msg)"
      case .renameFailed(let msg): return "Worktree rename failed: \(msg)"
      case .pullFailed(let msg): return "Pull failed: \(msg)"
      }
    }
  }
}
