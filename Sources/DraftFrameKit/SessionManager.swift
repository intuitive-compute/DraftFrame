import AppKit
import SwiftTerm

/// Notification posted whenever session list or session state changes.
extension Notification.Name {
  static let sessionsDidChange = Notification.Name("DFSessionsDidChange")
  static let activeSessionDidChange = Notification.Name("DFActiveSessionDidChange")
  static let modelPreferenceDidChange = Notification.Name("DFModelPreferenceDidChange")
}

/// Which Claude model new sessions should launch with. Passed via `claude --model`.
enum ClaudeModel: String, CaseIterable {
  case `default` = ""
  case opus45 = "claude-opus-4-5"
  case opus46 = "claude-opus-4-6"

  var displayName: String {
    switch self {
    case .default: return "Default"
    case .opus45: return "Opus 4.5"
    case .opus46: return "Opus 4.6"
    }
  }
}

/// Maximum context window size (in tokens) for a given model identifier.
enum ModelContextWindow {
  /// Look up the cap given the bare model id from a JSONL message (e.g.
  /// `claude-opus-4-7`). The `[1m]` variant is not recorded in JSONL message
  /// bodies and `projects[cwd].lastModelUsage` is empty mid-session, so we
  /// scan every project's `lastModelUsage` in `~/.claude.json` for any
  /// `<model>[1m]` entry with non-zero usage. If the user has used the 1M
  /// variant of this model anywhere recently, treat it as their preference.
  static func maxTokens(forBareModel model: String) -> Int {
    if hasUsed1MVariant(bareModel: model) { return 1_000_000 }
    return 200_000
  }

  private static func hasUsed1MVariant(bareModel: String) -> Bool {
    guard !bareModel.isEmpty else { return false }
    let path = "\(NSHomeDirectory())/.claude.json"
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let projects = root["projects"] as? [String: Any]
    else { return false }

    let oneMKey = "\(bareModel)[1m]"
    for (_, value) in projects {
      guard let proj = value as? [String: Any],
        let usage = proj["lastModelUsage"] as? [String: Any],
        let entry = usage[oneMKey] as? [String: Any]
      else { continue }
      let inTok = entry["inputTokens"] as? Int ?? 0
      let cacheRead = entry["cacheReadInputTokens"] as? Int ?? 0
      let cacheCreate = entry["cacheCreationInputTokens"] as? Int ?? 0
      if (inTok + cacheRead + cacheCreate) > 0 { return true }
    }
    return false
  }
}

/// Persisted preference for which model to launch `claude` with.
enum ModelPreference {
  private static let key = "DFClaudeModel"

  static var current: ClaudeModel {
    get {
      let raw = UserDefaults.standard.string(forKey: key) ?? ""
      return ClaudeModel(rawValue: raw) ?? .default
    }
    set {
      UserDefaults.standard.set(newValue.rawValue, forKey: key)
      NotificationCenter.default.post(name: .modelPreferenceDidChange, object: nil)
    }
  }
}

/// State of a Claude Code session, detected from terminal output.
enum SessionState: String {
  case generating
  case thinking
  case userInput
  case idle
  case needsAttention

  var color: NSColor {
    switch self {
    case .generating: return Theme.green
    case .thinking: return Theme.yellow
    case .userInput: return Theme.accent
    case .needsAttention: return Theme.red
    case .idle: return Theme.cyan
    }
  }

  var label: String {
    switch self {
    case .generating: return "Generating"
    case .thinking: return "Thinking"
    case .userInput: return "Input"
    case .needsAttention: return "Attention"
    case .idle: return "Idle"
    }
  }
}

/// A single terminal session.
final class Session {
  let id: UUID
  var name: String
  var state: SessionState
  var model: String
  var cost: Double
  var tokensIn: Int
  var tokensOut: Int
  /// Tokens fed to the model on the most recent assistant turn.
  /// Reflects the live context window usage, not a cumulative sum.
  var contextTokens: Int
  /// Maximum context window for the model in use (200K standard, 1M for
  /// `[1m]` variants). Resolved by the JSONL watcher.
  var maxContextTokens: Int
  var worktreePath: String?
  var terminalView: ClaudeTerminalView?

  /// Real-time PTY stream analyzer for Claude Code state detection.
  let ptyAnalyzer = PTYStreamAnalyzer()

  /// Watches the Claude Code JSONL log for cost/token updates.
  var jsonlWatcher: SessionJSONLWatcher?

  init(name: String, worktreePath: String? = nil) {
    self.id = UUID()
    self.name = name
    self.state = .idle
    self.model = "sonnet"
    self.cost = 0.0
    self.tokensIn = 0
    self.tokensOut = 0
    self.contextTokens = 0
    self.maxContextTokens = 200_000
    self.worktreePath = worktreePath

    // Wire up state changes from the PTY analyzer
    ptyAnalyzer.onStateChange = { [weak self] newState in
      guard let self = self else { return }
      self.state = newState
      DispatchQueue.main.async {
        NotificationCenter.default.post(name: .sessionsDidChange, object: nil)
      }
    }
  }

  /// Start monitoring the JSONL file for the given working directory.
  func startJSONLWatcher(directory: String) {
    jsonlWatcher = SessionJSONLWatcher(workingDirectory: directory) {
      [weak self] cost, tokensIn, tokensOut, model, contextTokens, maxContextTokens in
      guard let self = self else { return }
      self.cost = cost
      self.tokensIn = tokensIn
      self.tokensOut = tokensOut
      self.model = model
      self.contextTokens = contextTokens
      self.maxContextTokens = maxContextTokens
      NotificationCenter.default.post(name: .sessionsDidChange, object: nil)
    }
  }
}

/// Singleton managing all terminal sessions.
final class SessionManager {
  static let shared = SessionManager()

  private(set) var sessions: [Session] = []
  private(set) var activeSessionIndex: Int = -1
  var projectDir: String?

  var activeSession: Session? {
    guard activeSessionIndex >= 0, activeSessionIndex < sessions.count else { return nil }
    return sessions[activeSessionIndex]
  }

  var totalCost: Double {
    sessions.reduce(0) { $0 + $1.cost }
  }

  var totalTokensIn: Int {
    sessions.reduce(0) { $0 + $1.tokensIn }
  }

  var totalTokensOut: Int {
    sessions.reduce(0) { $0 + $1.tokensOut }
  }

  private init() {}

  /// Resolve an absolute path to the user's preferred shell. Prefers an
  /// absolute $SHELL, otherwise searches standard locations for zsh/bash.
  static func resolveShellPath(parentEnv: [String: String]) -> String {
    let fm = FileManager.default
    if let s = parentEnv["SHELL"], s.hasPrefix("/"), fm.isExecutableFile(atPath: s) {
      return s
    }
    // $SHELL is missing or a bare name — search common locations.
    let name = parentEnv["SHELL"].map { ($0 as NSString).lastPathComponent } ?? "zsh"
    let searchDirs = ["/bin", "/usr/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    for dir in searchDirs {
      let candidate = (dir as NSString).appendingPathComponent(name)
      if fm.isExecutableFile(atPath: candidate) { return candidate }
    }
    return "/bin/zsh"
  }

  /// Find an absolute path to the `claude` binary. Falls back to the bare
  /// name "claude" so the shell's own PATH lookup is used as a last resort.
  static func resolveClaudePath(augmentedPath: String) -> String {
    let fm = FileManager.default

    // 1) Search the caller-provided PATH first.
    for dir in augmentedPath.split(separator: ":").map(String.init) {
      let candidate = (dir as NSString).appendingPathComponent("claude")
      if fm.isExecutableFile(atPath: candidate) { return candidate }
    }

    // 2) Check common install locations the GUI-launched app PATH misses.
    let common = [
      "/opt/homebrew/bin/claude",
      "/usr/local/bin/claude",
      (NSHomeDirectory() as NSString).appendingPathComponent(".claude/local/claude"),
      (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/claude"),
    ]
    for candidate in common where fm.isExecutableFile(atPath: candidate) {
      return candidate
    }

    // 3) Ask an interactive login shell to resolve it. This picks up any
    // PATH the user configures in .zprofile/.zshrc even if we don't know
    // about the install location.
    if let resolved = runLoginShellCommand("command -v claude"),
      !resolved.isEmpty,
      fm.isExecutableFile(atPath: resolved)
    {
      return resolved
    }

    // 4) Give up and let the shell try its own PATH.
    return "claude"
  }

  /// Synchronously runs `command` inside a login zsh and returns its trimmed
  /// stdout, or nil on failure. Used only for discovery at session creation.
  private static func runLoginShellCommand(_ command: String) -> String? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
    proc.arguments = ["-l", "-c", command]
    let out = Pipe()
    proc.standardOutput = out
    proc.standardError = Pipe()
    do {
      try proc.run()
      proc.waitUntilExit()
      let data = out.fileHandleForReading.readDataToEndOfFile()
      return String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
      return nil
    }
  }

  /// Create a new session and return it.
  @discardableResult
  func createSession(name: String? = nil, command: String? = nil, worktreePath: String? = nil)
    -> Session
  {
    let sessionName = name ?? "session-\(sessions.count + 1)"
    let session = Session(name: sessionName, worktreePath: worktreePath)

    // Create the terminal view (ClaudeTerminalView intercepts PTY data)
    let tv = ClaudeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    tv.nativeForegroundColor = Theme.text1
    tv.nativeBackgroundColor = Theme.bg
    tv.selectedTextBackgroundColor = Theme.selected
    tv.caretColor = Theme.accent
    tv.font = Theme.mono(13)
    session.terminalView = tv

    // Wire PTY data stream to the analyzer for real-time state detection
    tv.onPtyData = { [weak session] bytes in
      session?.ptyAnalyzer.feed(bytes)
    }

    // Start the process
    let parentEnv = ProcessInfo.processInfo.environment
    // Resolve the shell to an absolute path. $SHELL may be unset or set to
    // a bare name like "zsh" (some setups do this), and execve requires an
    // absolute path — passing a bare name causes the child to exit 127.
    let shell = SessionManager.resolveShellPath(parentEnv: parentEnv)

    // Build a minimal, sanitized env for the child. Passing the full
    // ProcessInfo environment can make `execve` fail (exit code 127)
    // because it contains macOS-internal variables like DYLD_* and
    // __CF_USER_TEXT_ENCODING that can trip up exec on Apple Silicon.
    // Instead, we include only the handful of vars a shell actually
    // needs and compose PATH ourselves so Homebrew-installed tools
    // (like `claude` at /opt/homebrew/bin) are findable.
    let homebrewPaths = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]
    let inheritedPath = parentEnv["PATH"] ?? ""
    let inheritedParts = inheritedPath.split(separator: ":").map(String.init)
    let composedPath = (homebrewPaths.filter { !inheritedParts.contains($0) } + inheritedParts)
      .joined(separator: ":")

    var envDict: [String: String] = [
      "TERM": "xterm-256color",
      "COLORTERM": "truecolor",
      "LANG": parentEnv["LANG"] ?? "en_US.UTF-8",
      "PATH": composedPath,
      "SHELL": shell,
      "HOME": parentEnv["HOME"] ?? NSHomeDirectory(),
      "USER": parentEnv["USER"] ?? NSUserName(),
      "LOGNAME": parentEnv["LOGNAME"] ?? NSUserName(),
    ]
    // Pass through a few more useful vars if the parent has them, but
    // skip anything DYLD_*, __CF*, XPC_*, or similarly system-internal.
    for key in ["LC_ALL", "LC_CTYPE", "TMPDIR", "TZ", "DISPLAY"] {
      if let v = parentEnv[key] { envDict[key] = v }
    }
    let env: [String] = envDict.map { "\($0.key)=\($0.value)" }

    // Resolve the `claude` command to an absolute path so we don't depend
    // on the spawned login shell re-sourcing PATH correctly.
    let claudeBin = SessionManager.resolveClaudePath(augmentedPath: composedPath)
    let model = ModelPreference.current
    let claudeCmd =
      model == .default ? claudeBin : "\(claudeBin) --model \(model.rawValue)"

    if let cmd = command {
      tv.startProcess(
        executable: shell,
        args: ["-l", "-c", cmd],
        environment: env,
        execName: nil)
    } else {
      tv.startProcess(
        executable: shell,
        args: ["--login"],
        environment: env,
        execName: nil)
    }

    // cd into worktree directory then launch claude
    if let wtPath = worktreePath {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        tv.send(txt: "cd \(wtPath) && clear && \(claudeCmd)\r")
      }
    } else {
      // No worktree — just launch claude
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        tv.send(txt: "clear && \(claudeCmd)\r")
      }
    }

    // Start JSONL watcher for cost/token tracking.
    let watchDir = worktreePath ?? projectDir ?? FileManager.default.currentDirectoryPath
    session.startJSONLWatcher(directory: watchDir)

    sessions.append(session)
    activeSessionIndex = sessions.count - 1

    NotificationCenter.default.post(name: .sessionsDidChange, object: nil)
    NotificationCenter.default.post(name: .activeSessionDidChange, object: nil)

    return session
  }

  /// Switch to session at index.
  func switchTo(index: Int) {
    guard index >= 0, index < sessions.count else { return }
    activeSessionIndex = index
    NotificationCenter.default.post(name: .activeSessionDidChange, object: nil)
  }

  /// Close session at index.
  func closeSession(at index: Int) {
    guard index >= 0, index < sessions.count else { return }
    sessions[index].jsonlWatcher?.stop()
    sessions.remove(at: index)

    if sessions.isEmpty {
      activeSessionIndex = -1
    } else if activeSessionIndex >= sessions.count {
      activeSessionIndex = sessions.count - 1
    }

    NotificationCenter.default.post(name: .sessionsDidChange, object: nil)
    NotificationCenter.default.post(name: .activeSessionDidChange, object: nil)
  }

  /// Close session by ID.
  func closeSession(id: UUID) {
    if let idx = sessions.firstIndex(where: { $0.id == id }) {
      closeSession(at: idx)
    }
  }

  /// Restart session by ID — closes and re-creates.
  func restartSession(id: UUID) {
    guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
    let old = sessions[idx]
    closeSession(at: idx)
    createSession(name: old.name, worktreePath: old.worktreePath)
  }

  /// Get the current git branch for the active session's directory.
  func currentBranch() -> String {
    let dir = activeSession?.worktreePath ?? FileManager.default.currentDirectoryPath
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    proc.arguments = ["-C", dir, "rev-parse", "--abbrev-ref", "HEAD"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    do {
      try proc.run()
      proc.waitUntilExit()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        ?? "main"
    } catch {
      return "main"
    }
  }
}
