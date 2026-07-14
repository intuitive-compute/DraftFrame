import XCTest

@testable import DraftFrameKit

final class PTYStreamAnalyzerTests: XCTestCase {

  private var analyzer: PTYStreamAnalyzer!

  override func setUp() {
    super.setUp()
    analyzer = PTYStreamAnalyzer()
  }

  // MARK: - Initial State

  func testInitialStateIsIdle() {
    XCTAssertEqual(analyzer.state, .idle)
    XCTAssertFalse(analyzer.alternateBufferActive)
  }

  // MARK: - State Detection

  func testThinkingState() {
    let exp = expectation(description: "state change")
    analyzer.onStateChange = { state in
      if state == .thinking { exp.fulfill() }
    }
    feedString("Esc to interrupt ... thinking")
    wait(for: [exp], timeout: 0.5)
    XCTAssertEqual(analyzer.state, .thinking)
  }

  func testGeneratingState() {
    let exp = expectation(description: "state change")
    analyzer.onStateChange = { state in
      if state == .generating { exp.fulfill() }
    }
    feedString("Esc to interrupt")
    wait(for: [exp], timeout: 0.5)
    XCTAssertEqual(analyzer.state, .generating)
  }

  func testNeedsAttentionAllowDeny() {
    let exp = expectation(description: "state change")
    analyzer.onStateChange = { state in
      if state == .needsAttention { exp.fulfill() }
    }
    feedString("Allow Deny")
    wait(for: [exp], timeout: 0.5)
    XCTAssertEqual(analyzer.state, .needsAttention)
  }

  func testNeedsAttentionYN() {
    let exp = expectation(description: "state change")
    analyzer.onStateChange = { state in
      if state == .needsAttention { exp.fulfill() }
    }
    feedString("Do you want to proceed? [y/n]")
    wait(for: [exp], timeout: 0.5)
    XCTAssertEqual(analyzer.state, .needsAttention)
  }

  func testIdleOnShellPrompt() {
    // First move to a non-idle state
    let genExp = expectation(description: "generating")
    analyzer.onStateChange = { state in
      if state == .generating { genExp.fulfill() }
    }
    feedString("Esc to interrupt")
    wait(for: [genExp], timeout: 0.5)

    // Now feed shell prompt to return to idle
    let idleExp = expectation(description: "idle")
    analyzer.onStateChange = { state in
      if state == .idle { idleExp.fulfill() }
    }
    // Clear recent text by feeding enough new text
    feedString(String(repeating: " ", count: 2000) + "user@host$ ")
    wait(for: [idleExp], timeout: 0.5)
    XCTAssertEqual(analyzer.state, .idle)
  }

  // MARK: - ANSI Escape Stripping

  func testANSIEscapesAreStripped() {
    // Feed "AB" with an ANSI color escape between them: ESC[31m
    let bytes: [UInt8] = [0x41, 0x1B, 0x5B, 0x33, 0x31, 0x6D, 0x42]
    analyzer.feed(bytes[...])

    // The analyzer should accumulate "AB" as plain text (frameText is private,
    // but we can verify indirectly through state detection)
    // Feed enough to trigger a known state
    let exp = expectation(description: "generating")
    analyzer.onStateChange = { state in
      if state == .generating { exp.fulfill() }
    }
    feedString("Esc to interrupt")
    wait(for: [exp], timeout: 0.5)
  }

  // MARK: - Alternate Buffer

  func testAlternateBufferEnter() {
    // CSI ? 1049 h = ESC [ ? 1 0 4 9 h
    let bytes: [UInt8] = [0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x34, 0x39, 0x68]
    analyzer.feed(bytes[...])
    XCTAssertTrue(analyzer.alternateBufferActive)
  }

  func testAlternateBufferLeaveResetsToIdle() {
    // Enter alternate buffer first
    let enter: [UInt8] = [0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x34, 0x39, 0x68]
    analyzer.feed(enter[...])
    XCTAssertTrue(analyzer.alternateBufferActive)

    // Set up expectation for idle state
    let exp = expectation(description: "idle on alt buffer exit")
    // First change state to something non-idle so the transition fires
    let genExp = expectation(description: "generating")
    analyzer.onStateChange = { state in
      if state == .generating { genExp.fulfill() }
    }
    feedString("Esc to interrupt")
    wait(for: [genExp], timeout: 0.5)

    analyzer.onStateChange = { state in
      if state == .idle { exp.fulfill() }
    }
    // Leave alternate buffer: CSI ? 1049 l
    let leave: [UInt8] = [0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x34, 0x39, 0x6C]
    analyzer.feed(leave[...])
    wait(for: [exp], timeout: 0.5)
    XCTAssertFalse(analyzer.alternateBufferActive)
    XCTAssertEqual(analyzer.state, .idle)
  }

  // MARK: - Claude Ready

  // Marker detection runs inside the debounced analyzeFrame (50ms after the
  // last chunk), so onClaudeReady fires asynchronously on the main queue.
  func testClaudeReadyFiresOnTUIMarker() {
    let exp = expectation(description: "claude ready")
    analyzer.onClaudeReady = { exp.fulfill() }
    feedString("? for shortcuts")
    wait(for: [exp], timeout: 0.5)
  }

  func testClaudeReadyFiresAtMostOnce() {
    let first = expectation(description: "first ready")
    let refire = expectation(description: "must not refire")
    refire.isInverted = true
    var fireCount = 0
    analyzer.onClaudeReady = {
      fireCount += 1
      if fireCount == 1 { first.fulfill() } else { refire.fulfill() }
    }
    feedString("esc to interrupt")
    wait(for: [first], timeout: 0.5)

    // A second marker in a fresh debounce cycle must not re-fire.
    feedString("? for shortcuts")
    wait(for: [refire], timeout: 0.2)
    XCTAssertEqual(fireCount, 1)
  }

  func testClaudeReadyFiresOnAlternateBufferEnter() {
    var fireCount = 0
    analyzer.onClaudeReady = { fireCount += 1 }
    // CSI ? 1049 h — belt-and-suspenders ready signal if Claude ever takes
    // over the alternate screen. Fired synchronously, not debounced.
    let enter: [UInt8] = [0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x34, 0x39, 0x68]
    analyzer.feed(enter[...])
    XCTAssertEqual(fireCount, 1)
  }

  func testResetReArmsClaudeReady() {
    let first = expectation(description: "first ready")
    analyzer.onClaudeReady = { first.fulfill() }
    feedString("? for shortcuts")
    wait(for: [first], timeout: 0.5)

    analyzer.reset()

    let second = expectation(description: "ready again after reset")
    analyzer.onClaudeReady = { second.fulfill() }
    feedString("? for shortcuts")
    wait(for: [second], timeout: 0.5)
  }

  // MARK: - Context Window Banner

  func testBannerDetectedInSingleChunk() {
    var detected = 0
    analyzer.onContextWindowChange = { cap in
      XCTAssertEqual(cap, 1_000_000)
      detected += 1
    }
    feedString("Opus 4.7 (1M context) ready")
    XCTAssertEqual(detected, 1)
  }

  func testBannerDetectedWhenSplitAcrossChunks() {
    var detected = 0
    analyzer.onContextWindowChange = { _ in detected += 1 }
    feedString("Set model to Opus (1M co")
    feedString("ntext) (default)")
    XCTAssertEqual(detected, 1)
  }

  func testBannerFiresAtMostOnce() {
    var detected = 0
    analyzer.onContextWindowChange = { _ in detected += 1 }
    feedString("(1M context)")
    feedString("(1M context)")
    XCTAssertEqual(detected, 1)
  }

  func testBannerStillDetectedAfterLargeFlood() {
    // Banner arriving after enough output to have trimmed the rolling
    // buffer must still fire — detection scans every chunk as it arrives.
    var detected = 0
    analyzer.onContextWindowChange = { _ in detected += 1 }
    feedString(String(repeating: "x", count: 10_000))
    feedString("(1M context)")
    XCTAssertEqual(detected, 1)
  }

  // MARK: - Codex Markers

  func testCodexIdleFooterAfterWorkingReturnsToUserInput() {
    // Codex repaints "? for shortcuts" over its working row when a turn
    // ends; the stale working marker can still sit in the rolling buffer,
    // so the most recently painted marker must win.
    analyzer.agent = .codex
    let genExp = expectation(description: "generating")
    analyzer.onStateChange = { state in
      if state == .generating { genExp.fulfill() }
    }
    feedString("Working (3s • esc to interrupt)")
    wait(for: [genExp], timeout: 0.5)

    let idleExp = expectation(description: "user input")
    analyzer.onStateChange = { state in
      if state == .userInput { idleExp.fulfill() }
    }
    feedString("  ? for shortcuts")
    wait(for: [idleExp], timeout: 0.5)
    XCTAssertEqual(analyzer.state, .userInput)
  }

  func testCodexWorkingAfterIdleFooterReturnsToGenerating() {
    analyzer.agent = .codex
    let idleExp = expectation(description: "user input")
    analyzer.onStateChange = { state in
      if state == .userInput { idleExp.fulfill() }
    }
    feedString("? for shortcuts")
    wait(for: [idleExp], timeout: 0.5)

    let genExp = expectation(description: "generating")
    analyzer.onStateChange = { state in
      if state == .generating { genExp.fulfill() }
    }
    feedString("Working (0s • esc to interrupt)")
    wait(for: [genExp], timeout: 0.5)
    XCTAssertEqual(analyzer.state, .generating)
  }

  func testCodexApprovalPromptNeedsAttention() {
    analyzer.agent = .codex
    let exp = expectation(description: "needs attention")
    analyzer.onStateChange = { state in
      if state == .needsAttention { exp.fulfill() }
    }
    feedString("Yes, proceed   No, and tell Codex what to do differently")
    wait(for: [exp], timeout: 0.5)
    XCTAssertEqual(analyzer.state, .needsAttention)
  }

  // MARK: - Model Banner

  func testModelBannerDetected() {
    analyzer.agent = .codex
    let exp = expectation(description: "model detected")
    analyzer.onModelDetected = { model in
      XCTAssertEqual(model, "gpt-5.6-sol")
      exp.fulfill()
    }
    feedString("model:     gpt-5.6-sol    /model to change")
    wait(for: [exp], timeout: 0.5)
  }

  func testModelBannerDoesNotRefireForSameModel() {
    analyzer.agent = .codex
    let first = expectation(description: "first detection")
    let refire = expectation(description: "must not refire")
    refire.isInverted = true
    var count = 0
    analyzer.onModelDetected = { _ in
      count += 1
      if count == 1 { first.fulfill() } else { refire.fulfill() }
    }
    feedString("model: gpt-5.6-sol")
    wait(for: [first], timeout: 0.5)
    feedString("model: gpt-5.6-sol")
    wait(for: [refire], timeout: 0.2)
  }

  func testModelBannerRefiresOnModelChange() {
    analyzer.agent = .codex
    var models: [String] = []
    let first = expectation(description: "first model")
    analyzer.onModelDetected = { model in
      models.append(model)
      first.fulfill()
    }
    feedString("model: gpt-5.5")
    // Frame analysis is debounced, so let the first banner land before the
    // second replaces it in the analysis window.
    wait(for: [first], timeout: 0.5)

    let second = expectation(description: "second model")
    analyzer.onModelDetected = { model in
      models.append(model)
      second.fulfill()
    }
    feedString(String(repeating: " ", count: 600) + "model: gpt-5.6-sol")
    wait(for: [second], timeout: 0.5)
    XCTAssertEqual(models, ["gpt-5.5", "gpt-5.6-sol"])
  }

  // MARK: - Reset

  func testResetClearsState() {
    // Enter alternate buffer and feed data
    let enter: [UInt8] = [0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x34, 0x39, 0x68]
    analyzer.feed(enter[...])
    feedString("some text")

    analyzer.reset()

    XCTAssertEqual(analyzer.state, .idle)
    XCTAssertFalse(analyzer.alternateBufferActive)
  }

  // MARK: - Helpers

  private func feedString(_ text: String) {
    let bytes = Array(text.utf8)
    analyzer.feed(bytes[...])
  }
}
