import XCTest

@testable import DraftFrameKit

final class SessionJSONLWatcherTests: XCTestCase {

  // MARK: - shortModelName

  func testShortModelNameOpus() {
    XCTAssertEqual(SessionJSONLWatcher.shortModelName("claude-opus-4-6-20250514"), "opus")
  }

  func testShortModelNameSonnet() {
    XCTAssertEqual(SessionJSONLWatcher.shortModelName("claude-sonnet-4-20250514"), "sonnet")
  }

  func testShortModelNameHaiku() {
    XCTAssertEqual(SessionJSONLWatcher.shortModelName("claude-haiku-3-5-20250514"), "haiku")
  }

  func testShortModelNameUnknown() {
    XCTAssertEqual(SessionJSONLWatcher.shortModelName("some-other-model"), "some-other-model")
  }

  func testShortModelNameCaseInsensitive() {
    XCTAssertEqual(SessionJSONLWatcher.shortModelName("Claude-OPUS-4"), "opus")
  }

  func testShortModelNameFable() {
    XCTAssertEqual(SessionJSONLWatcher.shortModelName("claude-fable-5"), "fable")
  }

  // MARK: - contextWindowCap

  func testContextWindowCapOneMillionFamilies() {
    XCTAssertEqual(SessionJSONLWatcher.contextWindowCap(forModelId: "claude-fable-5"), 1_000_000)
    XCTAssertEqual(SessionJSONLWatcher.contextWindowCap(forModelId: "claude-opus-4-8"), 1_000_000)
    XCTAssertEqual(SessionJSONLWatcher.contextWindowCap(forModelId: "claude-opus-4-7"), 1_000_000)
    XCTAssertEqual(SessionJSONLWatcher.contextWindowCap(forModelId: "claude-opus-4-6"), 1_000_000)
    XCTAssertEqual(SessionJSONLWatcher.contextWindowCap(forModelId: "claude-sonnet-4-6"), 1_000_000)
  }

  func testContextWindowCapStripsDateSuffix() {
    XCTAssertEqual(
      SessionJSONLWatcher.contextWindowCap(forModelId: "claude-opus-4-8-20260301"), 1_000_000)
  }

  func testContextWindowCapDefaultsTo200K() {
    XCTAssertEqual(
      SessionJSONLWatcher.contextWindowCap(forModelId: "claude-haiku-4-5-20251001"), 200_000)
    XCTAssertEqual(SessionJSONLWatcher.contextWindowCap(forModelId: "claude-sonnet-4-5"), 200_000)
  }

  func testContextWindowCapHonorsOneMSuffix() {
    XCTAssertEqual(
      SessionJSONLWatcher.contextWindowCap(forModelId: "claude-haiku-4-5[1m]"), 1_000_000)
  }

  // MARK: - encodePath

  func testEncodePathBasic() {
    let encoded = SessionJSONLWatcher.encodePath("/Users/foo/project")
    XCTAssertEqual(encoded, "-Users-foo-project")
  }

  func testEncodePathDeep() {
    let encoded = SessionJSONLWatcher.encodePath("/Users/jwatters/code/draftframe")
    XCTAssertEqual(encoded, "-Users-jwatters-code-draftframe")
  }

  func testEncodePathReplacesDotsLikeClaudeCode() {
    // Worktree sessions live under `.../.claude/worktrees/<name>`. Claude Code
    // maps every non-alphanumeric character to `-`, so `/.claude` becomes
    // `--claude` (a double dash). A `/`-only encoding would yield `-.claude`
    // and the watcher would never find the transcript.
    let encoded = SessionJSONLWatcher.encodePath(
      "/Users/joseph/calm/calm-mosaic/.claude/worktrees/focus-area-agent")
    XCTAssertEqual(
      encoded, "-Users-joseph-calm-calm-mosaic--claude-worktrees-focus-area-agent")
  }

  // MARK: - extractText

  func testExtractTextFromPlainString() {
    XCTAssertEqual(SessionJSONLWatcher.extractText(from: "hello"), "hello")
  }

  func testExtractTextFromStringTrimsWhitespace() {
    XCTAssertEqual(SessionJSONLWatcher.extractText(from: "  hello\n"), "hello")
  }

  func testExtractTextFromBlockArray() {
    let content: [[String: Any]] = [
      ["type": "text", "text": "first"],
      ["type": "text", "text": "second"],
    ]
    XCTAssertEqual(SessionJSONLWatcher.extractText(from: content), "first\nsecond")
  }

  func testExtractTextSkipsNonTextBlocks() {
    let content: [[String: Any]] = [
      ["type": "tool_use", "id": "abc", "name": "Read"],
      ["type": "text", "text": "only this"],
      ["type": "tool_result", "tool_use_id": "abc"],
    ]
    XCTAssertEqual(SessionJSONLWatcher.extractText(from: content), "only this")
  }

  func testExtractTextReturnsNilForEmptyArray() {
    XCTAssertNil(SessionJSONLWatcher.extractText(from: [] as [[String: Any]]))
  }

  func testExtractTextReturnsNilWhenOnlyToolBlocks() {
    let content: [[String: Any]] = [
      ["type": "tool_use", "id": "abc", "name": "Bash"]
    ]
    XCTAssertNil(SessionJSONLWatcher.extractText(from: content))
  }

  func testExtractTextReturnsNilForUnsupportedType() {
    XCTAssertNil(SessionJSONLWatcher.extractText(from: 42))
    XCTAssertNil(SessionJSONLWatcher.extractText(from: nil))
  }

  // MARK: - Usage dedup

  private func makeWatcher() -> SessionJSONLWatcher {
    // Point at a directory with no ~/.claude/projects mirror so the watcher
    // never attaches to a real file; we feed lines via parseLine directly.
    SessionJSONLWatcher(workingDirectory: "/nonexistent/\(UUID().uuidString)") {
      _, _, _, _, _, _, _, _, _ in
    }
  }

  private func assistantLine(
    messageID: String, requestID: String = "req_1", inputTokens: Int = 100, outputTokens: Int = 10
  ) -> String {
    return """
      {"type":"assistant","requestId":"\(requestID)","message":{"id":"\(messageID)",\
      "model":"claude-sonnet-4-6","usage":{"input_tokens":\(inputTokens),\
      "output_tokens":\(outputTokens),"cache_creation_input_tokens":0,\
      "cache_read_input_tokens":0}}}
      """
  }

  func testUsageCountedOncePerMessage() {
    let watcher = makeWatcher()
    // One API response written as three lines (text + tool_use blocks share
    // the message id and an identical usage block).
    XCTAssertTrue(watcher.parseLine(assistantLine(messageID: "msg_a")))
    XCTAssertTrue(watcher.parseLine(assistantLine(messageID: "msg_a")))
    XCTAssertTrue(watcher.parseLine(assistantLine(messageID: "msg_a")))

    XCTAssertEqual(watcher.totalTokensIn, 100)
    XCTAssertEqual(watcher.totalTokensOut, 10)
    // Sonnet: 100 in * $3/M + 10 out * $15/M
    let expected = 100 * 3.0 / 1_000_000 + 10 * 15.0 / 1_000_000
    XCTAssertEqual(watcher.totalCost, expected, accuracy: 1e-12)
    // With no session switch, the lifetime totals track the current run.
    XCTAssertEqual(watcher.lifetimeTokensIn, 100)
    XCTAssertEqual(watcher.lifetimeTokensOut, 10)
    XCTAssertEqual(watcher.lifetimeCost, expected, accuracy: 1e-12)
  }

  func testDistinctMessagesBothCounted() {
    let watcher = makeWatcher()
    XCTAssertTrue(watcher.parseLine(assistantLine(messageID: "msg_a")))
    XCTAssertTrue(watcher.parseLine(assistantLine(messageID: "msg_b", requestID: "req_2")))

    XCTAssertEqual(watcher.totalTokensIn, 200)
    XCTAssertEqual(watcher.totalTokensOut, 20)
  }

  func testSameMessageIDDifferentRequestCountedSeparately() {
    // A retried request re-sends with a new requestId; treat it as billable.
    let watcher = makeWatcher()
    XCTAssertTrue(watcher.parseLine(assistantLine(messageID: "msg_a", requestID: "req_1")))
    XCTAssertTrue(watcher.parseLine(assistantLine(messageID: "msg_a", requestID: "req_2")))

    XCTAssertEqual(watcher.totalTokensIn, 200)
  }

  func testMissingMessageIDStillCounted() {
    let watcher = makeWatcher()
    let line = """
      {"type":"assistant","message":{"model":"claude-sonnet-4-6",\
      "usage":{"input_tokens":50,"output_tokens":5}}}
      """
    XCTAssertTrue(watcher.parseLine(line))
    XCTAssertTrue(watcher.parseLine(line))
    // No id to dedupe on — both lines accumulate (pre-existing behavior).
    XCTAssertEqual(watcher.totalTokensIn, 100)
  }

  func testDuplicateLineStillUpdatesContextAndText() {
    let watcher = makeWatcher()
    let first = """
      {"type":"assistant","requestId":"req_1","message":{"id":"msg_a",\
      "model":"claude-sonnet-4-6","content":[{"type":"tool_use","id":"t1","name":"Bash"}],\
      "usage":{"input_tokens":100,"output_tokens":10,"cache_creation_input_tokens":0,\
      "cache_read_input_tokens":0}}}
      """
    let second = """
      {"type":"assistant","requestId":"req_1","message":{"id":"msg_a",\
      "model":"claude-sonnet-4-6","content":[{"type":"text","text":"done"}],\
      "usage":{"input_tokens":100,"output_tokens":10,"cache_creation_input_tokens":0,\
      "cache_read_input_tokens":0}}}
      """
    XCTAssertTrue(watcher.parseLine(first))
    XCTAssertTrue(watcher.parseLine(second))

    // Usage counted once, but the text block on the duplicate line is kept.
    XCTAssertEqual(watcher.totalTokensIn, 100)
    XCTAssertEqual(watcher.latestAssistantText, "done")
  }
}
