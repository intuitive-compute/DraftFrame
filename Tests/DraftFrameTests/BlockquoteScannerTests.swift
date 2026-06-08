import SwiftTerm
import XCTest

@testable import DraftFrameKit

final class BlockquoteScannerTests: XCTestCase {

  // MARK: - quoteContent

  func testQuoteContentStripsBarAndSpaces() {
    XCTAssertEqual(BlockquoteScanner.quoteContent(of: "▎ hello"), "hello")
    XCTAssertEqual(BlockquoteScanner.quoteContent(of: "▎hello"), "hello")
    XCTAssertEqual(BlockquoteScanner.quoteContent(of: "  ▎ indented bar"), "indented bar")
  }

  func testQuoteContentStripsNestedBars() {
    XCTAssertEqual(BlockquoteScanner.quoteContent(of: "▎ ▎ ▎ deep"), "deep")
  }

  func testLeadingNulCellsBeforeBarAreSkipped() {
    // SwiftTerm returns NUL for unwritten indent cells; the bar must still match.
    XCTAssertEqual(BlockquoteScanner.quoteContent(of: "\u{0}\u{0}▎ quoted"), "quoted")
    XCTAssertEqual(BlockquoteScanner.quoteContent(of: "\u{0} ▎ ▎ nested"), "nested")
    XCTAssertEqual(BlockquoteScanner.quoteContent(of: "▎ trailing nul\u{0}\u{0}"), "trailing nul")
    // A row that's only NUL/space is not a quote.
    XCTAssertNil(BlockquoteScanner.quoteContent(of: "\u{0}\u{0}\u{0}"))
  }

  func testBarOnlyRowIsEmptyContentNotNil() {
    XCTAssertEqual(BlockquoteScanner.quoteContent(of: "▎"), "")
    XCTAssertEqual(BlockquoteScanner.quoteContent(of: "▎  "), "")
  }

  func testNonQuoteAndBlankRowsReturnNil() {
    XCTAssertNil(BlockquoteScanner.quoteContent(of: "plain prose"))
    XCTAssertNil(BlockquoteScanner.quoteContent(of: "   "))
    XCTAssertNil(BlockquoteScanner.quoteContent(of: ""))
    XCTAssertNil(BlockquoteScanner.quoteContent(of: nil))
  }

  func testBoxDrawingVerticalIsNotAQuote() {
    // The input box / tool frames use │ (U+2502) — must not read as a blockquote.
    XCTAssertNil(BlockquoteScanner.quoteContent(of: "│ inside a box border"))
    XCTAssertNil(BlockquoteScanner.quoteContent(of: "┃ heavy box border"))
  }

  // MARK: - block(in:at:)

  func testSingleRowBlock() {
    let lines: [String?] = ["prose", "▎ stands alone", "more prose"]
    let block = BlockquoteScanner.block(in: lines, at: 1)
    XCTAssertEqual(block?.range, 1...1)
    XCTAssertEqual(block?.text, "stands alone")
  }

  func testMultiRowBlockJoinsWithNewlines() {
    let lines: [String?] = ["x", "▎ first", "▎ second", "▎ third", "y"]
    let block = BlockquoteScanner.block(in: lines, at: 2)
    XCTAssertEqual(block?.range, 1...3)
    XCTAssertEqual(block?.text, "first\nsecond\nthird")
  }

  func testProbesNeighbourWhenRowMappingIsOffByOne() {
    // Pixel→row drift: the pointer maps one row above/below a single-row block.
    let lines: [String?] = ["prose", "▎ only line", "prose"]
    XCTAssertEqual(BlockquoteScanner.block(in: lines, at: 0)?.text, "only line")
    XCTAssertEqual(BlockquoteScanner.block(in: lines, at: 2)?.text, "only line")
  }

  func testInternalBlankQuotedLinePreservedTrailingTrimmed() {
    let lines: [String?] = ["▎ para one", "▎", "▎ para two", "▎"]
    let block = BlockquoteScanner.block(in: lines, at: 0)
    XCTAssertEqual(block?.range, 0...3)
    XCTAssertEqual(block?.text, "para one\n\npara two")
  }

  func testProseReturnsNil() {
    let lines: [String?] = ["nothing", "here", "is quoted"]
    XCTAssertNil(BlockquoteScanner.block(in: lines, at: 1))
  }

  func testTwoBlocksSeparatedByProseStayDistinct() {
    let lines: [String?] = ["▎ upper", "prose between", "▎ lower"]
    XCTAssertEqual(BlockquoteScanner.block(in: lines, at: 0)?.text, "upper")
    XCTAssertEqual(BlockquoteScanner.block(in: lines, at: 2)?.text, "lower")
  }

  // MARK: - allBlocks

  func testAllBlocksFindsEveryBlockInOrder() {
    let lines: [String?] = [
      "intro prose",
      "▎ block one only line",
      "between prose",
      "▎ block two first",
      "▎ block two second",
      "trailing prose",
      "▎ block three",
    ]
    let blocks = BlockquoteScanner.allBlocks(in: lines)
    XCTAssertEqual(blocks.count, 3)
    XCTAssertEqual(blocks[0].range, 1...1)
    XCTAssertEqual(blocks[0].text, "block one only line")
    XCTAssertEqual(blocks[1].range, 3...4)
    XCTAssertEqual(blocks[1].text, "block two first\nblock two second")
    XCTAssertEqual(blocks[2].range, 6...6)
    XCTAssertEqual(blocks[2].text, "block three")
  }

  func testAllBlocksSeparatedByBlankRowStayDistinct() {
    let lines: [String?] = ["▎ upper", "", "▎ lower"]
    let blocks = BlockquoteScanner.allBlocks(in: lines)
    XCTAssertEqual(blocks.count, 2)
    XCTAssertEqual(blocks[0].text, "upper")
    XCTAssertEqual(blocks[1].text, "lower")
  }

  func testAllBlocksEmptyWhenNoQuotes() {
    XCTAssertTrue(BlockquoteScanner.allBlocks(in: ["a", "b", nil, "c"]).isEmpty)
  }

  // MARK: - End-to-end through a real SwiftTerm buffer

  func testScrapesBarGlyphsFromLiveTerminalBuffer() {
    let delegate = StubDelegate()
    let terminal = Terminal(delegate: delegate)
    terminal.resize(cols: 40, rows: 24)
    terminal.feed(text: "▎ quoted line one\r\n▎ quoted line two\r\n")

    let lines = (0..<terminal.rows).map {
      terminal.getLine(row: $0)?.translateToString(trimRight: true)
    }
    let block = BlockquoteScanner.block(in: lines, at: 0)
    XCTAssertEqual(
      block?.text, "quoted line one\nquoted line two",
      "Bar glyph must survive translateToString and be stripped. Got: \(String(describing: block?.text))")
  }

  private final class StubDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
  }
}
