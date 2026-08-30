import Foundation

/// Single shared watcher over Claude Code's per-pid status files
/// (`~/.claude/sessions/<pid>.json`), fanning authoritative session state
/// out to every subscribed session.
///
/// Each `SessionStatusWatcher` used to run its own 1.5s poll that read and
/// JSON-parsed EVERY file in the directory — N sessions paid N identical
/// scans, plus a `kill(pid, 0)` per file per session. The registry performs
/// one scan per tick, resolves the newest live pid file per subscribed cwd,
/// and reports state changes per subscriber. Write-event sources on the
/// matched files keep latency below the poll cadence, exactly like the old
/// per-session watcher.
///
/// An actor so every piece of mutable state (subscribers, dedup, sources,
/// poll task) is compiler-enforced serial — the registry is touched from the
/// main queue (subscribe/stop), file-event handlers, and its own poll loop.
actor SessionStatusRegistry {

  static let shared = SessionStatusRegistry()

  /// Liveness probe supplied by the subscribing handle. Checked before
  /// every callback (and each tick) so a handle stopped or deallocated
  /// between actor hops is pruned instead of notified — this also makes an
  /// out-of-order stop()-before-subscribe harmless: the late subscribe is
  /// refused because the probe already answers false.
  typealias IsActive = @Sendable () -> Bool
  /// Fired on the main queue, only when the state differs from the last
  /// one reported to this subscriber.
  typealias Callback = @Sendable (SessionState) -> Void

  private struct Subscriber {
    let cwd: String
    let isActive: IsActive
    let callback: Callback
    var lastReported: SessionState?
  }

  /// One parsed status file. `state` is nil when the JSON is readable but
  /// carries no recognized `status` — the subscriber keeps its last state,
  /// matching the old watcher's behavior for torn/partial writes.
  private struct PidFile {
    let path: String
    let cwd: String
    let startedAt: Double
    let state: SessionState?
  }

  private let sessionsDir: String
  private var subscribers: [UUID: Subscriber] = [:]
  private var pollTask: Task<Void, Never>?
  /// One write-event source per pid file currently matched to a subscriber.
  private var fileSources: [String: DispatchSourceFileSystemObject] = [:]

  /// `sessionsDir` overrides the status-file location for tests.
  init(sessionsDir: String = "\(NSHomeDirectory())/.claude/sessions") {
    self.sessionsDir = sessionsDir
  }

  func subscribe(
    id: UUID, cwd: String,
    isActive: @escaping IsActive,
    onUpdate: @escaping Callback
  ) {
    guard isActive() else { return }
    // Match on symlink-resolved paths: Claude Code writes the realpath into
    // the pid file (e.g. /private/tmp) while sessions may hold the
    // unresolved spelling (/tmp) — an exact compare would leave any project
    // under a symlinked path without authoritative status forever.
    subscribers[id] = Subscriber(
      cwd: Self.resolved(cwd), isActive: isActive, callback: onUpdate)
    startPollingIfNeeded()
    tick()
  }

  private static func resolved(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().path
  }

  func unsubscribe(id: UUID) {
    subscribers.removeValue(forKey: id)
    if subscribers.isEmpty { stopPolling() }
  }

  // MARK: - Poll loop

  private func startPollingIfNeeded() {
    guard pollTask == nil else { return }
    // Weak so a test-owned registry that is dropped without unsubscribing
    // doesn't keep itself alive through its own loop.
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard let self else { return }
        await self.tick()
      }
    }
  }

  private func stopPolling() {
    pollTask?.cancel()
    pollTask = nil
    for source in fileSources.values { source.cancel() }
    fileSources = [:]
    resolvedCwdCache = [:]
  }

  // MARK: - Scan / dispatch

  /// One pass: prune dead subscribers, scan the directory once, resolve the
  /// newest live pid file per cwd, retarget write-event sources, and report
  /// state changes.
  private func tick() {
    subscribers = subscribers.filter { $0.value.isActive() }
    guard !subscribers.isEmpty else {
      stopPolling()
      return
    }

    var bestByCwd: [String: PidFile] = [:]
    for file in scanPidFiles() {
      if let current = bestByCwd[file.cwd], current.startedAt > file.startedAt { continue }
      bestByCwd[file.cwd] = file
    }

    let matchedPaths = Set(subscribers.values.compactMap { bestByCwd[$0.cwd]?.path })
    retargetFileSources(to: matchedPaths)

    for (id, var sub) in subscribers {
      let state: SessionState
      if let file = bestByCwd[sub.cwd] {
        // Readable file without a recognized status — keep the last state.
        guard let parsed = file.state else { continue }
        state = parsed
      } else {
        // No live claude here — terminal is at the shell prompt.
        state = .idle
      }
      guard state != sub.lastReported else { continue }
      sub.lastReported = state
      subscribers[id] = sub

      let callback = sub.callback
      let isActive = sub.isActive
      DispatchQueue.main.async {
        guard isActive() else { return }
        callback(state)
      }
    }
  }

  /// Symlink resolution hits the filesystem per path component; pid-file
  /// cwds repeat on every 1.5s tick, so cache them. Live pid files number a
  /// handful, so the cache stays tiny; it's dropped with the poll loop.
  private var resolvedCwdCache: [String: String] = [:]

  private func resolvedCwd(_ cwd: String) -> String {
    if let cached = resolvedCwdCache[cwd] { return cached }
    let resolved = Self.resolved(cwd)
    resolvedCwdCache[cwd] = resolved
    return resolved
  }

  /// Read and parse every pid file once, keeping only live processes
  /// (`kill(pid, 0) == 0`, same liveness test the per-session watcher used).
  private func scanPidFiles() -> [PidFile] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: sessionsDir) else {
      return []
    }
    var out: [PidFile] = []
    for name in names where name.hasSuffix(".json") {
      let full = "\(sessionsDir)/\(name)"
      guard let data = try? Data(contentsOf: URL(fileURLWithPath: full)),
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let cwd = obj["cwd"] as? String,
        let pid = obj["pid"] as? Int, kill(pid_t(pid), 0) == 0
      else { continue }

      let state: SessionState?
      switch obj["status"] as? String {
      case "busy": state = .generating
      case "waiting": state = .needsAttention
      case "idle": state = .userInput
      default: state = nil
      }
      out.append(
        PidFile(
          path: full,
          cwd: resolvedCwd(cwd),
          startedAt: (obj["startedAt"] as? Double) ?? 0,
          state: state))
    }
    return out
  }

  // MARK: - File-event sources

  private func retargetFileSources(to paths: Set<String>) {
    for (path, source) in fileSources where !paths.contains(path) {
      source.cancel()
      fileSources.removeValue(forKey: path)
    }
    for path in paths where fileSources[path] == nil {
      attachFileSource(path: path)
    }
  }

  private func attachFileSource(path: String) {
    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd,
      eventMask: [.write, .extend, .delete, .rename],
      queue: DispatchQueue.global(qos: .utility)
    )
    source.setEventHandler { [weak self] in
      guard let self else { return }
      Task { await self.tick() }
    }
    // The cancel handler is the SOLE closer of the event fd. `cancel()` is
    // async; closing anywhere else would free the fd number for reuse before
    // the handler runs, making it close an unrelated fd (libdispatch
    // EV_VANISHED trap).
    source.setCancelHandler { close(fd) }
    source.resume()
    fileSources[path] = source
  }
}
