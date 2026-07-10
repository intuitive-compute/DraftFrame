import XCTest

@testable import DraftFrameKit
@testable import SwiftTerm

/// Cmd+click hit-testing: the local event monitor consumes any click it can't
/// match, so its pixel-to-grid math must agree exactly with SwiftTerm's, or
/// clicks on links resolve against the wrong line and die.
final class LinkClickTests: XCTestCase {

  /// A frame deliberately not a multiple of the cell size, leaving leftover
  /// padding that the old bounds-based math smeared across all cells.
  private func makeView() -> ClaudeTerminalView {
    let tv = ClaudeTerminalView(frame: NSRect(x: 0, y: 0, width: 643.0, height: 411.0))
    let term = tv.getTerminal()
    var feed = ""
    for r in 0..<term.rows {
      if r > 0 { feed += "\r\n" }
      feed += "row\(r)"
    }
    term.feed(text: feed)
    return tv
  }

  /// Every cell center must map to the same grid cell SwiftTerm's own
  /// calculateMouseHit produces (verified via the per-row marker text).
  func testLineAndColumnMatchesSwiftTermHitTesting() {
    let tv = makeView()
    let term = tv.getTerminal()
    let optimal = tv.getOptimalFrameSize()
    let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
    let cellWidth = (optimal.width - scroller) / CGFloat(term.cols)
    let cellHeight = optimal.height / CGFloat(term.rows)

    var checked = 0
    for row in 0..<term.rows {
      for col in 0..<min(term.cols, 6) {
        let point = CGPoint(
          x: (CGFloat(col) + 0.5) * cellWidth,
          y: tv.bounds.height - (CGFloat(row) + 0.5) * cellHeight)
        guard tv.bounds.contains(point) else { continue }

        let oracle = tv.calculateMouseHit(at: point).grid
        guard let (text, gotCol) = tv.lineAndColumn(atLocal: point) else {
          XCTFail("lineAndColumn returned nil at row \(row) col \(col)")
          continue
        }
        XCTAssertEqual(gotCol, oracle.col, "col mismatch at row \(row) col \(col)")
        XCTAssertEqual(
          text, "row\(oracle.row)",
          "row mismatch at row \(row): SwiftTerm hit row \(oracle.row), got line |\(text)|")
        checked += 1
      }
    }
    XCTAssertGreaterThan(checked, 50, "test exercised too few cells to be meaningful")
  }

  /// The deferral path hands scheme URLs to SwiftTerm, so its implicit link
  /// detection must keep matching the URLs Claude Code prints.
  final class Dummy: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
  }

  func testSwiftTermImplicitMatchPlainURL() {
    let term = Terminal(delegate: Dummy(), options: TerminalOptions(cols: 120, rows: 30))
    term.feed(text: "https://github.com/intuitive-compute/DraftFrame")
    let match = term.linkMatch(at: .buffer(Position(col: 10, row: 0)), mode: .explicitAndImplicit)
    XCTAssertEqual(match?.text, "https://github.com/intuitive-compute/DraftFrame")
  }

  func testSwiftTermImplicitMatchInsideTUIBox() {
    let term = Terminal(delegate: Dummy(), options: TerminalOptions(cols: 120, rows: 30))
    term.feed(text: "\u{1b}[?1049h")
    term.feed(
      text: "\u{2502} See https://github.com/intuitive-compute/DraftFrame for details \u{2502}")
    let match = term.linkMatch(at: .buffer(Position(col: 20, row: 0)), mode: .explicitAndImplicit)
    XCTAssertEqual(match?.text, "https://github.com/intuitive-compute/DraftFrame")
  }

  /// Cmd+click now opens literal URLs directly rather than deferring to
  /// SwiftTerm's hover-gated handler, so the token cleaner must recover the
  /// real URL from the wrappers and prose punctuation around it.
  func testCleanedURLToken() {
    let url = "https://github.com/intuitive-compute/DraftFrame"
    XCTAssertEqual(ClaudeTerminalView.cleanedURLToken(url), url)
    XCTAssertEqual(ClaudeTerminalView.cleanedURLToken("(\(url))"), url)
    XCTAssertEqual(ClaudeTerminalView.cleanedURLToken("\(url)."), url)
    XCTAssertEqual(ClaudeTerminalView.cleanedURLToken("<\(url)>,"), url)
    // A close-paren whose opener is part of the URL is preserved.
    let paren = "https://en.wikipedia.org/wiki/Foo_(bar)"
    XCTAssertEqual(ClaudeTerminalView.cleanedURLToken(paren), paren)
    XCTAssertNil(ClaudeTerminalView.cleanedURLToken("(((("))
  }
}
