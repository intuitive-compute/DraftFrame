import AppKit
import UserNotifications

/// Manages macOS notifications for session state transitions.
/// Sends alerts when background sessions need attention or finish generating.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
  static let shared = NotificationManager()

  /// Whether we can use UNUserNotificationCenter (requires app bundle).
  private let canUseNotifications = Bundle.main.bundleIdentifier != nil

  /// Tracks previous state per session ID so we can detect transitions.
  private var previousStates: [UUID: SessionState] = [:]

  private override init() {
    super.init()

    if canUseNotifications {
      UNUserNotificationCenter.current().delegate = self
    }

    NotificationCenter.default.addObserver(
      self, selector: #selector(sessionsChanged),
      name: .sessionsDidChange, object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - Authorization

  /// Request notification permission. Call from DFAppDelegate on launch.
  func requestAuthorization() {
    guard Bundle.main.bundleIdentifier != nil else { return }
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
      if let error = error {
        NSLog("[NotificationManager] Authorization error: \(error.localizedDescription)")
      }
    }
  }

  // MARK: - Session State Observation

  @objc private func sessionsChanged() {
    let sessions = SessionManager.shared.sessions
    let activeSession = SessionManager.shared.activeSession

    var needsAttentionCount = 0

    for session in sessions {
      let previous = previousStates[session.id] ?? .idle
      let current = session.state

      // Count sessions needing attention for badge
      if current == .needsAttention {
        needsAttentionCount += 1
      }

      // Only notify for non-active (background) sessions
      let isActive = session.id == activeSession?.id
      if !isActive && previous != current {
        // Transition to .needsAttention
        if current == .needsAttention {
          sendNotification(
            title: "Session needs attention",
            body: "\(session.name) \u{2014} permission prompt or error",
            identifier: "needsAttention-\(session.id.uuidString)"
          )
        }

        // Transition from non-idle to .userInput (Claude finished)
        if current == .userInput && previous != .idle {
          sendNotification(
            title: "Claude finished",
            body: "\(session.name) is waiting for input",
            identifier: "finished-\(session.id.uuidString)"
          )
        }
      }

      // Update tracked state
      previousStates[session.id] = current
    }

    // Clean up states for removed sessions
    let activeIDs = Set(sessions.map { $0.id })
    previousStates = previousStates.filter { activeIDs.contains($0.key) }

    // Update dock badge
    updateDockBadge(count: needsAttentionCount)
  }

  // MARK: - Public API for Watchdogs

  /// Send a notification on behalf of a watchdog. Public so WatchdogManager can use it.
  func sendWatchdogNotification(title: String, body: String) {
    sendNotification(title: title, body: body, identifier: "watchdog-\(UUID().uuidString)")
  }

  // MARK: - Sending Notifications

  private func sendNotification(title: String, body: String, identifier: String) {
    guard canUseNotifications else {
      NSLog("[NotificationManager] %@: %@", title, body)
      return
    }

    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default

    let request = UNNotificationRequest(
      identifier: identifier,
      content: content,
      trigger: nil
    )

    UNUserNotificationCenter.current().add(request) { error in
      if let error = error {
        NSLog("[NotificationManager] Failed to deliver notification: \(error.localizedDescription)")
      }
    }
  }

  // MARK: - Dock Badge

  private func updateDockBadge(count: Int) {
    DispatchQueue.main.async {
      if count > 0 {
        NSApp.dockTile.badgeLabel = "\(count)"
      } else {
        NSApp.dockTile.badgeLabel = nil
      }
    }
  }

  // MARK: - UNUserNotificationCenterDelegate

  /// Show notifications even when the app is in the foreground (but we filter
  /// to background sessions above, so this is a safety net).
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }

  /// When user clicks a notification, switch to the relevant session.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let identifier = response.notification.request.identifier
    // Identifier format: "type-UUID"
    let components = identifier.split(separator: "-", maxSplits: 1)
    if components.count == 2, let uuid = UUID(uuidString: String(components[1])) {
      DispatchQueue.main.async {
        let sessions = SessionManager.shared.sessions
        if let idx = sessions.firstIndex(where: { $0.id == uuid }) {
          SessionManager.shared.switchTo(index: idx)
        }
        NSApp.activate(ignoringOtherApps: true)
      }
    }
    completionHandler()
  }
}
