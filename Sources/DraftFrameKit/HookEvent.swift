import Foundation

/// One Claude Code hook event, as forwarded by the bridge script: the tab it
/// belongs to plus the fields of Claude Code's payload that drive status and
/// transcript binding. Everything else in the payload is ignored.
struct HookEvent: Equatable, Sendable {
  /// DraftFrame tab (the `Session.id`), from `DRAFTFRAME_SESSION_ID`.
  let tabID: UUID
  /// `hook_event_name`: SessionStart, Stop, Notification, ...
  let name: String
  /// Claude Code's own session id (what `--resume` takes).
  let sessionId: String
  /// Path of the conversation JSONL. Written asynchronously by Claude Code,
  /// so it may not exist yet when the first event arrives.
  let transcriptPath: String?
  let cwd: String?
  /// Parent pid reported by the bridge shell. Usually the claude process,
  /// but hook spawning details vary, so callers treat it as a hint and
  /// confirm it across events before using it for liveness.
  let ppid: Int32?
  /// SessionStart `source`: startup, resume, clear, compact, fork.
  let source: String?
  /// Notification `notification_type`: permission_prompt, idle_prompt, ...
  let notificationType: String?
  /// SessionEnd `reason`.
  let reason: String?

  /// Parse one bridge message: `{"tab": "...", "ppid": N, "event": {...}}`.
  /// Returns nil for anything that can't be attributed to a tab and event.
  static func parse(_ data: Data) -> HookEvent? {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let tab = obj["tab"] as? String, let tabID = UUID(uuidString: tab),
      let event = obj["event"] as? [String: Any],
      let name = event["hook_event_name"] as? String,
      let sessionId = event["session_id"] as? String, !sessionId.isEmpty
    else { return nil }
    var ppid: Int32?
    if let p = obj["ppid"] as? Int, p > 1 { ppid = Int32(p) }
    return HookEvent(
      tabID: tabID, name: name, sessionId: sessionId,
      transcriptPath: event["transcript_path"] as? String,
      cwd: event["cwd"] as? String,
      ppid: ppid,
      source: event["source"] as? String,
      notificationType: event["notification_type"] as? String,
      reason: event["reason"] as? String)
  }

  /// The session state this event implies, or nil when it carries no
  /// status information (auth notices, compaction).
  var stateTransition: SessionState? {
    switch name {
    case "SessionStart":
      // Compaction happens mid-turn; the model keeps working afterwards.
      return source == "compact" ? nil : .userInput
    case "UserPromptSubmit", "PreToolUse", "PostToolUse":
      // Any tool activity also means an earlier permission prompt was
      // answered, so this clears `.needsAttention`.
      return .generating
    case "Notification":
      switch notificationType {
      case "idle_prompt": return .userInput
      case "auth_success", "auth_failure", "auth_needed": return nil
      // permission_prompt, elicitation_dialog, agent_needs_input, and any
      // type added later: Claude Code is asking the user for something.
      default: return .needsAttention
      }
    case "Stop":
      return .userInput
    case "SessionEnd":
      return .idle
    default:
      return nil
    }
  }
}
