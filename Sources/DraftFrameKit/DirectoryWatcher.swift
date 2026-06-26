import CoreServices
import Foundation

/// Watches a directory tree recursively via FSEvents and invokes `onChange`
/// on the main queue whenever anything inside it changes. FSEvents is
/// inherently recursive, so a single stream rooted at a worktree covers every
/// nested file; the OS coalesces bursts within `latency` so a `git checkout`
/// touching hundreds of files yields only a handful of callbacks.
///
/// Used to keep the sidebar CHANGES list live even when files are edited
/// outside of agent activity (e.g. the user's own editor), which the
/// notification-driven refresh alone would miss.
final class DirectoryWatcher {
  private var stream: FSEventStreamRef?
  private let onChange: () -> Void

  /// Returns nil if FSEvents could not start a stream for `path` (e.g. the
  /// path doesn't exist or sits on a volume without event support); callers
  /// should fall back to their existing notification-driven refresh.
  init?(path: String, latency: TimeInterval = 0.4, onChange: @escaping () -> Void) {
    self.onChange = onChange

    // `self` is fully initialized here (stream/onChange are set), so it's safe
    // to hand FSEvents an unretained pointer back to us. The watcher outlives
    // the stream because `deinit` stops it before we're deallocated.
    var context = FSEventStreamContext(
      version: 0,
      info: Unmanaged.passUnretained(self).toOpaque(),
      retain: nil,
      release: nil,
      copyDescription: nil)

    let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
      guard let info = info else { return }
      let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
      // We don't inspect which paths changed — just re-check from the main
      // thread. The caller's snapshot guard turns no-op events into cheap
      // git-status checks.
      DispatchQueue.main.async { watcher.onChange() }
    }

    // NoDefer delivers the first event of a burst immediately (then coalesces
    // the rest), so the first edit shows up without waiting out the latency.
    let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)

    guard
      let stream = FSEventStreamCreate(
        kCFAllocatorDefault,
        callback,
        &context,
        [path] as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        latency,
        flags)
    else { return nil }

    self.stream = stream
    FSEventStreamSetDispatchQueue(
      stream, DispatchQueue(label: "com.draftframe.directorywatcher"))
    guard FSEventStreamStart(stream) else {
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      self.stream = nil
      return nil
    }
  }

  deinit {
    guard let stream = stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
  }
}
