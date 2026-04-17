import AppKit
import Foundation

// MARK: - Model

struct PRCheck: Equatable {
  let name: String
  /// GitHub status: "COMPLETED", "IN_PROGRESS", "QUEUED", "PENDING".
  let status: String
  /// GitHub conclusion (only set when status == COMPLETED): "SUCCESS",
  /// "FAILURE", "CANCELLED", "SKIPPED", "NEUTRAL", "TIMED_OUT".
  let conclusion: String?
}

/// Summary of a PR's check suite — a single status we can render as a pill.
enum PRRollup: String {
  case passing
  case failing
  case pending
  case none  // no checks configured

  var color: NSColor {
    switch self {
    case .passing: return Theme.green
    case .failing: return Theme.red
    case .pending: return Theme.yellow
    case .none: return Theme.text3
    }
  }

  var label: String {
    switch self {
    case .passing: return "passing"
    case .failing: return "failing"
    case .pending: return "pending"
    case .none: return "no checks"
    }
  }
}

struct PRStatus: Equatable {
  let number: Int
  /// "OPEN", "MERGED", "CLOSED".
  let state: String
  let url: String
  let checks: [PRCheck]
  let rollup: PRRollup
  let lastUpdated: Date

  var passingCount: Int {
    checks.filter { $0.conclusion?.uppercased() == "SUCCESS" }.count
  }
}

/// Per-worktree user preferences for automated PR actions.
struct PRMonitorConfig: Codable, Equatable {
  var autoFix: Bool = false
  var autoMerge: Bool = false
  var autoArchive: Bool = false
}

extension Notification.Name {
  static let prStatusDidChange = Notification.Name("DFPRStatusDidChange")
}

// MARK: - PRMonitor

/// Singleton that polls `gh pr view` for each session with a worktree,
/// surfaces CI status, and fires auto-fix / auto-merge / auto-archive
/// actions when configured.
final class PRMonitor {
  static let shared = PRMonitor()

  private static let configDir = NSHomeDirectory() + "/.config/draftframe"
  private static let configPath = configDir + "/pr-monitor.json"

  /// Live status per session, updated on each poll.
  private var statusBySession: [UUID: PRStatus] = [:]

  /// Throttle for auto-fix so we don't spam Claude on flapping checks.
  private var lastFailureFiredAt: [UUID: Date] = [:]

  /// Tracks sessions where auto-merge has already been requested.
  /// Cleared if the PR's check rollup drops back out of `passing`.
  private var mergedAttempted: Set<UUID> = []

  /// Config keyed by worktree path (survives session lifecycle).
  private var configByWorktree: [String: PRMonitorConfig] = [:]

  /// One poll timer per session.
  private var timers: [UUID: DispatchSourceTimer] = [:]

  private let queue = DispatchQueue(label: "com.draftframe.pr-monitor", qos: .utility)

  /// How often to hit `gh pr view` per session.
  private static let pollInterval: TimeInterval = 30

  private init() {
    loadConfig()
    NotificationCenter.default.addObserver(
      self, selector: #selector(sessionsChanged),
      name: .sessionsDidChange, object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    for timer in timers.values { timer.cancel() }
  }

  // MARK: - Public

  func status(for sessionID: UUID) -> PRStatus? {
    statusBySession[sessionID]
  }

  func config(for worktreePath: String?) -> PRMonitorConfig {
    guard let path = worktreePath else { return PRMonitorConfig() }
    return configByWorktree[path] ?? PRMonitorConfig()
  }

  func setConfig(_ config: PRMonitorConfig, for worktreePath: String) {
    configByWorktree[worktreePath] = config
    saveConfig()
    NotificationCenter.default.post(name: .prStatusDidChange, object: nil)
  }

  /// Force an immediate poll for a session. Used after the user toggles a
  /// config option so the UI reflects current state without waiting 30s.
  func refreshNow(sessionID: UUID) {
    guard let session = SessionManager.shared.sessions.first(where: { $0.id == sessionID }),
      let path = effectivePath(for: session)
    else { return }
    queue.async { [weak self] in
      self?.poll(sessionID: sessionID, worktreePath: path)
    }
  }

  /// Resolve the directory we should run `gh` from for this session:
  /// its explicit worktree path, or the current project directory as a
  /// fallback. Returns nil if neither is set.
  private func effectivePath(for session: Session) -> String? {
    if let path = session.worktreePath { return path }
    return SessionManager.shared.projectDir
  }

  // MARK: - Session observation

  @objc private func sessionsChanged() {
    let sessions = SessionManager.shared.sessions
    let currentIDs = Set(sessions.map { $0.id })

    // Start timers for new sessions. We poll anywhere gh can resolve a PR:
    // the session's explicit worktree (if set) or the project directory,
    // since the child shell inherits that cwd at launch. Sessions created
    // with neither (shouldn't happen in practice) are skipped.
    for session in sessions {
      guard timers[session.id] == nil else { continue }
      guard let path = effectivePath(for: session) else { continue }
      startTimer(sessionID: session.id, worktreePath: path)
    }

    // Stop timers for removed sessions.
    for id in timers.keys where !currentIDs.contains(id) {
      timers[id]?.cancel()
      timers.removeValue(forKey: id)
      statusBySession.removeValue(forKey: id)
      lastFailureFiredAt.removeValue(forKey: id)
      mergedAttempted.remove(id)
    }
  }

  // MARK: - Timer

  private func startTimer(sessionID: UUID, worktreePath: String) {
    NSLog("[PRMonitor] starting timer for %@ (session %@)", worktreePath, sessionID.uuidString)
    let timer = DispatchSource.makeTimerSource(queue: queue)
    // Small initial delay so we don't all-fire at launch.
    timer.schedule(deadline: .now() + 3, repeating: Self.pollInterval)
    timer.setEventHandler { [weak self] in
      self?.poll(sessionID: sessionID, worktreePath: worktreePath)
    }
    timer.resume()
    timers[sessionID] = timer
  }

  // MARK: - Polling (runs on `queue`)

  private func poll(sessionID: UUID, worktreePath: String) {
    guard FileManager.default.fileExists(atPath: worktreePath) else {
      NSLog("[PRMonitor] poll skipped: path does not exist: %@", worktreePath)
      return
    }

    let output = runGH(
      args: ["pr", "view", "--json", "number,state,url,statusCheckRollup"],
      cwd: worktreePath
    )
    guard let data = output.data(using: .utf8),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let number = obj["number"] as? Int,
      let state = obj["state"] as? String,
      let url = obj["url"] as? String
    else {
      // No PR for this branch, or gh not installed / not authed. Clear
      // any stale status so the UI drops the indicator.
      let preview = output.trimmingCharacters(in: .whitespacesAndNewlines)
        .prefix(200)
      NSLog(
        "[PRMonitor] no PR for %@ (gh output: %@)",
        worktreePath, preview.isEmpty ? "<empty>" : String(preview))
      DispatchQueue.main.async { [weak self] in
        self?.clearStatus(sessionID: sessionID)
      }
      return
    }
    NSLog(
      "[PRMonitor] %@ → PR #%d %@ (%d checks)",
      worktreePath, number, state, (obj["statusCheckRollup"] as? [[String: Any]])?.count ?? 0)

    let rollupArr = obj["statusCheckRollup"] as? [[String: Any]] ?? []
    let checks = rollupArr.map { entry -> PRCheck in
      PRCheck(
        name: entry["name"] as? String ?? (entry["context"] as? String ?? "check"),
        status: entry["status"] as? String ?? "UNKNOWN",
        conclusion: entry["conclusion"] as? String
      )
    }
    let rollup = computeRollup(checks: checks)
    let status = PRStatus(
      number: number, state: state, url: url,
      checks: checks, rollup: rollup, lastUpdated: Date()
    )

    DispatchQueue.main.async { [weak self] in
      self?.updateStatus(sessionID: sessionID, worktreePath: worktreePath, newStatus: status)
    }
  }

  private func computeRollup(checks: [PRCheck]) -> PRRollup {
    if checks.isEmpty { return .none }
    let failureConclusions: Set<String> = ["FAILURE", "CANCELLED", "TIMED_OUT"]
    if checks.contains(where: { failureConclusions.contains($0.conclusion?.uppercased() ?? "") }) {
      return .failing
    }
    let pendingStates: Set<String> = ["IN_PROGRESS", "QUEUED", "PENDING"]
    if checks.contains(where: { pendingStates.contains($0.status.uppercased()) }) {
      return .pending
    }
    return .passing
  }

  // MARK: - State update + actions (main queue)

  private func clearStatus(sessionID: UUID) {
    guard statusBySession[sessionID] != nil else { return }
    statusBySession.removeValue(forKey: sessionID)
    NotificationCenter.default.post(name: .prStatusDidChange, object: nil)
  }

  private func updateStatus(sessionID: UUID, worktreePath: String, newStatus: PRStatus) {
    let previous = statusBySession[sessionID]
    let previousRollup = previous?.rollup
    let previousState = previous?.state

    statusBySession[sessionID] = newStatus
    NotificationCenter.default.post(name: .prStatusDidChange, object: nil)

    let config = configByWorktree[worktreePath] ?? PRMonitorConfig()

    // Reset auto-merge attempt flag if the PR fell out of passing — some
    // check newly started or failed, and we might attempt again later.
    if newStatus.rollup != .passing {
      mergedAttempted.remove(sessionID)
    }

    // Auto-archive: state transitioned to a terminal state.
    let stateChanged = previousState != newStatus.state
    let isTerminal = newStatus.state == "MERGED" || newStatus.state == "CLOSED"
    if config.autoArchive && stateChanged && isTerminal {
      autoArchive(sessionID: sessionID, worktreePath: worktreePath, status: newStatus)
      return  // session is being closed; no more actions
    }

    // Only act on OPEN PRs from here on.
    guard newStatus.state == "OPEN" else { return }

    // Auto-fix: rollup transitioned into .failing.
    if config.autoFix && newStatus.rollup == .failing && previousRollup != .failing {
      let now = Date()
      let last = lastFailureFiredAt[sessionID] ?? .distantPast
      // Throttle to at most once per 10 minutes so flapping checks don't
      // spam the session.
      if now.timeIntervalSince(last) > 600 {
        fireAutoFix(sessionID: sessionID, status: newStatus)
        lastFailureFiredAt[sessionID] = now
      }
    }

    // Auto-merge: rollup is passing and we haven't already requested merge.
    if config.autoMerge && newStatus.rollup == .passing
      && !mergedAttempted.contains(sessionID)
    {
      mergedAttempted.insert(sessionID)
      fireAutoMerge(sessionID: sessionID, worktreePath: worktreePath, status: newStatus)
    }
  }

  private func fireAutoFix(sessionID: UUID, status: PRStatus) {
    guard let session = SessionManager.shared.sessions.first(where: { $0.id == sessionID })
    else { return }
    let failed =
      status.checks
      .filter {
        let c = $0.conclusion?.uppercased() ?? ""
        return c == "FAILURE" || c == "CANCELLED" || c == "TIMED_OUT"
      }
      .map { $0.name }
    let list = failed.isEmpty ? "the CI checks" : failed.joined(separator: ", ")
    let prompt =
      "CI is failing on PR #\(status.number) (\(list)). "
      + "Please investigate via `gh pr checks \(status.number)` "
      + "(or `gh run view --log-failed`) and fix the issue.\r"
    session.terminalView?.send(txt: prompt)
    NotificationManager.shared.sendWatchdogNotification(
      title: "PR #\(status.number) checks failing",
      body: "Auto-fix triggered on \(session.name)"
    )
  }

  private func fireAutoMerge(sessionID: UUID, worktreePath: String, status: PRStatus) {
    queue.async { [weak self] in
      guard let self = self else { return }
      let output = self.runGH(
        args: ["pr", "merge", "--squash", "--auto"],
        cwd: worktreePath
      )
      NSLog("[PRMonitor] auto-merge output: %@", output)
      DispatchQueue.main.async {
        let session = SessionManager.shared.sessions.first(where: { $0.id == sessionID })
        NotificationManager.shared.sendWatchdogNotification(
          title: "PR #\(status.number) auto-merge requested",
          body: "Merge queued on \(session?.name ?? "session")"
        )
      }
    }
  }

  private func autoArchive(sessionID: UUID, worktreePath: String, status: PRStatus) {
    guard let session = SessionManager.shared.sessions.first(where: { $0.id == sessionID })
    else { return }
    guard let root = WorktreeManager.shared.repoRoot else {
      NSLog("[PRMonitor] auto-archive: no repoRoot; skipping")
      return
    }

    // Close session first — stops the JSONL watcher and removes the terminal.
    SessionManager.shared.closeSession(id: sessionID)

    // Then remove the worktree. Git refuses if uncommitted changes exist;
    // we `--force` in removeWorktree, which is appropriate here since the
    // PR just merged or was closed.
    do {
      try WorktreeManager.shared.removeWorktree(repoRoot: root, path: worktreePath)
      let verb = status.state == "MERGED" ? "merged" : "closed"
      NotificationManager.shared.sendWatchdogNotification(
        title: "Session archived",
        body: "PR #\(status.number) \(verb) — \(session.name) and its worktree were removed"
      )
    } catch {
      NSLog("[PRMonitor] auto-archive removeWorktree failed: %@", error.localizedDescription)
      NotificationManager.shared.sendWatchdogNotification(
        title: "Auto-archive failed",
        body: "Couldn't remove worktree for \(session.name): \(error.localizedDescription)"
      )
    }
  }

  // MARK: - gh shell out

  private func runGH(args: [String], cwd: String) -> String {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    proc.arguments = ["gh"] + args
    proc.currentDirectoryURL = URL(fileURLWithPath: cwd)

    // Compose an env with homebrew paths so `gh` is findable regardless of
    // launch context (GUI launches often start with a stripped PATH).
    let parentEnv = ProcessInfo.processInfo.environment
    let homebrewPaths = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]
    let inheritedPath = parentEnv["PATH"] ?? ""
    let parts = inheritedPath.split(separator: ":").map(String.init)
    let composedPath = (homebrewPaths.filter { !parts.contains($0) } + parts)
      .joined(separator: ":")
    var env = parentEnv
    env["PATH"] = composedPath
    proc.environment = env

    let out = Pipe()
    proc.standardOutput = out
    proc.standardError = Pipe()
    do {
      try proc.run()
      proc.waitUntilExit()
      let data = out.fileHandleForReading.readDataToEndOfFile()
      return String(data: data, encoding: .utf8) ?? ""
    } catch {
      return ""
    }
  }

  // MARK: - Config persistence

  private func saveConfig() {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: Self.configDir, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(configByWorktree) {
      fm.createFile(atPath: Self.configPath, contents: data)
    }
  }

  private func loadConfig() {
    guard let data = FileManager.default.contents(atPath: Self.configPath),
      let loaded = try? JSONDecoder().decode([String: PRMonitorConfig].self, from: data)
    else { return }
    configByWorktree = loaded
  }
}
