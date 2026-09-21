import XCTest

@testable import DraftFrameKit

final class SubagentScannerTests: XCTestCase {

  private func line(_ obj: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: obj)
    return String(data: data, encoding: .utf8)!
  }

  private func user(_ text: String, ts: String, meta: Bool = false) -> String {
    var obj: [String: Any] = [
      "type": "user", "timestamp": ts, "agentId": "abc",
      "message": ["role": "user", "content": text],
    ]
    if meta { obj["isMeta"] = true }
    return line(obj)
  }

  private func assistant(
    id: String, ts: String, model: String = "claude-opus-5", toolUse: Bool,
    input: Int = 100, output: Int = 50, cacheRead: Int = 0, requestId: String = "r1",
    attribution: (String, String)? = ("general-purpose", "code-review")
  ) -> String {
    var content: [[String: Any]] = [["type": "text", "text": "hi"]]
    if toolUse { content.append(["type": "tool_use", "id": "t1", "name": "Bash", "input": [:]]) }
    var obj: [String: Any] = [
      "type": "assistant", "timestamp": ts, "agentId": "abc", "requestId": requestId,
      "message": [
        "id": id, "role": "assistant", "model": model, "content": content,
        "usage": [
          "input_tokens": input, "output_tokens": output,
          "cache_creation_input_tokens": 0, "cache_read_input_tokens": cacheRead,
        ],
      ],
    ]
    if let (agent, skill) = attribution {
      obj["attributionAgent"] = agent
      obj["attributionSkill"] = skill
    }
    return line(obj)
  }

  private let path = "/tmp/x/subagents/agent-a0efeeb6a9c655add.jsonl"

  func testParsesCompletedAgent() {
    let transcript = [
      user(
        "You are a code-review finder (angle: cross-file tracer). Repo: /r\nMore.",
        ts: "2026-09-14T18:36:51.132Z"),
      assistant(id: "m1", ts: "2026-09-14T18:36:54.036Z", toolUse: true),
      // Same message id repeated on a second content-block line: counted once.
      assistant(id: "m1", ts: "2026-09-14T18:36:54.100Z", toolUse: true),
      user("tool result", ts: "2026-09-14T18:37:00.000Z"),
      assistant(
        id: "m2", ts: "2026-09-14T18:41:37.923Z", toolUse: false, input: 10, output: 20,
        cacheRead: 1000, requestId: "r2"),
    ].joined(separator: "\n")

    let now = SubagentScanner.parseTimestamp("2026-09-14T20:00:00.000Z")!
    let record = SubagentScanner.parse(transcript: transcript, path: path, now: now)!

    XCTAssertEqual(record.agentID, "a0efeeb6a9c655add")
    XCTAssertEqual(record.agentType, "general-purpose")
    XCTAssertEqual(record.skill, "code-review")
    XCTAssertEqual(record.model, "opus")
    XCTAssertEqual(
      record.promptSummary, "You are a code-review finder (angle: cross-file tracer). Repo: /r")
    XCTAssertEqual(record.status, .completed, "last record is a text-only assistant turn")
    XCTAssertEqual(record.turns, 2)
    XCTAssertEqual(record.tokensIn, 100 + 10 + 1000)
    XCTAssertEqual(record.tokensOut, 70)
    XCTAssertEqual(
      record.lastActivityAt.timeIntervalSince(record.startedAt), 286.791, accuracy: 0.01)

    // opus: $5/M in, $25/M out, cache read at 0.1x in.
    let expected = 110 * 5e-6 + 70 * 25e-6 + 1000 * 0.5e-6
    XCTAssertEqual(record.cost, expected, accuracy: 1e-9)
  }

  func testRunningVersusStoppedDependsOnRecency() {
    let transcript = [
      user("Prompt", ts: "2026-09-14T18:36:51.000Z"),
      assistant(id: "m1", ts: "2026-09-14T18:37:00.000Z", toolUse: true),
    ].joined(separator: "\n")

    let soon = SubagentScanner.parseTimestamp("2026-09-14T18:37:30.000Z")!
    XCTAssertEqual(
      SubagentScanner.parse(transcript: transcript, path: path, now: soon)?.status, .running)

    let later = SubagentScanner.parseTimestamp("2026-09-14T18:40:00.000Z")!
    XCTAssertEqual(
      SubagentScanner.parse(transcript: transcript, path: path, now: later)?.status, .stopped)
  }

  func testSkipsMetaUserMessagesForPromptAndToleratesMissingAttribution() {
    let transcript = [
      user(
        "<system-reminder>ignored</system-reminder>", ts: "2026-09-14T18:36:50.000Z", meta: true),
      user("Real prompt line", ts: "2026-09-14T18:36:51.000Z"),
      assistant(id: "m1", ts: "2026-09-14T18:36:52.000Z", toolUse: false, attribution: nil),
    ].joined(separator: "\n")
    let record = SubagentScanner.parse(transcript: transcript, path: path)!
    XCTAssertEqual(record.promptSummary, "Real prompt line")
    XCTAssertNil(record.agentType)
    XCTAssertNil(record.skill)
    XCTAssertEqual(record.displayTitle, "agent")
  }

  func testMetaPromptIsUsedWhenNoOrdinaryUserMessageExists() {
    let transcript = [
      user("`medium effort` fork brief", ts: "2026-09-14T18:36:51.000Z", meta: true),
      assistant(id: "m1", ts: "2026-09-14T18:36:52.000Z", toolUse: false),
    ].joined(separator: "\n")
    let record = SubagentScanner.parse(transcript: transcript, path: path)!
    XCTAssertEqual(record.promptSummary, "`medium effort` fork brief")
  }

  func testEmptyOrGarbageTranscriptYieldsNil() {
    XCTAssertNil(SubagentScanner.parse(transcript: "", path: path))
    XCTAssertNil(SubagentScanner.parse(transcript: "not json\n{also not", path: path))
  }

  func testSummarizeTruncates() {
    let long = String(repeating: "x", count: 200)
    XCTAssertEqual(SubagentScanner.summarize(prompt: "\n\n  " + long, limit: 20).count, 20)
    XCTAssertTrue(SubagentScanner.summarize(prompt: long, limit: 20).hasSuffix("…"))
  }

  func testScanDirectoryOrdersByStart() throws {
    let dir = NSTemporaryDirectory() + "df-subagents-\(UUID().uuidString)/subagents"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(atPath: (dir as NSString).deletingLastPathComponent)
    }

    let late = user("late", ts: "2026-09-14T19:00:00.000Z")
    let early = user("early", ts: "2026-09-14T18:00:00.000Z")
    try late.write(toFile: dir + "/agent-bbb.jsonl", atomically: true, encoding: .utf8)
    try early.write(toFile: dir + "/agent-aaa.jsonl", atomically: true, encoding: .utf8)
    try "ignored".write(toFile: dir + "/notes.txt", atomically: true, encoding: .utf8)

    let records = SubagentScanner.scan(dir: dir)
    XCTAssertEqual(records.map(\.agentID), ["aaa", "bbb"])
    XCTAssertEqual(records.map(\.promptSummary), ["early", "late"])
  }
}
