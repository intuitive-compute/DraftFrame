import Foundation

/// Tails a JSONL file that another process appends to, delivering complete
/// lines in order. Owns the subtle machinery shared by every transcript
/// watcher so its invariants live in exactly one place:
///
/// - The kqueue event source's CANCEL HANDLER is the sole closer of the
///   event fd. `cancel()` is async; closing the fd anywhere else would free
///   its number for reuse before the handler runs, making the handler close
///   an unrelated fd (libdispatch EV_VANISHED trap).
/// - Reads always go through a fresh `FileHandle`. A long-lived handle on
///   macOS caches stat info and misses appends made by another process even
///   after `seek(toOffset:)`.
/// - Byte-offset tracking with a partial-line carry buffer, since JSONL
///   writes can land mid-line.
/// - A 1.5s poll fallback — some filesystems don't reliably deliver vnode
///   events for every append.
/// - Discovery polling until `findLatest` first returns a file, and a
///   throttled newest-file rescan afterwards that switches to a newer file
///   (a new agent run writes a new transcript; without the switch we'd
///   track the stale file forever).
///
/// `findLatest`, `onSwitch`, and `onLines` are all invoked on the tailer's
/// private queue.
final class JSONLTailer {

  private let findLatest: () -> String?
  /// Called when a newer file replaces the tracked one, before any of the
  /// new file's lines are delivered — the watcher resets its per-run state.
  private let onSwitch: () -> Void
  private let onLines: ([String]) -> Void

  private let queue = DispatchQueue(label: "com.draftframe.jsonl-tailer", qos: .utility)
  private var watcherFD: Int32 = -1
  private var dispatchSource: DispatchSourceFileSystemObject?
  private var fileOffset: UInt64 = 0
  private var lineBuffer: String = ""
  private var pollTimer: DispatchSourceTimer?
  private var discoveryTimer: DispatchSourceTimer?
  private var watchedPath: String?
  /// Write events fire many times per second while the agent streams;
  /// without this throttle each one would re-run the full newest-file scan.
  private var lastNewestScan = Date.distantPast

  init(
    findLatest: @escaping () -> String?,
    onSwitch: @escaping () -> Void = {},
    onLines: @escaping ([String]) -> Void
  ) {
    self.findLatest = findLatest
    self.onSwitch = onSwitch
    self.onLines = onLines
    queue.async { [weak self] in
      self?.resolveAndWatch()
    }
  }

  deinit {
    stop()
  }

  func stop() {
    // The source's cancel handler owns close(fd) — see the class comment.
    dispatchSource?.cancel()
    dispatchSource = nil
    watcherFD = -1
    pollTimer?.cancel()
    pollTimer = nil
    discoveryTimer?.cancel()
    discoveryTimer = nil
  }

  // MARK: - Discovery

  private func resolveAndWatch() {
    if let path = findLatest() {
      startWatching(path: path)
      return
    }
    // The transcript may not exist yet (the agent hasn't started) — poll
    // until it appears.
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 2, repeating: 3.0)
    timer.setEventHandler { [weak self] in
      guard let self = self else { return }
      if let path = self.findLatest() {
        self.discoveryTimer?.cancel()
        self.discoveryTimer = nil
        self.startWatching(path: path)
      }
    }
    timer.resume()
    discoveryTimer = timer
  }

  // MARK: - File watching

  private func startWatching(path: String) {
    watchedPath = path

    // Process whatever's already in the file.
    processNewData()

    attachFileSource(path: path)

    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 1.5, repeating: 1.5)
    timer.setEventHandler { [weak self] in
      self?.processNewData()
    }
    timer.resume()
    pollTimer = timer
  }

  /// Re-attach to a newer file, restarting from byte 0.
  private func switchTo(path: String) {
    // Let the old source's cancel handler close its fd. The fd stays open
    // until the handler runs, so the `open()` below is guaranteed a fresh
    // number — closing it synchronously here would race that reuse.
    dispatchSource?.cancel()
    dispatchSource = nil
    watcherFD = -1
    watchedPath = path
    fileOffset = 0
    lineBuffer = ""
    onSwitch()
    attachFileSource(path: path)
  }

  private func attachFileSource(path: String) {
    // The fd is used only for kqueue event delivery — reads go through a
    // fresh file handle (see the class comment).
    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else { return }
    watcherFD = fd
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd,
      eventMask: [.write, .extend],
      queue: queue
    )
    source.setEventHandler { [weak self] in
      self?.processNewData()
    }
    source.setCancelHandler { [weak self] in
      if let self = self, self.watcherFD == fd { self.watcherFD = -1 }
      close(fd)
    }
    source.resume()
    dispatchSource = source
  }

  private func processNewData() {
    // Switch if a newer file has appeared since we attached. Throttled to
    // every 2s; the 1.5s poll timer guarantees we still converge on a new
    // file within ~3.5s even with no write events.
    let now = Date()
    if now.timeIntervalSince(lastNewestScan) >= 2.0 {
      lastNewestScan = now
      if let newest = findLatest(), newest != watchedPath {
        switchTo(path: newest)
      }
    }

    guard let path = watchedPath else { return }

    guard let fh = FileHandle(forReadingAtPath: path) else { return }
    defer { try? fh.close() }

    do {
      try fh.seek(toOffset: fileOffset)
    } catch {
      return
    }
    let data = fh.readDataToEndOfFile()
    guard !data.isEmpty else { return }
    fileOffset += UInt64(data.count)

    guard let text = String(data: data, encoding: .utf8) else { return }
    // Prepend any partial line carried over from a previous read.
    let combined = lineBuffer + text
    let lastNewline = combined.lastIndex(of: "\n")
    let processable: Substring
    if let nl = lastNewline {
      processable = combined[..<nl]
      lineBuffer = String(combined[combined.index(after: nl)...])
    } else {
      // No newline yet — entire chunk is partial; buffer it for next read.
      lineBuffer = combined
      return
    }

    let lines = processable.split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    if !lines.isEmpty {
      onLines(lines)
    }
  }
}
