import XCTest

@testable import DraftFrameKit

final class SmokeTests: XCTestCase {

  func testSessionStateRawValues() {
    XCTAssertEqual(SessionState.generating.rawValue, "generating")
    XCTAssertEqual(SessionState.thinking.rawValue, "thinking")
    XCTAssertEqual(SessionState.userInput.rawValue, "userInput")
    XCTAssertEqual(SessionState.idle.rawValue, "idle")
    XCTAssertEqual(SessionState.needsAttention.rawValue, "needsAttention")
  }

  func testSessionStateLabels() {
    XCTAssertFalse(SessionState.generating.label.isEmpty)
    XCTAssertFalse(SessionState.thinking.label.isEmpty)
    XCTAssertFalse(SessionState.idle.label.isEmpty)
  }

  func testSessionStateColors() {
    // Verify colors are non-nil (they come from Theme constants)
    XCTAssertNotNil(SessionState.generating.color)
    XCTAssertNotNil(SessionState.thinking.color)
    XCTAssertNotNil(SessionState.idle.color)
    XCTAssertNotNil(SessionState.needsAttention.color)
    XCTAssertNotNil(SessionState.userInput.color)
  }
}
