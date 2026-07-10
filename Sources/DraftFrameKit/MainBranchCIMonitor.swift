import AppKit
import Foundation

// MARK: - Model

/// Snapshot of GitHub Actions on a repo's default branch: the latest run of
/// each workflow, rolled up into a single pill-able status.
struct MainBranchCIStatus {
  struct WorkflowRun: Equatable {
    let workflow: String
    let status: String  // completed, in_progress, queued, ...
    let conclusion: String  // success, failure, ... ("" until completed)
    let url: String
  }

  let branch: String
  let rollup: PRRollup
  let runs: [WorkflowRun]

  /// Display text for the CI pill, e.g. "main passing".
  var displayText: String { "\(branch) \(rollup.label)" }

  var displayColor: NSColor { rollup.color }

  /// One line per workflow for the pill tooltip.
  var tooltip: String {
    runs.map { run in
      let outcome = run.conclusion.isEmpty ? run.status : run.conclusion
      return "\(run.workflow): \(outcome)"
    }.joined(separator: "\n")
  }
}

extension Notification.Name {
  static let mainBranchCIStatusDidChange = Notification.Name("DFMainBranchCIStatusDidChange")
}

// MARK: - MainBranchCIMonitor

/// Singleton that polls `gh run list` for the default branch of every repo
/// with an open session, so session cards can show whether main is green.
/// Polling is keyed by repo root (not session): all sessions in the same
/// repo share one poll.
final class MainBranchCIMonitor {
  static let shared = MainBranchCIMonitor()

  /// Live status per repo root, updated on each poll.
  private var statusByRepoRoot: [String: MainBranchCIStatus] = [:]

  /// Default branch per repo root, resolved once from origin/HEAD.
  /// Only touched on `queue`.
  private var branchByRepoRoot: [String: String] = [:]

  /// One poll timer per repo root.
  private var timers: [String: DispatchSourceTimer] = [:]

  private let queue = DispatchQueue(label: "com.draftframe.main-ci-monitor", qos: .utility)

  /// How often to hit `gh run list` per repo.
  private static let pollInterval: TimeInterval = 60

  /// Conclusions that should color the pill red.
  private static let failingConclusions: Set<String> = [
    "failure", "cancelled", "timed_out", "startup_failure", "action_required",
  ]

  /// Statuses of a run that has not finished yet.
  private static let pendingStatuses: Set<String> = [
    "queued", "in_progress", "waiting", "requested", "pending",
  ]

  /// Cached PATH with Homebrew dirs prepended, computed once at init.
  private let composedPATH: String = {
    let homebrewPaths = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]
    let inherited = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let parts = inherited.split(separator: ":").map(String.init)
    return (homebrewPaths.filter { !parts.contains($0) } + parts).joined(separator: ":")
  }()

  private init() {
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

  func status(forRepoRoot root: String) -> MainBranchCIStatus? {
    statusByRepoRoot[root]
  }

  func status(for session: Session) -> MainBranchCIStatus? {
    guard let path = PRMonitor.effectivePath(for: session),
      let root = WorktreeManager.repoRoot(at: path)
    else { return nil }
    return statusByRepoRoot[root]
  }

  // MARK: - Session observation

  @objc private func sessionsChanged() {
    // Resolve the set of repo roots currently backing sessions.
    var roots: Set<String> = []
    for session in SessionManager.shared.sessions {
      guard let path = PRMonitor.effectivePath(for: session),
        let root = WorktreeManager.repoRoot(at: path)
      else { continue }
      roots.insert(root)
    }

    for root in roots where timers[root] == nil {
      startTimer(repoRoot: root)
    }

    for root in timers.keys where !roots.contains(root) {
      timers[root]?.cancel()
      timers.removeValue(forKey: root)
      queue.async { [weak self] in self?.branchByRepoRoot.removeValue(forKey: root) }
      if statusByRepoRoot.removeValue(forKey: root) != nil {
        NotificationCenter.default.post(name: .mainBranchCIStatusDidChange, object: nil)
      }
    }
  }

  // MARK: - Timer

  private func startTimer(repoRoot: String) {
    NSLog("[MainBranchCIMonitor] starting timer for %@", repoRoot)
    let timer = DispatchSource.makeTimerSource(queue: queue)
    // Small initial delay so we don't all-fire at launch.
    timer.schedule(deadline: .now() + 5, repeating: Self.pollInterval)
    timer.setEventHandler { [weak self] in
      self?.poll(repoRoot: repoRoot)
    }
    timer.resume()
    timers[repoRoot] = timer
  }

  // MARK: - Polling (runs on `queue`)

  private func poll(repoRoot: String) {
    guard FileManager.default.fileExists(atPath: repoRoot) else { return }

    let branch = defaultBranch(repoRoot: repoRoot)
    let output = runGH(
      args: [
        "run", "list", "--branch", branch, "--limit", "20",
        "--json", "workflowName,status,conclusion,url",
      ],
      cwd: repoRoot
    )
    guard let data = output.data(using: .utf8),
      let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else {
      // gh failed (no remote, offline, not authenticated): drop any stale
      // status so the pill disappears rather than lying.
      DispatchQueue.main.async { [weak self] in self?.clearStatus(repoRoot: repoRoot) }
      return
    }

    // `gh run list` is newest-first; keep the latest run of each workflow.
    var runs: [MainBranchCIStatus.WorkflowRun] = []
    var seenWorkflows: Set<String> = []
    for entry in arr {
      let workflow = entry["workflowName"] as? String ?? "workflow"
      guard !seenWorkflows.contains(workflow) else { continue }
      seenWorkflows.insert(workflow)
      runs.append(
        MainBranchCIStatus.WorkflowRun(
          workflow: workflow,
          status: (entry["status"] as? String ?? "").lowercased(),
          conclusion: (entry["conclusion"] as? String ?? "").lowercased(),
          url: entry["url"] as? String ?? ""
        ))
    }

    guard !runs.isEmpty else {
      // Repo has no Actions runs on the default branch: no pill.
      DispatchQueue.main.async { [weak self] in self?.clearStatus(repoRoot: repoRoot) }
      return
    }

    let status = MainBranchCIStatus(
      branch: branch, rollup: computeRollup(runs: runs), runs: runs)
    DispatchQueue.main.async { [weak self] in
      self?.updateStatus(repoRoot: repoRoot, newStatus: status)
    }
  }

  private func computeRollup(runs: [MainBranchCIStatus.WorkflowRun]) -> PRRollup {
    if runs.contains(where: { Self.failingConclusions.contains($0.conclusion) }) {
      return .failing
    }
    if runs.contains(where: { Self.pendingStatuses.contains($0.status) }) {
      return .pending
    }
    return .passing
  }

  /// Default branch from origin/HEAD, falling back to "main". Cached per
  /// repo since it effectively never changes within a session.
  private func defaultBranch(repoRoot: String) -> String {
    if let cached = branchByRepoRoot[repoRoot] { return cached }
    let output = run(
      executable: "/usr/bin/git",
      args: ["-C", repoRoot, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
      cwd: repoRoot
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    // "origin/main" -> "main"
    let branch = output.split(separator: "/").dropFirst().joined(separator: "/")
    let resolved = branch.isEmpty ? "main" : branch
    branchByRepoRoot[repoRoot] = resolved
    return resolved
  }

  // MARK: - State update (main queue)

  private func clearStatus(repoRoot: String) {
    guard statusByRepoRoot[repoRoot] != nil else { return }
    statusByRepoRoot.removeValue(forKey: repoRoot)
    NotificationCenter.default.post(name: .mainBranchCIStatusDidChange, object: nil)
  }

  private func updateStatus(repoRoot: String, newStatus: MainBranchCIStatus) {
    let previous = statusByRepoRoot[repoRoot]
    statusByRepoRoot[repoRoot] = newStatus

    // Only post the notification (which triggers card rebuilds) when
    // something the user can see actually changed.
    let changed =
      previous.map { $0.rollup != newStatus.rollup || $0.runs != newStatus.runs } ?? true
    if changed {
      NotificationCenter.default.post(name: .mainBranchCIStatusDidChange, object: nil)
    }
  }

  // MARK: - Shell out

  private func runGH(args: [String], cwd: String) -> String {
    run(executable: "/usr/bin/env", args: ["gh"] + args, cwd: cwd)
  }

  private func run(executable: String, args: [String], cwd: String) -> String {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: executable)
    proc.arguments = args
    proc.currentDirectoryURL = URL(fileURLWithPath: cwd)

    var env = ProcessInfo.processInfo.environment
    env["PATH"] = composedPATH
    proc.environment = env

    let out = Pipe()
    proc.standardOutput = out
    // Discard stderr at the kernel instead of attaching an undrained Pipe —
    // a full stderr pipe buffer would block the child and deadlock the wait.
    proc.standardError = FileHandle.nullDevice
    do {
      try proc.run()
      // Drain stdout to EOF *before* waiting so a large JSON payload can't
      // fill the 64KB pipe buffer and deadlock against waitUntilExit.
      let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
      proc.waitUntilExit()
      guard proc.terminationStatus == 0 else { return "" }
      return String(data: data, encoding: .utf8) ?? ""
    } catch {
      return ""
    }
  }
}
