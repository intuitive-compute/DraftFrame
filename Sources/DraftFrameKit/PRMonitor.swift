import AppKit
import Foundation

// MARK: - Model

enum PRState: String {
  case open = "OPEN"
  case merged = "MERGED"
  case closed = "CLOSED"
}

enum PRConclusion: String {
  case success = "SUCCESS"
  case failure = "FAILURE"
  case cancelled = "CANCELLED"
  case skipped = "SKIPPED"
  case neutral = "NEUTRAL"
  case timedOut = "TIMED_OUT"

  /// Conclusions that count as a verdict against the code. `.cancelled` is
  /// deliberately absent: a cancelled run (typically superseded by a
  /// `concurrency` group) says nothing about whether the code is good.
  static let failing: Set<PRConclusion> = [.failure, .timedOut]
}

struct PRCheck: Equatable {
  let name: String
  let status: String
  let conclusion: PRConclusion?
}

/// Summary of a PR's check suite — a single status we can render as a pill.
enum PRRollup: String {
  case passing
  case failing
  case pending
  case none

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

/// Human review outcome for a PR. Only the two outcomes worth surfacing are
/// modelled; "no reviews", "review required", and comment-only reviews are
/// all `nil` on `PRStatus.review`.
enum PRReview: String {
  case approved
  case changesRequested

  var color: NSColor {
    switch self {
    case .approved: return Theme.green
    case .changesRequested: return Theme.red
    }
  }

  /// Distinct per state so the two never rely on red versus green alone.
  var glyph: String {
    switch self {
    case .approved: return "\u{2713}"
    case .changesRequested: return "\u{2717}"
    }
  }

  var label: String {
    switch self {
    case .approved: return "approved"
    case .changesRequested: return "changes requested"
    }
  }

  /// Glyph plus label, e.g. "✓ approved".
  var displayText: String { "\(glyph) \(label)" }

  var tooltip: String {
    switch self {
    case .approved: return "Approved by a reviewer"
    case .changesRequested: return "A reviewer requested changes"
    }
  }
}

struct PRStatus {
  let number: Int
  let state: PRState
  let url: String
  let checks: [PRCheck]
  let rollup: PRRollup
  /// True when GitHub has an auto-merge request armed for the PR (the
  /// "Queued to merge..." banner). Reported via `autoMergeRequest`.
  var autoMergeQueued: Bool = false
  /// Review outcome, or nil when there is nothing to show (no decisive
  /// review, or the PR is merged/closed). Independent of `rollup`.
  var review: PRReview? = nil
  /// The PR's head commit SHA. Auto-fix keys on it so a rerun that fails
  /// again on the same commit is not treated as a new failure.
  var headCommit: String? = nil

  var passingCount: Int {
    checks.filter { $0.conclusion == .success }.count
  }

  /// Display text for the PR pill / header.
  var displayText: String {
    switch state {
    case .merged: return "PR#\(number) merged"
    case .closed: return "PR#\(number) closed"
    case .open:
      if autoMergeQueued && rollup != .failing { return "PR#\(number) queued to merge" }
      if checks.isEmpty { return "PR#\(number) no checks" }
      return "PR#\(number) \(rollup.label)"
    }
  }

  /// Display color for the PR pill / header.
  var displayColor: NSColor {
    switch state {
    case .merged: return Theme.accent
    case .closed: return Theme.text3
    case .open:
      if autoMergeQueued && rollup != .failing { return Theme.accent }
      return rollup.color
    }
  }

  /// Value-equality ignoring transient fields like timestamps. Used to
  /// suppress redundant `.prStatusDidChange` notifications.
  func contentEquals(_ other: PRStatus) -> Bool {
    number == other.number && state == other.state
      && checks == other.checks && rollup == other.rollup
      && autoMergeQueued == other.autoMergeQueued
      && review == other.review
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
///
/// Main-actor isolated: all mutable state (status, timers, config) lives on
/// the main actor. The blocking `gh` spawns are `nonisolated` and run on the
/// private queue, handing results back via explicit main-queue hops.
@MainActor
final class PRMonitor {
  static let shared = PRMonitor()

  private static let configDir = NSHomeDirectory() + "/.config/draftframe"
  private static let configPath = configDir + "/pr-monitor.json"
  private static let autoFixFiredPath = configDir + "/pr-autofix.json"

  /// Live status per session, updated on each poll.
  private var statusBySession: [UUID: PRStatus] = [:]

  /// Head commit auto-fix last sent a prompt for, keyed by worktree path.
  /// Persisted, so relaunching the app does not prompt again for a commit
  /// that already had its prompt.
  private var autoFixFiredCommit: [String: String] = [:]

  /// Sessions with an auto-fix prompt waiting for the session to be ready.
  /// At most one per session; sent on the next transition to `.userInput`
  /// if the checks are still failing by then.
  private var autoFixPending: Set<UUID> = []

  /// Sessions whose auto-fix prompt has been written and is being confirmed.
  private var autoFixSubmitting: Set<UUID> = []

  /// Tracks sessions where auto-merge has already been requested.
  /// Cleared if the PR's check rollup drops back out of `passing`.
  private var mergedAttempted: Set<UUID> = []

  /// Config keyed by worktree path (survives session lifecycle).
  private var configByWorktree: [String: PRMonitorConfig] = [:]

  /// One poll timer per session.
  private var timers: [UUID: DispatchSourceTimer] = [:]

  /// Path each timer's event handler captured at start, so a session whose
  /// worktree moved (rename) gets its timer restarted on the new path.
  private var timerPaths: [UUID: String] = [:]

  private let queue = DispatchQueue(label: "com.draftframe.pr-monitor", qos: .utility)

  /// How often to hit `gh pr view` per session.
  private static let pollInterval: TimeInterval = 30

  /// Cached PATH with Homebrew dirs prepended, computed once.
  nonisolated private static let composedPATH: String = {
    let homebrewPaths = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]
    let inherited = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let parts = inherited.split(separator: ":").map(String.init)
    return (homebrewPaths.filter { !parts.contains($0) } + parts).joined(separator: ":")
  }()

  private init() {
    loadConfig()
    loadAutoFixFired()
    // Timers track session membership and worktree paths, both of which
    // only move on list changes — state/usage ticks are irrelevant here.
    NotificationCenter.default.addObserver(
      self, selector: #selector(sessionsChanged),
      name: .sessionListDidChange, object: nil
    )
    NotificationCenter.default.addObserver(
      self, selector: #selector(sessionStateChanged(_:)),
      name: .sessionStateDidChange, object: nil
    )
  }

  // No deinit: the shared singleton never deallocates, so observer removal
  // and timer cancellation there would be dead code.

  // MARK: - Public

  func status(for sessionID: UUID) -> PRStatus? {
    statusBySession[sessionID]
  }

  /// True while an auto-fix prompt is waiting for the session to be ready.
  func hasPendingAutoFix(sessionID: UUID) -> Bool {
    autoFixPending.contains(sessionID)
  }

  /// Explicit per-worktree config if the user has toggled anything for this
  /// path, otherwise the app-wide defaults from Settings.
  func config(for worktreePath: String?) -> PRMonitorConfig {
    guard let path = worktreePath else { return AppSettings.defaultPRConfig }
    return configByWorktree[path] ?? AppSettings.defaultPRConfig
  }

  func setConfig(_ config: PRMonitorConfig, for worktreePath: String) {
    configByWorktree[worktreePath] = config
    saveConfig()
    NotificationCenter.default.post(name: .prStatusDidChange, object: nil)
    // Turning auto-fix off cancels a waiting prompt right away rather than
    // at the next poll. Turning it on waits for that poll: the cached status
    // can be up to a poll interval old, too stale to send a prompt on.
    guard !config.autoFix else { return }
    for session in SessionManager.shared.sessions
    where Self.effectivePath(for: session) == worktreePath {
      evaluateAutoFix(
        sessionID: session.id, worktreePath: worktreePath,
        previousRollup: statusBySession[session.id]?.rollup)
    }
  }

  /// Force an immediate poll for a session. Used after the user toggles a
  /// config option so the UI reflects current state without waiting 30s.
  func refreshNow(sessionID: UUID) {
    guard let session = SessionManager.shared.sessions.first(where: { $0.id == sessionID }),
      let path = Self.effectivePath(for: session)
    else { return }
    queue.async { [weak self] in
      self?.poll(sessionID: sessionID, worktreePath: path)
    }
  }

  /// Resolve the directory we should run `gh` from for this session:
  /// its explicit worktree path, or the current project directory as a
  /// fallback. Returns nil if neither is set.
  static func effectivePath(for session: Session) -> String? {
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
      guard let path = Self.effectivePath(for: session) else { continue }
      // The timer's event handler captured its path at start; if the
      // session's worktree has since moved (rename), restart on the new one.
      if timers[session.id] != nil, timerPaths[session.id] != path {
        timers[session.id]?.cancel()
        timers.removeValue(forKey: session.id)
      }
      guard timers[session.id] == nil else { continue }
      startTimer(sessionID: session.id, worktreePath: path)
    }

    // Stop timers for removed sessions.
    for id in timers.keys where !currentIDs.contains(id) {
      timers[id]?.cancel()
      timers.removeValue(forKey: id)
      timerPaths.removeValue(forKey: id)
      statusBySession.removeValue(forKey: id)
      autoFixPending.remove(id)
      autoFixSubmitting.remove(id)
      mergedAttempted.remove(id)
    }
  }

  /// A session with a waiting auto-fix prompt reached its input prompt.
  /// Poll first instead of sending on the cached status: the turn that just
  /// ended may well have pushed a fix.
  @objc private func sessionStateChanged(_ note: Notification) {
    guard let change = SessionEvents.stateChange(note), change.new == .userInput,
      autoFixPending.contains(change.id)
    else { return }
    refreshNow(sessionID: change.id)
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
    timerPaths[sessionID] = worktreePath
  }

  // MARK: - Polling (runs on `queue`)

  nonisolated private func poll(sessionID: UUID, worktreePath: String) {
    guard FileManager.default.fileExists(atPath: worktreePath) else {
      NSLog("[PRMonitor] poll skipped: path does not exist: %@", worktreePath)
      return
    }

    let output = Self.runGH(
      args: ["pr", "view", "--json", Self.prViewFields],
      cwd: worktreePath
    )
    guard let data = output.data(using: .utf8),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let number = obj["number"] as? Int,
      let stateStr = obj["state"] as? String,
      let state = PRState(rawValue: stateStr),
      let url = obj["url"] as? String
    else {
      let preview = output.trimmingCharacters(in: .whitespacesAndNewlines)
        .prefix(200)
      NSLog(
        "[PRMonitor] no PR for %@ (gh output: %@)",
        worktreePath, preview.isEmpty ? "<empty>" : String(preview))
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated {
          self?.clearStatus(sessionID: sessionID)
        }
      }
      return
    }

    let rollupArr = obj["statusCheckRollup"] as? [[String: Any]] ?? []
    let checks = Self.parseChecks(rollupArr)
    let rollup = Self.computeRollup(checks: checks)
    // `autoMergeRequest` is a JSON object when auto-merge is armed and
    // `null` otherwise (which JSONSerialization surfaces as NSNull).
    let autoMergeQueued = obj["autoMergeRequest"] is [String: Any]
    let review = Self.deriveReview(
      state: state,
      reviewDecision: obj["reviewDecision"] as? String,
      latestReviews: obj["latestReviews"] as? [[String: Any]] ?? []
    )
    let status = PRStatus(
      number: number, state: state, url: url,
      checks: checks, rollup: rollup,
      autoMergeQueued: autoMergeQueued,
      review: review,
      headCommit: obj["headRefOid"] as? String
    )

    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        self?.updateStatus(sessionID: sessionID, worktreePath: worktreePath, newStatus: status)
      }
    }
  }

  /// Fields requested from `gh pr view --json`.
  nonisolated static let prViewFields =
    "number,state,url,statusCheckRollup,autoMergeRequest,reviewDecision,latestReviews,headRefOid"

  /// Derives the review outcome to show for a PR, or nil for "show nothing".
  ///
  /// `reviewDecision` is GitHub's own verdict and wins whenever it is set:
  /// `REVIEW_REQUIRED` means the required approval is still outstanding, so
  /// it yields nil even if some reviewer has approved. GitHub leaves the
  /// field empty on some repositories without a required-review rule; only
  /// then do we fall back to `latestReviews` (one entry per reviewer), where
  /// any change request outranks any approval and `COMMENTED`, `DISMISSED`,
  /// and `PENDING` entries are ignored.
  nonisolated static func deriveReview(
    state: PRState, reviewDecision: String?, latestReviews: [[String: Any]]
  ) -> PRReview? {
    guard state == .open else { return nil }
    switch reviewDecision?.uppercased() ?? "" {
    case "APPROVED": return .approved
    case "CHANGES_REQUESTED": return .changesRequested
    case "": break
    default: return nil
    }
    let states = Set(latestReviews.compactMap { ($0["state"] as? String)?.uppercased() })
    if states.contains("CHANGES_REQUESTED") { return .changesRequested }
    if states.contains("APPROVED") { return .approved }
    return nil
  }

  /// Reduces a raw `statusCheckRollup` array to one entry per check.
  ///
  /// GitHub keeps every check run ever recorded against the head commit, so
  /// a workflow re-triggered by a second event (or cancelled by a
  /// `concurrency` group) leaves its superseded runs beside the current one.
  /// The checks tab only shows the latest run per check; we do the same by
  /// grouping on workflow + name and keeping the newest run. A run that has
  /// not completed yet is by definition the newest, regardless of timestamp
  /// (a QUEUED run has no `startedAt` at all). Completed runs are ordered by
  /// `startedAt` (check runs) or `createdAt` (commit statuses); later array
  /// entries win ties so that a missing timestamp still favours the newer run.
  nonisolated static func parseChecks(_ rollupArr: [[String: Any]]) -> [PRCheck] {
    struct Candidate {
      let check: PRCheck
      let completed: Bool
      let timestamp: Date

      /// True when `self` should replace `other` as the current run.
      func supersedes(_ other: Candidate) -> Bool {
        if completed != other.completed { return !completed }
        return timestamp >= other.timestamp
      }
    }
    var latest: [String: Candidate] = [:]
    var keyOrder: [String] = []
    for entry in rollupArr {
      let name = entry["name"] as? String ?? (entry["context"] as? String ?? "check")
      let status = entry["status"] as? String ?? "UNKNOWN"
      let check = PRCheck(
        name: name,
        status: status,
        conclusion: (entry["conclusion"] as? String).flatMap { PRConclusion(rawValue: $0) }
      )
      let workflow = entry["workflowName"] as? String ?? ""
      let key = "\(workflow)\u{0}\(name)"
      let stamp = (entry["startedAt"] as? String) ?? (entry["createdAt"] as? String)
      let candidate = Candidate(
        check: check,
        completed: status.uppercased() == "COMPLETED" || entry["status"] == nil,
        timestamp: stamp.flatMap(parseTimestamp) ?? .distantPast
      )
      if let existing = latest[key] {
        if candidate.supersedes(existing) { latest[key] = candidate }
      } else {
        latest[key] = candidate
        keyOrder.append(key)
      }
    }
    return keyOrder.compactMap { latest[$0]?.check }
  }

  nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()
  nonisolated(unsafe) private static let plainFormatter = ISO8601DateFormatter()

  /// Parses GitHub's ISO 8601 timestamps with or without fractional seconds.
  nonisolated static func parseTimestamp(_ s: String) -> Date? {
    fractionalFormatter.date(from: s) ?? plainFormatter.date(from: s)
  }

  nonisolated static func computeRollup(checks: [PRCheck]) -> PRRollup {
    if checks.isEmpty { return .none }
    if checks.contains(where: { c in c.conclusion.map { PRConclusion.failing.contains($0) } ?? false
    }) {
      return .failing
    }
    let pendingStates: Set<String> = ["IN_PROGRESS", "QUEUED", "PENDING"]
    if checks.contains(where: { pendingStates.contains($0.status.uppercased()) }) {
      return .pending
    }
    // A cancelled run that no rerun has replaced is not a verdict either
    // way; surface it as pending rather than passing.
    if checks.contains(where: { $0.conclusion == .cancelled }) {
      return .pending
    }
    return .passing
  }

  // MARK: - State update + actions (main queue)

  private func clearStatus(sessionID: UUID) {
    guard statusBySession[sessionID] != nil else { return }
    statusBySession.removeValue(forKey: sessionID)
    autoFixPending.remove(sessionID)
    NotificationCenter.default.post(name: .prStatusDidChange, object: nil)
  }

  private func updateStatus(sessionID: UUID, worktreePath: String, newStatus: PRStatus) {
    let previous = statusBySession[sessionID]
    let previousRollup = previous?.rollup
    let previousState = previous?.state

    statusBySession[sessionID] = newStatus

    // Only post the notification (which triggers UI rebuilds) when something
    // the user can see actually changed.
    if previous.map({ !$0.contentEquals(newStatus) }) ?? true {
      NotificationCenter.default.post(name: .prStatusDidChange, object: nil)
    }

    let config = configByWorktree[worktreePath] ?? AppSettings.defaultPRConfig

    if newStatus.rollup != .passing {
      mergedAttempted.remove(sessionID)
    }
    // GitHub already has auto-merge armed; no need to request it again.
    if newStatus.autoMergeQueued {
      mergedAttempted.insert(sessionID)
    }

    let stateChanged = previousState != newStatus.state
    let isTerminal = newStatus.state == .merged || newStatus.state == .closed
    if config.autoArchive && stateChanged && isTerminal {
      autoArchive(sessionID: sessionID, worktreePath: worktreePath, status: newStatus)
      return
    }

    // Before the open-PR guard so a waiting prompt is dropped when the PR
    // is merged or closed.
    evaluateAutoFix(
      sessionID: sessionID, worktreePath: worktreePath, previousRollup: previousRollup)

    guard newStatus.state == .open else { return }

    // Auto-merge: rollup is passing and we haven't already requested merge.
    if config.autoMerge && newStatus.rollup == .passing
      && !mergedAttempted.contains(sessionID)
    {
      mergedAttempted.insert(sessionID)
      fireAutoMerge(sessionID: sessionID, worktreePath: worktreePath, status: newStatus)
    }
  }

  // MARK: - Auto-fix

  /// Run the auto-fix rules for a session against its latest status and act
  /// on the result. Called after every poll and when the config changes.
  private func evaluateAutoFix(sessionID: UUID, worktreePath: String, previousRollup: PRRollup?) {
    guard let session = SessionManager.shared.sessions.first(where: { $0.id == sessionID }),
      let status = statusBySession[sessionID]
    else {
      autoFixPending.remove(sessionID)
      return
    }
    let config = configByWorktree[worktreePath] ?? AppSettings.defaultPRConfig
    let decision = AutoFixPolicy.decide(
      AutoFixInput(
        enabled: config.autoFix,
        prOpen: status.state == .open,
        previousRollup: previousRollup,
        rollup: status.rollup,
        headCommit: status.headCommit,
        lastFiredCommit: autoFixFiredCommit[worktreePath],
        hasPending: autoFixPending.contains(sessionID),
        // A prompt still being confirmed counts as busy, so a second one
        // is never typed in behind it.
        readiness: autoFixSubmitting.contains(sessionID) ? .busy : session.promptReadiness
      ))

    switch decision {
    case .none:
      break
    case .cancel:
      autoFixPending.remove(sessionID)
      NSLog("[PRMonitor] auto-fix: dropped waiting prompt for %@", session.name)
    case .queue(let reason):
      autoFixPending.insert(sessionID)
      NotificationManager.shared.sendWatchdogNotification(
        title: "PR #\(status.number) checks failing",
        body: Self.autoFixWaitingMessage(reason, sessionName: session.name)
      )
    case .send:
      autoFixPending.remove(sessionID)
      sendAutoFix(session: session, worktreePath: worktreePath, status: status)
    }
  }

  nonisolated static func autoFixWaitingMessage(
    _ reason: PromptReadiness, sessionName: String
  ) -> String {
    switch reason {
    case .draftInInput:
      return "Auto-fix is waiting on \(sessionName): its input box has unsent text"
    case .notRunning:
      return "Auto-fix is waiting on \(sessionName): the agent is not at its prompt yet"
    case .busy, .ready:
      return "Auto-fix will start when \(sessionName) is next waiting for input"
    }
  }

  nonisolated static func autoFixPrompt(for status: PRStatus) -> String {
    let failed =
      status.checks
      .filter { $0.conclusion.map { PRConclusion.failing.contains($0) } ?? false }
      .map { $0.name }
    let list = failed.isEmpty ? "the CI checks" : failed.joined(separator: ", ")
    return "CI is failing on PR #\(status.number) (\(list)). "
      + "Please investigate via `gh pr checks \(status.number)` "
      + "(or `gh run view --log-failed`) and fix the issue."
  }

  private func sendAutoFix(session: Session, worktreePath: String, status: PRStatus) {
    // Recorded on the attempt, not on success: a prompt that could not be
    // sent must not be retyped on every poll.
    if let head = status.headCommit {
      autoFixFiredCommit[worktreePath] = head
      saveAutoFixFired()
    }
    let title = "PR #\(status.number) checks failing"
    let name = session.name
    guard let tv = session.terminalView else {
      NotificationManager.shared.sendWatchdogNotification(
        title: title, body: "Auto-fix could not be sent: \(name) has no terminal")
      return
    }
    let sessionID = session.id
    autoFixSubmitting.insert(sessionID)
    PromptSubmitter.submit(
      Self.autoFixPrompt(for: status), sessionID: sessionID,
      write: { [weak tv] in tv?.send(txt: $0) },
      completion: { [weak self, weak session] outcome in
        self?.autoFixSubmitting.remove(sessionID)
        switch outcome {
        case .started:
          NotificationManager.shared.sendWatchdogNotification(
            title: title, body: "Auto-fix started on \(name)")
        case .notStarted:
          // The prompt is presumably still in the input box; treat it like a
          // user draft so nothing else is typed in after it.
          session?.hasUnsentDraft = true
          NotificationManager.shared.sendWatchdogNotification(
            title: title,
            body: "Auto-fix could not be sent: \(name) did not start a turn. "
              + "The prompt may still be in its input box")
        }
      })
  }

  private func fireAutoMerge(sessionID: UUID, worktreePath: String, status: PRStatus) {
    queue.async { [weak self] in
      guard let self = self else { return }
      let output = Self.runGH(
        args: ["pr", "merge", "--squash", "--auto"],
        cwd: worktreePath
      )
      NSLog("[PRMonitor] auto-merge output: %@", output)
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          let session = SessionManager.shared.sessions.first(where: { $0.id == sessionID })
          NotificationManager.shared.sendWatchdogNotification(
            title: "PR #\(status.number) auto-merge requested",
            body: "Merge queued on \(session?.name ?? "session")"
          )
        }
      }
    }
  }

  private func autoArchive(sessionID: UUID, worktreePath: String, status: PRStatus) {
    guard let session = SessionManager.shared.sessions.first(where: { $0.id == sessionID })
    else { return }

    let verb = status.state == .merged ? "merged" : "closed"

    // Only attempt worktree removal for actual draftframe-managed worktrees
    // (those living under .claude/worktrees/). Sessions opened directly
    // on the project dir should just be closed, not removed from git.
    let isManagedWorktree = WorktreeManager.isManagedWorktree(worktreePath)

    // Close session first — stops the JSONL watcher and removes the terminal.
    SessionManager.shared.closeSession(id: sessionID)

    if isManagedWorktree {
      // Resolve the repo root from the worktree path itself rather than
      // using the singleton, which may point at a different project.
      let repoRoot = WorktreeManager.repoRoot(at: worktreePath)
      guard let root = repoRoot else {
        NSLog("[PRMonitor] auto-archive: could not resolve repoRoot from %@", worktreePath)
        return
      }
      do {
        try WorktreeManager.shared.removeWorktree(repoRoot: root, path: worktreePath)
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
    } else {
      NotificationManager.shared.sendWatchdogNotification(
        title: "Session archived",
        body: "PR #\(status.number) \(verb) — \(session.name) closed"
      )
    }
  }

  // MARK: - gh shell out

  /// Run `gh` with `args` in `cwd` and return its stdout. Blocks until gh
  /// exits — never call from the main thread. Shared with `WorktreeSweeper`.
  nonisolated static func runGH(args: [String], cwd: String) -> String {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    proc.arguments = ["gh"] + args
    proc.currentDirectoryURL = URL(fileURLWithPath: cwd)

    var env = ProcessInfo.processInfo.environment
    env["PATH"] = composedPATH
    proc.environment = env

    let out = Pipe()
    proc.standardOutput = out
    // Discard stderr at the kernel instead of attaching an undrained Pipe —
    // a full stderr pipe buffer would block gh and deadlock the wait below.
    proc.standardError = FileHandle.nullDevice
    do {
      try proc.run()
      // Drain stdout to EOF *before* waiting. `gh pr view --json` with a
      // large statusCheckRollup can exceed the 64KB pipe buffer; waiting
      // first would deadlock (gh blocked writing, us blocked waiting).
      let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
      proc.waitUntilExit()
      return String(data: data, encoding: .utf8) ?? ""
    } catch {
      return ""
    }
  }

  // MARK: - Config persistence

  private func saveConfig() {
    // QA runs toggle these on scratch worktrees; keep them out of the user's file.
    guard !QABridge.isQAMode else { return }
    let fm = FileManager.default
    try? fm.createDirectory(atPath: Self.configDir, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(configByWorktree) {
      fm.createFile(atPath: Self.configPath, contents: data)
    }
  }

  private func saveAutoFixFired() {
    // QA runs use scratch worktrees; keep them out of the user's file.
    guard !QABridge.isQAMode else { return }
    let fm = FileManager.default
    try? fm.createDirectory(atPath: Self.configDir, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(autoFixFiredCommit) {
      fm.createFile(atPath: Self.autoFixFiredPath, contents: data)
    }
  }

  private func loadAutoFixFired() {
    guard !QABridge.isQAMode,
      let data = FileManager.default.contents(atPath: Self.autoFixFiredPath),
      let loaded = try? JSONDecoder().decode([String: String].self, from: data)
    else { return }
    // Worktrees that no longer exist can never fail again; let them go.
    autoFixFiredCommit = loaded.filter { FileManager.default.fileExists(atPath: $0.key) }
  }

  private func loadConfig() {
    guard let data = FileManager.default.contents(atPath: Self.configPath),
      let loaded = try? JSONDecoder().decode([String: PRMonitorConfig].self, from: data)
    else { return }
    configByWorktree = loaded
  }
}
