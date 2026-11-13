import XCTest

@testable import DraftFrameKit

final class ReplyQuoteTests: XCTestCase {

  // MARK: - Formatting

  func testSingleLineIsPrefixedAndFollowedByBlankLine() {
    XCTAssertEqual(ReplyQuote.format("this line is wrong"), "> this line is wrong\n\n")
  }

  func testEveryLineIsPrefixed() {
    XCTAssertEqual(
      ReplyQuote.format("first\nsecond\nthird"), "> first\n> second\n> third\n\n")
  }

  func testBlankLineInsideQuoteKeepsTheQuoteOpen() {
    XCTAssertEqual(ReplyQuote.format("para one\n\npara two"), "> para one\n>\n> para two\n\n")
  }

  func testSurroundingBlankLinesAndTrailingSpacesAreDropped() {
    XCTAssertEqual(ReplyQuote.format("\n  \nkeep   \n  indented\n\n"), "> keep\n>   indented\n\n")
  }

  func testNothingToQuoteReturnsNil() {
    XCTAssertNil(ReplyQuote.format(""))
    XCTAssertNil(ReplyQuote.format("  \n\t\n "))
  }

  func testControlCharactersAreStripped() {
    // An ESC in the quote could close the bracketed paste early.
    XCTAssertEqual(ReplyQuote.format("a\u{1b}[201~b\r\nc\u{0}d"), "> a[201~b\n> cd\n\n")
  }

  // MARK: - Truncation

  func testTextAtTheLimitIsNotTruncated() {
    let text = String(repeating: "x", count: ReplyQuote.defaultLimit)
    XCTAssertEqual(ReplyQuote.format(text), "> " + text + "\n\n")
  }

  func testTextOverTheLimitIsCutAndMarked() {
    let text = String(repeating: "x", count: ReplyQuote.defaultLimit + 500)
    let kept = String(repeating: "x", count: ReplyQuote.defaultLimit)
    XCTAssertEqual(ReplyQuote.format(text), "> " + kept + ReplyQuote.truncationMarker + "\n\n")
  }

  func testTruncationAcrossLinesKeepsEveryLineQuoted() {
    let quote = ReplyQuote.format("abcd\nefgh\nijkl", limit: 7)
    // 7 characters: "abcd", the newline, "ef".
    XCTAssertEqual(quote, "> abcd\n> ef" + ReplyQuote.truncationMarker + "\n\n")
  }

  func testTruncationDoesNotLeaveADanglingBlankLine() {
    // The cut lands just after a newline; the marker joins the last real line.
    XCTAssertEqual(
      ReplyQuote.format("abcd\nefgh", limit: 5), "> abcd" + ReplyQuote.truncationMarker + "\n\n")
  }

  // MARK: - Shared selection helper

  /// A paragraph Claude Code wrapped at 30 columns behind a two-space gutter.
  private let wrappedSelection = [
    "  The quick brown fox jumps over",
    "  the lazy dog and keeps running",
    "  until it is done.",
  ].joined(separator: "\n")

  private var screen: [String?] { wrappedSelection.components(separatedBy: "\n") }

  func testSharedHelperMatchesCopyPipeline() {
    let viaHelper = LogicalLineJoiner.logicalText(fromSelection: wrappedSelection, columns: 40) {
      screen
    }
    let viaCopySteps = LogicalLineJoiner.stripCommonIndent(
      LogicalLineJoiner.join(wrappedSelection, columns: 40, screenRows: screen))
    XCTAssertEqual(viaHelper, viaCopySteps)
    XCTAssertEqual(
      viaHelper, "The quick brown fox jumps over the lazy dog and keeps running until it is done.")
  }

  func testSharedHelperSkipsScreenScanForSingleRow() {
    let text = LogicalLineJoiner.logicalText(fromSelection: "    one row", columns: 40) {
      XCTFail("screen rows should not be read for a single-row selection")
      return []
    }
    XCTAssertEqual(text, "one row")
  }

  func testReplyQuotesExactlyTheTextCopyProduces() {
    let copied = LogicalLineJoiner.logicalText(fromSelection: wrappedSelection, columns: 40) {
      screen
    }
    XCTAssertEqual(ReplyQuote.format(copied), "> " + copied + "\n\n")
  }
}
