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

  // MARK: - encodePath

  func testEncodePathBasic() {
    let encoded = SessionJSONLWatcher.encodePath("/Users/foo/project")
    XCTAssertEqual(encoded, "-Users-foo-project")
  }

  func testEncodePathDeep() {
    let encoded = SessionJSONLWatcher.encodePath("/Users/jwatters/code/draftframe")
    XCTAssertEqual(encoded, "-Users-jwatters-code-draftframe")
  }
}
