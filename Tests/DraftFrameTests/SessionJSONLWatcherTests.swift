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
}
