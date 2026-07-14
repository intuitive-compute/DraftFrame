import XCTest

@testable import DraftFrameKit

final class CodexUsageWatcherTests: XCTestCase {

  private func makeWatcher() -> CodexUsageWatcher {
    // Point at a working directory no rollout's cwd can match so the watcher
    // never attaches to a real file; we feed lines via parseLine directly.
    CodexUsageWatcher(workingDirectory: "/nonexistent/\(UUID().uuidString)") {
      _, _, _, _, _, _, _, _, _ in
    }
  }

  private func tokenCountLine(
    input: Int, cached: Int, output: Int,
    lastInput: Int = 0, contextWindow: Int? = nil
  ) -> String {
    let window = contextWindow.map { ",\"model_context_window\":\($0)" } ?? ""
    return """
      {"timestamp":"2026-07-07T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count",\
      "info":{"total_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),\
      "output_tokens":\(output),"reasoning_output_tokens":0,"total_tokens":\(input + output)},\
      "last_token_usage":{"input_tokens":\(lastInput),"cached_input_tokens":0,\
      "output_tokens":0,"reasoning_output_tokens":0,"total_tokens":\(lastInput)}\(window)},\
      "rate_limits":null}}
      """
  }

  private func turnContextLine(model: String) -> String {
    """
    {"timestamp":"2026-07-07T10:00:00.000Z","type":"turn_context","payload":{"cwd":"/tmp",\
    "approval_policy":"on-request","sandbox_policy":{"mode":"workspace-write"},\
    "model":"\(model)","summary":"auto"}}
    """
  }

  // MARK: - token_count

  func testTokenCountTotalsAreCumulativeNotSummed() {
    let watcher = makeWatcher()
    XCTAssertTrue(watcher.parseLine(tokenCountLine(input: 1_000, cached: 0, output: 100)))
    XCTAssertTrue(watcher.parseLine(tokenCountLine(input: 3_000, cached: 500, output: 400)))

    // total_token_usage is already cumulative — the latest event wins.
    XCTAssertEqual(watcher.totalTokensIn, 3_000)
    XCTAssertEqual(watcher.totalTokensOut, 400)
  }

  func testCostUsesCachedInputPricing() {
    let watcher = makeWatcher()
    XCTAssertTrue(watcher.parseLine(turnContextLine(model: "gpt-5.5")))
    XCTAssertTrue(
      watcher.parseLine(tokenCountLine(input: 1_000_000, cached: 400_000, output: 100_000)))

    // gpt-5.5: $5/M input, $0.50/M cached input, $30/M output.
    // 600k non-cached * 5 + 400k cached * 0.5 + 100k out * 30 (per 1M).
    let expected =
      600_000 * 5.0 / 1_000_000 + 400_000 * 0.5 / 1_000_000
      + 100_000 * 30.0 / 1_000_000
    XCTAssertEqual(watcher.totalCost, expected, accuracy: 1e-9)
  }

  func testPricingMatchesLongestPrefixForDatedIds() {
    let watcher = makeWatcher()
    XCTAssertTrue(watcher.parseLine(turnContextLine(model: "gpt-5.4-mini-2026-05-01")))
    XCTAssertTrue(watcher.parseLine(tokenCountLine(input: 1_000_000, cached: 0, output: 0)))

    // gpt-5.4-mini rates ($0.75/M input), not gpt-5.4 ($2.50/M).
    XCTAssertEqual(watcher.totalCost, 0.75, accuracy: 1e-9)
  }

  func testSyntheticZeroUsageEventIgnored() {
    let watcher = makeWatcher()
    XCTAssertTrue(watcher.parseLine(tokenCountLine(input: 2_000, cached: 0, output: 200)))
    // Codex writes all-zero usage (only total_tokens set) when it marks the
    // context window full — it must not zero the figures.
    XCTAssertFalse(watcher.parseLine(tokenCountLine(input: 0, cached: 0, output: 0)))

    XCTAssertEqual(watcher.totalTokensIn, 2_000)
    XCTAssertEqual(watcher.totalTokensOut, 200)
  }

  func testRegressingTotalsIgnored() {
    let watcher = makeWatcher()
    XCTAssertTrue(watcher.parseLine(tokenCountLine(input: 5_000, cached: 0, output: 500)))
    // Cumulative totals never shrink; a smaller event is malformed noise.
    XCTAssertFalse(watcher.parseLine(tokenCountLine(input: 1_000, cached: 0, output: 100)))

    XCTAssertEqual(watcher.totalTokensIn, 5_000)
  }

  func testNullInfoIgnored() {
    let watcher = makeWatcher()
    let line = """
      {"timestamp":"2026-07-07T10:00:00.000Z","type":"event_msg",\
      "payload":{"type":"token_count","info":null,"rate_limits":{}}}
      """
    XCTAssertFalse(watcher.parseLine(line))
    XCTAssertEqual(watcher.totalTokensIn, 0)
  }

  func testContextTokensAndWindowFromTokenCount() {
    let watcher = makeWatcher()
    XCTAssertTrue(
      watcher.parseLine(
        tokenCountLine(
          input: 10_000, cached: 0, output: 1_000, lastInput: 42_000, contextWindow: 272_000)))

    XCTAssertEqual(watcher.currentContextTokens, 42_000)
    XCTAssertEqual(watcher.parsedMaxContextTokens, 272_000)
  }

  // MARK: - agent_message

  func testAgentMessageCapturedForSummary() {
    let watcher = makeWatcher()
    let line = """
      {"timestamp":"2026-07-07T10:00:00.000Z","type":"event_msg",\
      "payload":{"type":"agent_message","message":"All tests pass.","phase":null}}
      """
    XCTAssertTrue(watcher.parseLine(line))
    XCTAssertEqual(watcher.latestAssistantText, "All tests pass.")
    XCTAssertNotNil(watcher.latestAssistantAt)
  }

  func testBlankAgentMessageIgnored() {
    let watcher = makeWatcher()
    let line = """
      {"timestamp":"2026-07-07T10:00:00.000Z","type":"event_msg",\
      "payload":{"type":"agent_message","message":"  \\n"}}
      """
    XCTAssertFalse(watcher.parseLine(line))
    XCTAssertNil(watcher.latestAssistantText)
  }

  // MARK: - Turn lifecycle → session state

  func testTurnLifecycleEventsDriveState() {
    let watcher = makeWatcher()

    func event(_ type: String) -> String {
      """
      {"timestamp":"2026-07-07T10:00:00.000Z","type":"event_msg","payload":{"type":"\(type)"}}
      """
    }

    XCTAssertNil(watcher.latestTurnState)
    _ = watcher.parseLine(event("turn_started"))
    XCTAssertEqual(watcher.latestTurnState, .generating)
    _ = watcher.parseLine(event("turn_complete"))
    XCTAssertEqual(watcher.latestTurnState, .userInput)
    _ = watcher.parseLine(event("turn_started"))
    _ = watcher.parseLine(event("turn_aborted"))
    XCTAssertEqual(watcher.latestTurnState, .userInput)
    // Older codex versions used task_* names.
    _ = watcher.parseLine(event("task_started"))
    XCTAssertEqual(watcher.latestTurnState, .generating)
  }

  func testModelIsEmptyUntilFirstTurnContext() {
    let watcher = makeWatcher()
    // The session keeps its banner/preference model until the rollout
    // names one, so the watcher must not invent a default.
    XCTAssertEqual(watcher.latestModel, "")
    XCTAssertTrue(watcher.parseLine(turnContextLine(model: "gpt-5.6-sol")))
    XCTAssertEqual(watcher.latestModel, "gpt-5.6-sol")
  }

  // MARK: - turn_context

  func testTurnContextUpdatesModel() {
    let watcher = makeWatcher()
    XCTAssertTrue(watcher.parseLine(turnContextLine(model: "gpt-5.3-codex")))
    XCTAssertEqual(watcher.latestModel, "gpt-5.3-codex")
    // Same model again is not an update.
    XCTAssertFalse(watcher.parseLine(turnContextLine(model: "gpt-5.3-codex")))
  }

  // MARK: - Discovery + streaming

  func testDiscoversRolloutByCwdAndStreamsTokens() throws {
    let fm = FileManager.default
    let root = NSTemporaryDirectory() + "codex-sessions-\(UUID().uuidString)"
    let dayDir = root + "/2026/07/07"
    try fm.createDirectory(atPath: dayDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: root) }

    let cwd = "/tmp/project-\(UUID().uuidString)"

    func metaLine(cwd: String) -> String {
      """
      {"timestamp":"2026-07-07T10:00:00.000Z","type":"session_meta",\
      "payload":{"id":"abc","cwd":"\(cwd)","originator":"codex_cli_rs","cli_version":"0.142.5"}}
      """
    }

    // A newer rollout for a DIFFERENT cwd must not be picked up.
    let other = dayDir + "/rollout-2026-07-07T11-00-00-other.jsonl"
    try
      (metaLine(cwd: "/somewhere/else") + "\n" + tokenCountLine(input: 9, cached: 0, output: 9)
      + "\n")
      .write(toFile: other, atomically: true, encoding: .utf8)

    let mine = dayDir + "/rollout-2026-07-07T10-00-00-mine.jsonl"
    try (metaLine(cwd: cwd) + "\n" + tokenCountLine(input: 3_000, cached: 0, output: 400) + "\n")
      .write(toFile: mine, atomically: true, encoding: .utf8)

    let exp = expectation(description: "usage update from matching rollout")
    exp.assertForOverFulfill = false
    let watcher = CodexUsageWatcher(workingDirectory: cwd, sessionsRoot: root) {
      _, tokensIn, tokensOut, _, _, _, _, _, _ in
      XCTAssertEqual(tokensIn, 3_000)
      XCTAssertEqual(tokensOut, 400)
      exp.fulfill()
    }
    wait(for: [exp], timeout: 3.0)
    watcher.stop()
  }

  // MARK: - Unrelated lines

  func testUnrelatedLinesIgnored() {
    let watcher = makeWatcher()
    XCTAssertFalse(
      watcher.parseLine(
        """
        {"timestamp":"2026-07-07T10:00:00.000Z","type":"session_meta",\
        "payload":{"id":"abc","cwd":"/tmp","originator":"codex_cli_rs"}}
        """))
    XCTAssertFalse(
      watcher.parseLine(
        """
        {"timestamp":"2026-07-07T10:00:00.000Z","type":"response_item",\
        "payload":{"type":"message","role":"assistant","content":[]}}
        """))
    XCTAssertFalse(watcher.parseLine("not json"))
  }
}
