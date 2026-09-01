import Foundation

/// Saves and restores the working state — open project, sessions, and their
/// Claude session ids — across app launches. Persists to
/// ~/.config/draftframe/sessions.json. State is written on quit and
/// periodically while running (so a crash loses at most one interval), and
/// restored sessions relaunch with `claude --resume` when the original
/// conversation's transcript still exists.
/// Main-actor isolated: reads and mutates SessionManager state.
@MainActor
final class SessionPersistence {
  static let shared = SessionPersistence()

  private static let configDir = NSHomeDirectory() + "/.config/draftframe"
  private static let sessionsPath = configDir + "/sessions.json"

  /// How often the running state is snapshotted to disk between the
  /// event-driven saves. Only exists to bound crash loss.
  private static let autoSaveInterval: TimeInterval = 30

  private var autoSaveTimer: Timer?

  private init() {}

  // MARK: - Data Model

  struct SavedSession: Codable {
    let name: String
    let worktreePath: String?
    /// AgentKind raw value. Optional so files written before agent support
    /// still decode; those sessions were always Claude.
    let agent: String?
    /// The agent CLI's own session id (what `claude --resume` takes).
    /// Optional: unknown until the agent writes its transcript, and absent
    /// in files written by older app versions.
    let agentSessionId: String?
  }

  struct SessionsFile: Codable {
    let projectDir: String
    let sessions: [SavedSession]
    /// Which session was selected at save time. Optional for old files.
    let activeSessionIndex: Int?
  }

  // MARK: - Save

  /// Save current sessions to disk. Called on quit and by the autosave
  /// timer/observer. An empty session list clears the file — restoring
  /// sessions the user deliberately closed would be worse than nothing.
  func saveSessions() {
    // QA runs share this file with real launches; never let their throwaway
    // sessions overwrite the user's real saved state.
    if QABridge.isQAMode { return }
    // Nothing open yet (startup, before a project is chosen) — don't touch
    // the saved state the launch flow is about to restore.
    guard let projectDir = SessionManager.shared.projectDir else { return }

    let sessions = SessionManager.shared.sessions
    guard !sessions.isEmpty else {
      clearSavedSessions()
      return
    }

    let saved = sessions.map { session in
      SavedSession(
        name: session.name, worktreePath: session.worktreePath,
        agent: session.agent.rawValue,
        agentSessionId: session.agentSessionId)
    }

    let file = SessionsFile(
      projectDir: projectDir, sessions: saved,
      activeSessionIndex: SessionManager.shared.activeSessionIndex)

    let fm = FileManager.default
    let dir = SessionPersistence.configDir
    if !fm.fileExists(atPath: dir) {
      try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    if let data = try? encoder.encode(file) {
      fm.createFile(atPath: SessionPersistence.sessionsPath, contents: data)
    }
  }

  /// Begin saving state periodically and on session-list changes, so a crash
  /// or force-quit loses at most `autoSaveInterval` of state. Idempotent;
  /// started once the initial project is open (starting earlier would let a
  /// save of the empty startup state clear the file before restore runs).
  func startAutoSave() {
    guard autoSaveTimer == nil, !QABridge.isQAMode else { return }

    NotificationCenter.default.addObserver(
      self, selector: #selector(sessionListChanged),
      name: .sessionListDidChange, object: nil)

    let timer = Timer.scheduledTimer(
      withTimeInterval: Self.autoSaveInterval, repeats: true
    ) { _ in
      // The timer fires on the main run loop; the hop makes that
      // main-actor guarantee explicit for the compiler.
      DispatchQueue.main.async {
        SessionPersistence.shared.saveSessions()
      }
    }
    timer.tolerance = 5
    autoSaveTimer = timer
  }

  @objc private func sessionListChanged() {
    saveSessions()
  }

  // MARK: - Restore

  /// The project directory the last saved state belongs to, or nil when
  /// there is no saved state. Used at launch to reopen where the user
  /// left off.
  var lastProjectDir: String? {
    loadSessionsFile()?.projectDir
  }

  /// Check if there are saved sessions for the given project directory.
  func hasSavedSessions(for projectDir: String) -> Bool {
    guard let file = loadSessionsFile() else { return false }
    return file.projectDir == projectDir && !file.sessions.isEmpty
  }

  /// Load saved sessions from disk. Returns nil if no file or wrong project.
  func loadSavedSessions(for projectDir: String) -> [SavedSession]? {
    guard let file = loadSessionsFile() else { return nil }
    guard file.projectDir == projectDir, !file.sessions.isEmpty else { return nil }
    return file.sessions
  }

  /// Restore saved sessions by creating them in SessionManager, resuming
  /// each Claude conversation whose transcript still exists. Returns whether
  /// any session was restored, so the caller can fall back to a fresh one.
  @discardableResult
  func restoreSessions(for projectDir: String) -> Bool {
    guard let file = loadSessionsFile(),
      file.projectDir == projectDir, !file.sessions.isEmpty
    else { return false }

    for entry in file.sessions {
      // Verify worktree path still exists if specified
      var wtPath = entry.worktreePath
      if let path = wtPath, !FileManager.default.fileExists(atPath: path) {
        wtPath = nil
      }

      let agent = entry.agent.flatMap(AgentKind.init(rawValue:)) ?? .claude
      let workDir = wtPath ?? projectDir

      // Resume the previous conversation only when its transcript is still
      // on disk for the directory the session will actually launch in —
      // `claude --resume` with a stale id fails outright, which would leave
      // the restored tab sitting on an error.
      var resumeId: String?
      if agent == .claude, let sid = entry.agentSessionId,
        SessionJSONLWatcher.transcriptExists(sessionId: sid, workingDirectory: workDir)
      {
        resumeId = sid
      }

      SessionManager.shared.createSession(
        name: entry.name, worktreePath: workDir, agent: agent,
        resumeSessionId: resumeId)
    }

    // Reselect the session that was active at save time.
    let count = SessionManager.shared.sessions.count
    if let idx = file.activeSessionIndex, idx >= 0, idx < count {
      SessionManager.shared.switchTo(index: idx)
    }

    // Rewrite the file from the live state (each restored session keeps its
    // resume id via `resumedFromSessionId`), so a crash right after restore
    // still finds the same workspace next launch.
    saveSessions()
    return true
  }

  /// Remove the saved sessions file.
  func clearSavedSessions() {
    try? FileManager.default.removeItem(atPath: SessionPersistence.sessionsPath)
  }

  // MARK: - Private

  private func loadSessionsFile() -> SessionsFile? {
    guard let data = FileManager.default.contents(atPath: SessionPersistence.sessionsPath) else {
      return nil
    }
    return try? JSONDecoder().decode(SessionsFile.self, from: data)
  }
}
