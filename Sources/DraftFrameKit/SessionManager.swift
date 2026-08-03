import AppKit
import SwiftTerm

/// Notification posted whenever session list or session state changes.
extension Notification.Name {
  static let sessionsDidChange = Notification.Name("DFSessionsDidChange")
  static let activeSessionDidChange = Notification.Name("DFActiveSessionDidChange")
}

/// State of an agent session, detected from its status file or terminal output.
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
    case .userInput: return Theme.cyan
    case .needsAttention: return Theme.red
    case .idle: return Theme.cyan
    }
  }

  var label: String {
    switch self {
    case .generating: return "Generating"
    case .thinking: return "Thinking"
    case .userInput: return "Idle"
    case .needsAttention: return "Attention"
    case .idle: return "Idle"
    }
  }
}

/// A single terminal session.
final class Session {
  let id: UUID
  var name: String
  /// Which agent CLI this session runs (Claude Code or Codex).
  let agent: AgentKind
  var state: SessionState
  var model: String
  /// Cost/tokens for the current claude run, matching Claude Code's `/usage`
  /// "Session" total. A tab can span many runs; these reset per run.
  var cost: Double
  var tokensIn: Int
  var tokensOut: Int
  /// Cumulative cost/tokens across every claude run in this tab. Surfaced
  /// alongside the per-run figure (e.g. in the cost label's tooltip).
  var lifetimeCost: Double = 0
  var lifetimeTokensIn: Int = 0
  var lifetimeTokensOut: Int = 0
  /// Tokens fed to the model on the most recent assistant turn.
  /// Reflects the live context window usage, not a cumulative sum.
  var contextTokens: Int
  /// Maximum context window for the model in use (200K standard, 1M for
  /// `[1m]` variants). Resolved from Claude Code's startup banner via
  /// `PTYStreamAnalyzer.onContextWindowChange`.
  var maxContextTokens: Int
  var worktreePath: String?
  var terminalView: ClaudeTerminalView?

  /// Label shown in the UI. When the session is on `main`/`master`, the bare
  /// branch name is indistinguishable across projects, so we substitute the
  /// project repo name (derived from `worktreePath`). Other branches show
  /// `name` unchanged.
  var displayName: String {
    guard name == "main" || name == "master" else { return name }
    guard let path = worktreePath else { return name }
    let subpath = WorktreeManager.worktreeSubpath + "/"
    if let range = path.range(of: subpath) {
      let projectRoot = String(path[..<range.lowerBound])
      return (projectRoot as NSString).lastPathComponent
    }
    return (path as NSString).lastPathComponent
  }

  /// Stable, unique-per-session seed for the generated avatar. Prefers the
  /// worktree path so two sessions sharing a branch name (e.g. `main` in two
  /// different projects) still get distinct marks, and so the mark survives a
  /// rename. Falls back to the name for sessions without a worktree.
  var avatarSeed: String { worktreePath ?? name }

  /// PTY stream analyzer — used for the 1M-context banner detection.
  /// State detection now comes from `SessionStatusWatcher` instead, since
  /// the per-pid status file Claude Code maintains is authoritative whereas
  /// PTY parsing was racy with the TUI redraw loop.
  let ptyAnalyzer = PTYStreamAnalyzer()

  /// Watches the agent's transcript (Claude Code project JSONL or Codex
  /// rollout JSONL) for cost/token updates.
  var usageWatcher: UsageWatcher?

  /// Watches `~/.claude/sessions/<pid>.json` for authoritative session state.
  /// Claude sessions only — Codex has no equivalent, so its state comes from
  /// the PTY stream analyzer instead.
  var statusWatcher: SessionStatusWatcher?

  /// `launchModelId` is the model the session's CLI is launched with
  /// (empty = the CLI default); it seeds the card's model label until the
  /// agent's transcript confirms or corrects it.
  init(
    name: String, worktreePath: String? = nil, agent: AgentKind = .claude,
    launchModelId: String = ""
  ) {
    self.id = UUID()
    self.name = name
    self.agent = agent
    self.state = .idle
    self.model = agent.initialCardModel(forLaunchModelId: launchModelId)
    self.cost = 0.0
    self.tokensIn = 0
    self.tokensOut = 0
    self.contextTokens = 0
    self.maxContextTokens = 200_000
    self.worktreePath = worktreePath

    ptyAnalyzer.agent = agent
    ptyAnalyzer.onContextWindowChange = { [weak self] maxTokens in
      guard let self = self else { return }
      self.maxContextTokens = maxTokens
      DispatchQueue.main.async {
        NotificationCenter.default.post(name: .sessionsDidChange, object: nil)
      }
    }
  }

  /// Start monitoring the agent's transcript (cost/tokens) and status for
  /// the given working directory.
  func startWatchers(directory: String) {
    let applyUsage: SessionJSONLWatcher.UpdateCallback = {
      [weak self]
      cost, tokensIn, tokensOut, model, contextTokens, maxContextTokens,
      lifetimeCost, lifetimeTokensIn, lifetimeTokensOut in
      guard let self = self else { return }
      self.cost = cost
      self.tokensIn = tokensIn
      self.tokensOut = tokensOut
      self.lifetimeCost = lifetimeCost
      self.lifetimeTokensIn = lifetimeTokensIn
      self.lifetimeTokensOut = lifetimeTokensOut
      // Empty means the transcript hasn't named the model yet — keep what
      // the launch preference or startup banner already put on the card.
      if !model.isEmpty {
        self.model = model
      }
      self.contextTokens = contextTokens
      // 0 means "no JSONL signal yet" — leave the value the PTY banner set.
      if maxContextTokens > 0 {
        self.maxContextTokens = maxContextTokens
      }
      NotificationCenter.default.post(name: .sessionsDidChange, object: nil)
    }

    let applyState: (SessionState) -> Void = { [weak self] newState in
      guard let self = self else { return }
      self.state = newState
      NotificationCenter.default.post(name: .sessionsDidChange, object: nil)
    }

    switch agent {
    case .claude:
      usageWatcher = SessionJSONLWatcher(workingDirectory: directory, onUpdate: applyUsage)
      statusWatcher = SessionStatusWatcher(cwd: directory, onUpdate: applyState)
    case .codex:
      // Codex writes no per-pid status file. Working/idle comes from the
      // rollout's persisted turn lifecycle events; the PTY stream covers
      // only what the rollout can't see — approval prompts (never
      // persisted), process exit, and the startup banner's model line.
      usageWatcher = CodexUsageWatcher(
        workingDirectory: directory,
        onTurnState: applyState,
        onUpdate: applyUsage)
      ptyAnalyzer.onStateChange = { [weak self] newState in
        guard let self = self else { return }
        switch newState {
        case .needsAttention, .idle:
          break
        case .generating, .thinking:
          // Only to clear an answered approval prompt — the turn events
          // own the regular working/idle transitions.
          guard self.state == .needsAttention else { return }
        case .userInput:
          return
        }
        applyState(newState)
      }
      ptyAnalyzer.onModelDetected = { [weak self] model in
        guard let self = self, self.model != model else { return }
        self.model = model
        NotificationCenter.default.post(name: .sessionsDidChange, object: nil)
      }
    }
  }

  /// Stop every watcher `startWatchers` installed. Counterpart kept next to
  /// it so the set of per-agent watchers is owned in one place.
  func stopWatchers() {
    usageWatcher?.stop()
    statusWatcher?.stop()
    ptyAnalyzer.onStateChange = nil
    ptyAnalyzer.onModelDetected = nil
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

  /// Cumulative cost across every session's full run history this app
  /// session, summing each session's lifetime figure.
  var lifetimeTotalCost: Double {
    sessions.reduce(0) { $0 + $1.lifetimeCost }
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

  /// Resolved binary path per agent. Install locations don't move during an
  /// app run, and a cache miss can cost a synchronous login-shell spawn on
  /// the main thread — restoring N sessions would otherwise pay it N times.
  private static var resolvedAgentPaths: [AgentKind: String] = [:]

  /// Find an absolute path to the agent's CLI binary. Falls back to the bare
  /// binary name so the shell's own PATH lookup is used as a last resort.
  static func resolveAgentPath(agent: AgentKind, augmentedPath: String) -> String {
    if let cached = resolvedAgentPaths[agent] { return cached }
    let resolved = uncachedResolveAgentPath(agent: agent, augmentedPath: augmentedPath)
    resolvedAgentPaths[agent] = resolved
    return resolved
  }

  private static func uncachedResolveAgentPath(agent: AgentKind, augmentedPath: String) -> String {
    let fm = FileManager.default
    let binary = agent.binaryName

    // 1) Search the caller-provided PATH first.
    for dir in augmentedPath.split(separator: ":").map(String.init) {
      let candidate = (dir as NSString).appendingPathComponent(binary)
      if fm.isExecutableFile(atPath: candidate) { return candidate }
    }

    // 2) Check common install locations the GUI-launched app PATH misses.
    for candidate in agent.fallbackBinaryPaths where fm.isExecutableFile(atPath: candidate) {
      return candidate
    }

    // 3) Ask an interactive login shell to resolve it. This picks up any
    // PATH the user configures in .zprofile/.zshrc even if we don't know
    // about the install location.
    if let resolved = runLoginShellCommand("command -v \(binary)"),
      !resolved.isEmpty,
      fm.isExecutableFile(atPath: resolved)
    {
      return resolved
    }

    // 4) Give up and let the shell try its own PATH.
    return binary
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

  /// Create a new session and return it. `agent` defaults to the persisted
  /// agent preference; pass one explicitly to restore or restart a session
  /// with the agent it originally launched with. `initialPrompt` is handed
  /// to the agent CLI as a positional argument so the session starts working
  /// on it immediately (used for ticket-linked worktrees).
  @discardableResult
  func createSession(
    name: String? = nil, command: String? = nil, worktreePath: String? = nil,
    agent: AgentKind? = nil, initialPrompt: String? = nil
  )
    -> Session
  {
    let agent = agent ?? AgentPreference.current
    // Read the model preference once so the card label and the launched CLI
    // can't disagree.
    let modelId = agent.preferredModelId
    let sessionName = name ?? "session-\(sessions.count + 1)"
    let session = Session(
      name: sessionName, worktreePath: worktreePath, agent: agent, launchModelId: modelId)

    // Create the terminal view (ClaudeTerminalView intercepts PTY data).
    // Use a zero frame — autolayout will resize to the real visible area
    // once the view is parented in `terminalContainer`. Forking the child
    // process before that resize would bake a stale `cols`/`rows` into the
    // PTY's initial winsize, which makes Claude Code's TUI wrap and
    // cursor-position at a column count that doesn't match what's drawn.
    let tv = ClaudeTerminalView(frame: .zero)
    tv.nativeForegroundColor = Theme.text1
    tv.nativeBackgroundColor = Theme.bg
    tv.selectedTextBackgroundColor = Theme.selected
    tv.caretColor = Theme.accent
    tv.font = Theme.terminalMono(13)
    session.terminalView = tv

    // Wire PTY data stream to the analyzer for real-time state detection
    tv.onPtyData = { [weak session] bytes in
      session?.ptyAnalyzer.feed(bytes)
    }

    // Build the child env up front so we only start the process once the
    // view has settled into its final on-screen size below.
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

    // Resolve the agent command to an absolute path so we don't depend
    // on the spawned login shell re-sourcing PATH correctly.
    let agentBin = SessionManager.resolveAgentPath(agent: agent, augmentedPath: composedPath)
    let agentCmd = agent.launchCommand(
      binPath: agentBin, modelId: modelId, initialPrompt: initialPrompt)

    // Start transcript/status watchers for cost/token/state tracking.
    let watchDir = worktreePath ?? projectDir ?? FileManager.default.currentDirectoryPath
    session.startWatchers(directory: watchDir)

    // Register and broadcast the session first. The notification synchronously
    // drives DFTerminalPane to parent `tv` in its terminal container with the
    // real layout constraints; forcing layout immediately after gives the view
    // its final frame before we fork the child process.
    sessions.append(session)
    activeSessionIndex = sessions.count - 1

    NotificationCenter.default.post(name: .sessionsDidChange, object: nil)
    NotificationCenter.default.post(name: .activeSessionDidChange, object: nil)

    tv.window?.layoutIfNeeded()
    tv.superview?.layoutSubtreeIfNeeded()

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

    // The PTY's initial winsize now matches the visible area, so the shell
    // (and the agent once it launches) wrap at the same column count we
    // render. The kernel buffers the bytes until the shell calls read(), so
    // we don't need a delay before sending.
    if let wtPath = worktreePath {
      tv.send(txt: "cd \(shellSingleQuote(wtPath)) && clear && \(agentCmd)\r")
    } else {
      tv.send(txt: "clear && \(agentCmd)\r")
    }

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
    sessions[index].stopWatchers()
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

  /// Move the session at `from` to `to`. Preserves which session is active.
  func moveSession(from: Int, to: Int) {
    guard from >= 0, from < sessions.count else { return }
    guard to >= 0, to <= sessions.count, to != from else { return }

    let activeID = activeSession?.id
    let priorActiveIndex = activeSessionIndex
    let moved = sessions.remove(at: from)
    // After removal, an insertion index past `from` shifts down by one.
    let insertAt = to > from ? to - 1 : to
    sessions.insert(moved, at: insertAt)

    if let id = activeID, let newIdx = sessions.firstIndex(where: { $0.id == id }) {
      activeSessionIndex = newIdx
    }

    NotificationCenter.default.post(name: .sessionsDidChange, object: nil)
    if activeSessionIndex != priorActiveIndex {
      NotificationCenter.default.post(name: .activeSessionDidChange, object: nil)
    }
  }

  /// Restart session by ID — closes and re-creates with the same agent.
  func restartSession(id: UUID) {
    guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
    let old = sessions[idx]
    closeSession(at: idx)
    createSession(name: old.name, worktreePath: old.worktreePath, agent: old.agent)
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
