import XCTest

@testable import DraftFrameKit

/// How a tab reacts to hook events: binding, rebinding across session ids,
/// release on SessionEnd, and the precedence over the pid-file watcher.
@MainActor
final class SessionHookBindingTests: XCTestCase {

  private func event(
    _ name: String, tab: UUID, sessionId: String = "sid-1", ppid: Int32? = nil,
    transcript: String? = "/t/sid-1.jsonl", extra: [String: Any] = [:]
  ) -> HookEvent {
    var payload: [String: Any] = ["hook_event_name": name, "session_id": sessionId]
    if let transcript { payload["transcript_path"] = transcript }
    payload.merge(extra) { $1 }
    var obj: [String: Any] = ["tab": tab.uuidString, "event": payload]
    if let ppid { obj["ppid"] = Int(ppid) }
    return HookEvent.parse(try! JSONSerialization.data(withJSONObject: obj))!
  }

  func testFirstEventBindsAndDrivesState() {
    let s = Session(name: "a", agent: .claude)
    XCTAssertFalse(s.isHookDriven)
    XCTAssertNil(s.agentSessionId)

    s.applyHookEvent(event("SessionStart", tab: s.id, extra: ["source": "startup"]))
    XCTAssertTrue(s.isHookDriven)
    XCTAssertEqual(s.state, .userInput)
    XCTAssertEqual(s.agentSessionId, "sid-1")
    XCTAssertEqual(s.hookBinding?.transcriptPath, "/t/sid-1.jsonl")

    s.applyHookEvent(event("UserPromptSubmit", tab: s.id))
    XCTAssertEqual(s.state, .generating)
    s.applyHookEvent(
      event("Notification", tab: s.id, extra: ["notification_type": "permission_prompt"]))
    XCTAssertEqual(s.state, .needsAttention)
    s.applyHookEvent(event("PostToolUse", tab: s.id))
    XCTAssertEqual(s.state, .generating, "tool activity clears an answered prompt")
    s.applyHookEvent(event("Stop", tab: s.id))
    XCTAssertEqual(s.state, .userInput)
  }

  func testHookSessionIdOutranksResumeId() {
    let s = Session(name: "a", agent: .claude)
    s.resumedFromSessionId = "old"
    XCTAssertEqual(s.agentSessionId, "old")
    s.applyHookEvent(event("SessionStart", tab: s.id, sessionId: "new"))
    XCTAssertEqual(s.agentSessionId, "new")
  }

  func testSessionEndReleasesBindingButKeepsId() {
    let s = Session(name: "a", agent: .claude)
    s.applyHookEvent(event("SessionStart", tab: s.id))
    s.applyHookEvent(event("SessionEnd", tab: s.id, extra: ["reason": "logout"]))
    XCTAssertFalse(s.isHookDriven)
    XCTAssertEqual(s.state, .idle)
    XCTAssertEqual(s.agentSessionId, "sid-1", "persistence can still resume it")
  }

  func testSessionEndForUnknownSessionIsIgnored() {
    let s = Session(name: "a", agent: .claude)
    s.applyHookEvent(event("SessionStart", tab: s.id, sessionId: "live"))
    s.applyHookEvent(event("UserPromptSubmit", tab: s.id, sessionId: "live"))
    // A stale SessionEnd from a previous conversation must not idle the tab.
    s.applyHookEvent(event("SessionEnd", tab: s.id, sessionId: "stale"))
    XCTAssertTrue(s.isHookDriven)
    XCTAssertEqual(s.state, .generating)
    XCTAssertEqual(s.agentSessionId, "live")
  }

  func testNewSessionIdInSameTabRebinds() {
    let s = Session(name: "a", agent: .claude)
    s.applyHookEvent(event("SessionStart", tab: s.id, sessionId: "first"))
    // `/clear` or a fork: Claude Code continues under a new id.
    s.applyHookEvent(
      event(
        "SessionStart", tab: s.id, sessionId: "second", transcript: "/t/second.jsonl",
        extra: ["source": "clear"]))
    XCTAssertEqual(s.agentSessionId, "second")
    XCTAssertEqual(s.hookBinding?.transcriptPath, "/t/second.jsonl")
  }

  func testPidTrustedOnlyAfterTwoAgreeingEvents() {
    let s = Session(name: "a", agent: .claude)
    s.applyHookEvent(event("SessionStart", tab: s.id, ppid: 999_999))
    XCTAssertNil(s.hookBinding?.trustedPid)
    s.applyHookEvent(event("UserPromptSubmit", tab: s.id, ppid: 999_999))
    XCTAssertEqual(s.hookBinding?.trustedPid, 999_999)
    // A different parent resets the count (an interposed shell, say).
    s.applyHookEvent(event("Stop", tab: s.id, ppid: 999_998))
    XCTAssertNil(s.hookBinding?.trustedPid)
  }

  func testSweepReleasesWhenTrustedPidIsDead() {
    let s = Session(name: "a", agent: .claude)
    // Our own pid is alive: the sweep must leave the binding alone.
    s.applyHookEvent(event("SessionStart", tab: s.id, ppid: getpid()))
    s.applyHookEvent(event("UserPromptSubmit", tab: s.id, ppid: getpid()))
    s.sweepHookProcess()
    XCTAssertTrue(s.isHookDriven)
    XCTAssertEqual(s.state, .generating)

    // A pid that cannot exist: the sweep reports the process gone.
    let dead = Session(name: "b", agent: .claude)
    dead.applyHookEvent(event("SessionStart", tab: dead.id, ppid: Int32.max - 1))
    dead.applyHookEvent(event("UserPromptSubmit", tab: dead.id, ppid: Int32.max - 1))
    dead.sweepHookProcess()
    XCTAssertFalse(dead.isHookDriven)
    XCTAssertEqual(dead.state, .idle)
  }

  func testClearDoesNotIdleTheTab() {
    let s = Session(name: "a", agent: .claude)
    s.applyHookEvent(event("SessionStart", tab: s.id, sessionId: "first"))
    s.applyHookEvent(event("UserPromptSubmit", tab: s.id, sessionId: "first"))
    // `/clear` fires SessionEnd(clear) and then SessionStart(clear) under a
    // new id. The process never exits, so the tab must not flash to idle.
    s.applyHookEvent(event("SessionEnd", tab: s.id, sessionId: "first", extra: ["reason": "clear"]))
    XCTAssertTrue(s.isHookDriven)
    XCTAssertEqual(s.state, .generating)
    s.applyHookEvent(
      event("SessionStart", tab: s.id, sessionId: "second", extra: ["source": "clear"]))
    XCTAssertEqual(s.agentSessionId, "second")
    XCTAssertEqual(s.state, .userInput)
  }

  func testRegistryCanEndATurnButNotStartOne() {
    let s = Session(name: "a", agent: .claude)
    s.applyHookEvent(event("SessionStart", tab: s.id))
    s.applyHookEvent(event("UserPromptSubmit", tab: s.id))
    // Esc interrupt: no Stop fires, but the pid file flips to idle.
    s.applyRegistryState(.userInput)
    XCTAssertEqual(s.state, .userInput)
    XCTAssertTrue(s.isHookDriven)
    // The registry may not claim activity or a prompt; hooks report those.
    s.applyRegistryState(.generating)
    XCTAssertEqual(s.state, .userInput)
    s.applyRegistryState(.needsAttention)
    XCTAssertEqual(s.state, .userInput)
    // Nor may it demote a permission prompt hooks reported.
    s.applyHookEvent(
      event("Notification", tab: s.id, extra: ["notification_type": "permission_prompt"]))
    s.applyRegistryState(.userInput)
    XCTAssertEqual(s.state, .needsAttention)
  }

  func testRegistryIdleReleasesOnlyWithoutTrustedPid() {
    let s = Session(name: "a", agent: .claude)
    s.applyHookEvent(event("SessionStart", tab: s.id, ppid: getpid()))
    s.applyRegistryState(.idle)
    XCTAssertFalse(s.isHookDriven, "no trusted pid yet: registry verdict stands")
    XCTAssertEqual(s.state, .idle)

    let t = Session(name: "b", agent: .claude)
    t.applyHookEvent(event("SessionStart", tab: t.id, ppid: getpid()))
    t.applyHookEvent(event("UserPromptSubmit", tab: t.id, ppid: getpid()))
    t.applyRegistryState(.idle)
    XCTAssertTrue(t.isHookDriven, "trusted pid: the sweep decides, not the cwd scan")
    XCTAssertEqual(t.state, .generating)
  }

  func testCodexSessionsIgnoreHookEvents() {
    let s = Session(name: "c", agent: .codex)
    s.applyHookEvent(event("UserPromptSubmit", tab: s.id))
    XCTAssertFalse(s.isHookDriven)
    XCTAssertEqual(s.state, .idle)
  }

  func testPinnedTranscriptResolvesOnlyOnceWritten() throws {
    let dir = NSTemporaryDirectory() + "df-pin-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let watcher = SessionJSONLWatcher(workingDirectory: dir + "/no-such-project") {
      _, _, _, _, _, _, _, _, _ in
    }
    defer { watcher.stop() }
    XCTAssertNil(watcher.resolveTranscriptPath(), "no project folder, nothing to guess")

    let pinned = dir + "/sid.jsonl"
    watcher.pinnedTranscriptPath = pinned
    XCTAssertNil(watcher.resolveTranscriptPath(), "pinned but Claude hasn't written it yet")
    FileManager.default.createFile(atPath: pinned, contents: Data())
    XCTAssertEqual(watcher.resolveTranscriptPath(), pinned)
    XCTAssertTrue(watcher.captureSessionIds)
  }
}
