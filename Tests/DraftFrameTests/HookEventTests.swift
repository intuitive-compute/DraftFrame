import XCTest

@testable import DraftFrameKit

final class HookEventTests: XCTestCase {

  private let tab = UUID()

  private func message(_ event: [String: Any], ppid: Int? = 4242, tab: String? = nil) -> Data {
    var obj: [String: Any] = ["tab": tab ?? self.tab.uuidString, "event": event]
    if let ppid { obj["ppid"] = ppid }
    return try! JSONSerialization.data(withJSONObject: obj)
  }

  private func event(_ name: String, _ extra: [String: Any] = [:]) -> HookEvent {
    var payload: [String: Any] = [
      "hook_event_name": name, "session_id": "sid-1",
      "transcript_path": "/t/sid-1.jsonl", "cwd": "/p",
    ]
    payload.merge(extra) { $1 }
    return HookEvent.parse(message(payload))!
  }

  func testParsesBridgeMessage() {
    let e = event("SessionStart", ["source": "startup"])
    XCTAssertEqual(e.tabID, tab)
    XCTAssertEqual(e.name, "SessionStart")
    XCTAssertEqual(e.sessionId, "sid-1")
    XCTAssertEqual(e.transcriptPath, "/t/sid-1.jsonl")
    XCTAssertEqual(e.cwd, "/p")
    XCTAssertEqual(e.ppid, 4242)
    XCTAssertEqual(e.source, "startup")
  }

  func testRejectsUnattributableMessages() {
    XCTAssertNil(HookEvent.parse(Data("not json".utf8)))
    XCTAssertNil(
      HookEvent.parse(message(["hook_event_name": "Stop", "session_id": "s"], tab: "nope")))
    XCTAssertNil(HookEvent.parse(message(["session_id": "s"])))
    XCTAssertNil(HookEvent.parse(message(["hook_event_name": "Stop", "session_id": ""])))
  }

  func testPpidHintIsOptionalAndIgnoresInit() {
    let base: [String: Any] = ["hook_event_name": "Stop", "session_id": "s"]
    XCTAssertNil(HookEvent.parse(message(base, ppid: nil))?.ppid)
    XCTAssertNil(HookEvent.parse(message(base, ppid: 0))?.ppid)
    XCTAssertNil(HookEvent.parse(message(base, ppid: 1))?.ppid)
  }

  func testStateTransitions() {
    XCTAssertEqual(event("SessionStart", ["source": "startup"]).stateTransition, .userInput)
    XCTAssertEqual(event("SessionStart", ["source": "resume"]).stateTransition, .userInput)
    XCTAssertNil(event("SessionStart", ["source": "compact"]).stateTransition)
    XCTAssertEqual(event("UserPromptSubmit").stateTransition, .generating)
    XCTAssertEqual(event("PreToolUse").stateTransition, .generating)
    XCTAssertEqual(event("PostToolUse").stateTransition, .generating)
    XCTAssertEqual(event("Stop").stateTransition, .userInput)
    XCTAssertEqual(event("SessionEnd", ["reason": "logout"]).stateTransition, .idle)
    XCTAssertNil(event("SessionEnd", ["reason": "clear"]).stateTransition, "process lives on")
    XCTAssertNil(event("PreCompact").stateTransition)
  }

  func testNotificationTransitions() {
    XCTAssertEqual(
      event("Notification", ["notification_type": "permission_prompt"]).stateTransition,
      .needsAttention)
    XCTAssertEqual(
      event("Notification", ["notification_type": "elicitation_dialog"]).stateTransition,
      .needsAttention)
    XCTAssertEqual(
      event("Notification", ["notification_type": "idle_prompt"]).stateTransition, .userInput)
    XCTAssertNil(event("Notification", ["notification_type": "auth_success"]).stateTransition)
    // Unknown and missing types are treated as a request for the user.
    XCTAssertEqual(
      event("Notification", ["notification_type": "something_new"]).stateTransition,
      .needsAttention)
    XCTAssertEqual(event("Notification").stateTransition, .needsAttention)
  }
}
