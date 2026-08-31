import Foundation
import os

/// Reports authoritative session status from the per-pid state file Claude
/// Code writes at `~/.claude/sessions/<pid>.json`. Far more reliable than
/// PTY parsing — TUI redraws can push our textual markers (like "esc to
/// interrupt") out of the rolling buffer before we observe them, but Claude
/// Code keeps the JSON file fresh as state changes.
///
/// Thin per-session handle over the shared `SessionStatusRegistry`, which
/// owns the single directory scan and file-event machinery for every session
/// at once. `onUpdate` fires on the main queue, only when the state changes.
final class SessionStatusWatcher {

  typealias UpdateCallback = @MainActor @Sendable (SessionState) -> Void

  private let id = UUID()
  /// Consulted by the registry (its liveness probe) before every callback.
  /// A lock rather than a plain Bool because the probe runs from the
  /// registry's executor and the main queue.
  private let stopped = OSAllocatedUnfairLock(initialState: false)

  init(cwd: String, onUpdate: @escaping UpdateCallback) {
    let id = self.id
    let stopped = self.stopped
    // The subscribe and unsubscribe hops are separate Tasks and may land on
    // the actor in either order; the registry refuses a subscribe whose
    // probe already answers false, so a stop() racing init is safe.
    Task {
      await SessionStatusRegistry.shared.subscribe(
        id: id, cwd: cwd,
        isActive: { !stopped.withLock { $0 } },
        onUpdate: onUpdate)
    }
  }

  deinit { stop() }

  func stop() {
    stopped.withLock { $0 = true }
    let id = self.id
    Task { await SessionStatusRegistry.shared.unsubscribe(id: id) }
  }
}
