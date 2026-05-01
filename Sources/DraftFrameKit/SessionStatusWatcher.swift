import Foundation

/// Watches the per-pid state file Claude Code writes at
/// `~/.claude/sessions/<pid>.json` and reports authoritative session status.
/// Far more reliable than PTY parsing — TUI redraws can push our textual
/// markers (like "esc to interrupt") out of the rolling buffer before we
/// observe them, but Claude Code keeps the JSON file fresh as state changes.
final class SessionStatusWatcher {

  typealias UpdateCallback = (SessionState) -> Void

  private let cwd: String
  private let onUpdate: UpdateCallback

  private let queue = DispatchQueue(label: "com.draftframe.status-watcher", qos: .utility)
  private var pollTimer: DispatchSourceTimer?
  private var fileSource: DispatchSourceFileSystemObject?
  private var watchedPath: String?
  private var watchedFD: Int32 = -1
  private var lastReported: SessionState?

  init(cwd: String, onUpdate: @escaping UpdateCallback) {
    self.cwd = cwd
    self.onUpdate = onUpdate

    // Re-resolve the matching pid file frequently so a new claude run, a
    // restart, or an atomic-rename of the JSON (which invalidates our
    // file-event subscription) all converge within ~1.5s.
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 0.5, repeating: 1.5)
    timer.setEventHandler { [weak self] in
      self?.tick()
    }
    timer.resume()
    pollTimer = timer
  }

  deinit { stop() }

  func stop() {
    pollTimer?.cancel()
    pollTimer = nil
    fileSource?.cancel()
    fileSource = nil
    if watchedFD >= 0 {
      close(watchedFD)
      watchedFD = -1
    }
  }

  private func tick() {
    let resolved = findMatchingPidFile()
    if resolved != watchedPath {
      detachFileWatcher()
      watchedPath = resolved
      if let path = resolved {
        attachFileWatcher(path: path)
      }
    }
    readAndDispatch()
  }

  /// Find the most recently started pid file whose `cwd` matches and whose
  /// pid is still alive. Returns nil when no live claude is running here.
  private func findMatchingPidFile() -> String? {
    let dir = "\(NSHomeDirectory())/.claude/sessions"
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
      return nil
    }

    var bestPath: String?
    var bestStartedAt: Double = 0

    for name in names where name.hasSuffix(".json") {
      let full = "\(dir)/\(name)"
      guard let data = try? Data(contentsOf: URL(fileURLWithPath: full)),
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let pidCwd = obj["cwd"] as? String, pidCwd == cwd,
        let pid = obj["pid"] as? Int, kill(pid_t(pid), 0) == 0
      else { continue }
      let startedAt = (obj["startedAt"] as? Double) ?? 0
      if startedAt >= bestStartedAt {
        bestStartedAt = startedAt
        bestPath = full
      }
    }
    return bestPath
  }

  private func attachFileWatcher(path: String) {
    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else { return }
    watchedFD = fd
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd,
      eventMask: [.write, .extend, .delete, .rename],
      queue: queue
    )
    source.setEventHandler { [weak self] in
      self?.readAndDispatch()
    }
    source.setCancelHandler { [weak self] in
      if let self = self, self.watchedFD == fd { self.watchedFD = -1 }
      close(fd)
    }
    source.resume()
    fileSource = source
  }

  private func detachFileWatcher() {
    fileSource?.cancel()
    fileSource = nil
    watchedPath = nil
    if watchedFD >= 0 {
      close(watchedFD)
      watchedFD = -1
    }
  }

  private func readAndDispatch() {
    guard let path = watchedPath else {
      // No live claude here — terminal is at the shell prompt.
      report(.idle)
      return
    }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let status = obj["status"] as? String
    else { return }

    let state: SessionState
    switch status {
    case "busy": state = .generating
    case "waiting": state = .needsAttention
    case "idle": state = .userInput
    default: return
    }
    report(state)
  }

  private func report(_ state: SessionState) {
    guard state != lastReported else { return }
    lastReported = state
    DispatchQueue.main.async { [weak self] in
      self?.onUpdate(state)
    }
  }
}
