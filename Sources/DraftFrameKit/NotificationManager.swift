import AppKit
import UserNotifications

/// Manages macOS notifications for session state transitions.
/// Sends alerts when background sessions need attention or finish generating.
/// Main-actor isolated; the UNUserNotificationCenter delegate callbacks are
/// `nonisolated` (the framework calls them on its own queue) and hop to the
/// main actor where they touch session state.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
  static let shared = NotificationManager()

  /// Whether we can use UNUserNotificationCenter (requires app bundle).
  private let canUseNotifications = Bundle.main.bundleIdentifier != nil

  private override init() {
    super.init()

    if canUseNotifications {
      UNUserNotificationCenter.current().delegate = self
    }

    NotificationCenter.default.addObserver(
      self, selector: #selector(sessionStateChanged(_:)),
      name: .sessionStateDidChange, object: nil
    )
    // A needs-attention session being closed shrinks the badge count.
    NotificationCenter.default.addObserver(
      self, selector: #selector(sessionListChanged),
      name: .sessionListDidChange, object: nil
    )
  }

  // No deinit: the shared singleton never deallocates, so observer removal
  // there would be dead code.

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

  /// The typed event carries the transition, so there's no per-session state
  /// diffing (or its cleanup) here anymore.
  @objc private func sessionStateChanged(_ note: Notification) {
    if let change = SessionEvents.stateChange(note),
      let session = SessionManager.shared.sessions.first(where: { $0.id == change.id }),
      // Only notify for non-active (background) sessions
      session.id != SessionManager.shared.activeSession?.id
    {
      // Transition to .needsAttention
      if change.new == .needsAttention {
        sendNotification(
          title: "Session needs attention",
          body: "\(session.name) \u{2014} permission prompt or error",
          identifier: "needsAttention-\(session.id.uuidString)"
        )
      }

      // Transition from non-idle to .userInput (the agent finished)
      if change.new == .userInput && change.old != .idle {
        sendNotification(
          title: "\(session.agent.displayName) finished",
          body: "\(session.name) is waiting for input",
          identifier: "finished-\(session.id.uuidString)"
        )
      }
    }

    refreshDockBadge()
  }

  @objc private func sessionListChanged() {
    refreshDockBadge()
  }

  private func refreshDockBadge() {
    let count = SessionManager.shared.sessions.filter { $0.state == .needsAttention }.count
    updateDockBadge(count: count)
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
    if count > 0 {
      NSApp.dockTile.badgeLabel = "\(count)"
    } else {
      NSApp.dockTile.badgeLabel = nil
    }
  }

  // MARK: - UNUserNotificationCenterDelegate

  /// Show notifications even when the app is in the foreground (but we filter
  /// to background sessions above, so this is a safety net).
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }

  /// When user clicks a notification, switch to the relevant session.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let identifier = response.notification.request.identifier
    // Identifier format: "type-UUID"
    let components = identifier.split(separator: "-", maxSplits: 1)
    if components.count == 2, let uuid = UUID(uuidString: String(components[1])) {
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          let sessions = SessionManager.shared.sessions
          if let idx = sessions.firstIndex(where: { $0.id == uuid }) {
            SessionManager.shared.switchTo(index: idx)
          }
          NSApp.activate(ignoringOtherApps: true)
        }
      }
    }
    completionHandler()
  }
}
