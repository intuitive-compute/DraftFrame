import AppKit

// MARK: - Watchdog Model

enum WatchdogTrigger {
  case needsAttention  // session enters .needsAttention state
  case idleAfterWork  // session goes from generating/thinking to userInput
  case periodic(seconds: Int)  // check every N seconds
}

enum WatchdogResponse {
  case notify  // just send macOS notification
  case autoAccept  // auto-type "y" to accept prompts
  case sendText(String)  // send custom text to the session
  case runCommand(String)  // run a shell command and send output
}

struct Watchdog: Identifiable {
  let id: UUID
  var name: String
  var isEnabled: Bool
  var sessionID: UUID?  // nil = watch all sessions
  var trigger: WatchdogTrigger
  var response: WatchdogResponse
}

// MARK: - WatchdogManager

/// Singleton that manages watchdogs — semi-autonomous monitors that watch
/// Claude sessions and auto-respond when certain conditions are met.
final class WatchdogManager {
  static let shared = WatchdogManager()

  private(set) var watchdogs: [Watchdog] = []

  /// Log of all watchdog actions: (timestamp, description).
  private(set) var watchdogLog: [(Date, String)] = []

  /// Tracks previous session states to detect transitions.
  private var previousStates: [UUID: SessionState] = [:]

  /// Timers for periodic watchdogs, keyed by watchdog ID.
  private var periodicTimers: [UUID: Timer] = [:]

  private init() {
    loadDefaults()

    NotificationCenter.default.addObserver(
      self, selector: #selector(sessionsChanged),
      name: .sessionsDidChange, object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    for timer in periodicTimers.values { timer.invalidate() }
  }

  // MARK: - Default Watchdogs

  private func loadDefaults() {
    watchdogs = [
      Watchdog(
        id: UUID(),
        name: "Auto-accept tools",
        isEnabled: false,
        sessionID: nil,
        trigger: .needsAttention,
        response: .autoAccept
      ),
      Watchdog(
        id: UUID(),
        name: "Notify on finish",
        isEnabled: true,
        sessionID: nil,
        trigger: .idleAfterWork,
        response: .notify
      ),
    ]
  }

  // MARK: - CRUD

  func addWatchdog(_ watchdog: Watchdog) {
    watchdogs.append(watchdog)
    if watchdog.isEnabled {
      startPeriodicTimerIfNeeded(for: watchdog)
    }
    NotificationCenter.default.post(name: .watchdogsDidChange, object: nil)
  }

  func removeWatchdog(id: UUID) {
    stopPeriodicTimer(for: id)
    watchdogs.removeAll { $0.id == id }
    NotificationCenter.default.post(name: .watchdogsDidChange, object: nil)
  }

  func updateWatchdog(_ updated: Watchdog) {
    guard let idx = watchdogs.firstIndex(where: { $0.id == updated.id }) else { return }
    let old = watchdogs[idx]
    watchdogs[idx] = updated

    // Handle periodic timer changes
    if !updated.isEnabled {
      stopPeriodicTimer(for: updated.id)
    } else {
      // Restart timer if trigger changed or was just enabled
      let triggerChanged: Bool
      switch (old.trigger, updated.trigger) {
      case (.periodic(let a), .periodic(let b)): triggerChanged = a != b
      case (.periodic, _), (_, .periodic): triggerChanged = true
      default: triggerChanged = false
      }
      if triggerChanged || (!old.isEnabled && updated.isEnabled) {
        stopPeriodicTimer(for: updated.id)
        startPeriodicTimerIfNeeded(for: updated)
      }
    }

    NotificationCenter.default.post(name: .watchdogsDidChange, object: nil)
  }

  func toggleWatchdog(id: UUID) {
    guard let idx = watchdogs.firstIndex(where: { $0.id == id }) else { return }
    watchdogs[idx].isEnabled.toggle()
    if watchdogs[idx].isEnabled {
      startPeriodicTimerIfNeeded(for: watchdogs[idx])
    } else {
      stopPeriodicTimer(for: id)
    }
    NotificationCenter.default.post(name: .watchdogsDidChange, object: nil)
  }

  // MARK: - Session State Observation

  @objc private func sessionsChanged() {
    let sessions = SessionManager.shared.sessions

    for session in sessions {
      let previous = previousStates[session.id] ?? .idle
      let current = session.state

      guard previous != current else { continue }

      // Evaluate all enabled watchdogs
      for watchdog in watchdogs where watchdog.isEnabled {
        // Check session scope
        if let targetID = watchdog.sessionID, targetID != session.id {
          continue
        }

        var shouldFire = false

        switch watchdog.trigger {
        case .needsAttention:
          shouldFire = current == .needsAttention

        case .idleAfterWork:
          let wasWorking = previous == .generating || previous == .thinking
          shouldFire = wasWorking && current == .userInput

        case .periodic:
          // Periodic triggers are handled by timers, not state transitions
          break
        }

        if shouldFire {
          executeResponse(watchdog.response, for: session, watchdog: watchdog)
        }
      }

      previousStates[session.id] = current
    }

    // Clean up states for removed sessions
    let activeIDs = Set(sessions.map { $0.id })
    previousStates = previousStates.filter { activeIDs.contains($0.key) }
  }

  // MARK: - Periodic Timers

  private func startPeriodicTimerIfNeeded(for watchdog: Watchdog) {
    guard case .periodic(let seconds) = watchdog.trigger, watchdog.isEnabled else { return }

    let interval = TimeInterval(max(seconds, 1))
    let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
      self?.firePeriodicWatchdog(id: watchdog.id)
    }
    RunLoop.main.add(timer, forMode: .common)
    periodicTimers[watchdog.id] = timer
  }

  private func stopPeriodicTimer(for watchdogID: UUID) {
    periodicTimers[watchdogID]?.invalidate()
    periodicTimers.removeValue(forKey: watchdogID)
  }

  private func firePeriodicWatchdog(id: UUID) {
    guard let watchdog = watchdogs.first(where: { $0.id == id }),
      watchdog.isEnabled
    else { return }

    let sessions = SessionManager.shared.sessions
    for session in sessions {
      if let targetID = watchdog.sessionID, targetID != session.id {
        continue
      }
      executeResponse(watchdog.response, for: session, watchdog: watchdog)
    }
  }

  // MARK: - Response Execution

  private func executeResponse(
    _ response: WatchdogResponse, for session: Session, watchdog: Watchdog
  ) {
    let logPrefix = "[\(watchdog.name)] \(session.name)"

    switch response {
    case .notify:
      let msg = "\(logPrefix): sending notification"
      appendLog(msg)
      NotificationManager.shared.sendWatchdogNotification(
        title: "Watchdog: \(watchdog.name)",
        body: "Session \"\(session.name)\" triggered \(watchdog.name)"
      )

    case .autoAccept:
      let msg = "\(logPrefix): auto-accepting (sending 'y')"
      appendLog(msg)
      DispatchQueue.main.async {
        session.terminalView?.send(txt: "y\r")
      }

    case .sendText(let text):
      let msg = "\(logPrefix): sending text \"\(text)\""
      appendLog(msg)
      DispatchQueue.main.async {
        session.terminalView?.send(txt: text + "\r")
      }

    case .runCommand(let cmd):
      let msg = "\(logPrefix): running command \"\(cmd)\""
      appendLog(msg)
      runShellCommand(cmd) { [weak self] output in
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        self?.appendLog("\(logPrefix): command output: \(trimmed)")
        DispatchQueue.main.async {
          session.terminalView?.send(txt: trimmed + "\r")
        }
      }
    }
  }

  private func runShellCommand(_ command: String, completion: @escaping (String) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
      let proc = Process()
      let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
      proc.executableURL = URL(fileURLWithPath: shell)
      proc.arguments = ["-l", "-c", command]

      let pipe = Pipe()
      proc.standardOutput = pipe
      proc.standardError = pipe

      do {
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        DispatchQueue.main.async {
          completion(output)
        }
      } catch {
        DispatchQueue.main.async {
          completion("Error: \(error.localizedDescription)")
        }
      }
    }
  }

  private func appendLog(_ message: String) {
    let entry = (Date(), message)
    watchdogLog.append(entry)
    NSLog("[Watchdog] %@", message)

    // Cap the log at 500 entries
    if watchdogLog.count > 500 {
      watchdogLog.removeFirst(watchdogLog.count - 500)
    }
  }
}

// MARK: - Notification Name

extension Notification.Name {
  static let watchdogsDidChange = Notification.Name("DFWatchdogsDidChange")
}
