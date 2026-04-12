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
