import XCTest

@testable import DraftFrameKit

final class SessionPersistenceTests: XCTestCase {

  // MARK: - Resume launch command

  func testClaudeLaunchCommandWithResume() {
    let cmd = AgentKind.claude.launchCommand(
      binPath: "/opt/homebrew/bin/claude", modelId: "",
      resumeSessionId: "72edbe87-6e8e-4ef2-b7c2-11b8633c2bef")
    XCTAssertEqual(
      cmd, "/opt/homebrew/bin/claude --resume '72edbe87-6e8e-4ef2-b7c2-11b8633c2bef'")
  }

  func testClaudeLaunchCommandWithResumeAndModel() {
    let cmd = AgentKind.claude.launchCommand(
      binPath: "claude", modelId: "claude-opus-4-8", resumeSessionId: "abc")
    XCTAssertEqual(cmd, "claude --model claude-opus-4-8 --resume 'abc'")
  }

  func testCodexLaunchCommandIgnoresResume() {
    let cmd = AgentKind.codex.launchCommand(
      binPath: "codex", modelId: "", resumeSessionId: "abc")
    XCTAssertEqual(cmd, "codex")
  }

  func testLaunchCommandWithoutResumeUnchanged() {
    let cmd = AgentKind.claude.launchCommand(binPath: "claude", modelId: "")
    XCTAssertEqual(cmd, "claude")
  }

  // MARK: - Session id capture from the transcript

  func testWatcherCapturesSessionIdFromAnyLineType() {
    let watcher = SessionJSONLWatcher(workingDirectory: "/nonexistent") {
      _, _, _, _, _, _, _, _, _ in
    }
    defer { watcher.stop() }
    XCTAssertNil(watcher.agentSessionId)

    // Lines whose type the usage parser ignores still carry the id.
    _ = watcher.parseLine(
      #"{"type":"summary","sessionId":"11111111-2222-3333-4444-555555555555"}"#)
    XCTAssertEqual(watcher.agentSessionId, "11111111-2222-3333-4444-555555555555")

    // A newer line (e.g. after the tailer switches files) replaces it.
    _ = watcher.parseLine(
      #"{"type":"user","sessionId":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","message":{"content":"hi"}}"#
    )
    XCTAssertEqual(watcher.agentSessionId, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")

    // Lines without the field leave the last-seen id in place.
    _ = watcher.parseLine(#"{"type":"user","message":{"content":"hi"}}"#)
    XCTAssertEqual(watcher.agentSessionId, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
  }

  // MARK: - Saved-file format compatibility

  func testDecodesFileWrittenByOlderVersions() throws {
    // Files from before resume support carry neither agentSessionId nor
    // activeSessionIndex; they must still decode.
    let json = """
      {
        "projectDir": "/Users/x/proj",
        "sessions": [
          {"name": "main", "worktreePath": null, "agent": "claude"}
        ]
      }
      """
    let file = try JSONDecoder().decode(
      SessionPersistence.SessionsFile.self, from: Data(json.utf8))
    XCTAssertEqual(file.projectDir, "/Users/x/proj")
    XCTAssertEqual(file.sessions.count, 1)
    XCTAssertNil(file.sessions[0].agentSessionId)
    XCTAssertNil(file.activeSessionIndex)
  }

  func testRoundTripsResumeState() throws {
    let file = SessionPersistence.SessionsFile(
      projectDir: "/p",
      sessions: [
        SessionPersistence.SavedSession(
          name: "feature", worktreePath: "/p/.claude/worktrees/feature",
          agent: "claude", agentSessionId: "abc-123")
      ],
      activeSessionIndex: 0)
    let data = try JSONEncoder().encode(file)
    let decoded = try JSONDecoder().decode(SessionPersistence.SessionsFile.self, from: data)
    XCTAssertEqual(decoded.sessions[0].agentSessionId, "abc-123")
    XCTAssertEqual(decoded.activeSessionIndex, 0)
  }

  func testTranscriptExistsIsFalseForUnknownDirectory() {
    XCTAssertFalse(
      SessionJSONLWatcher.transcriptExists(
        sessionId: "no-such-id", workingDirectory: "/nonexistent/dir/for/tests"))
  }
}
