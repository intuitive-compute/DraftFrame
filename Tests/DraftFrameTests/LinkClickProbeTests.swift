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

  /// Ink positions the cursor past the left margin instead of writing spaces,
  /// leaving never-written cells that SwiftTerm renders as literal NULs. Those
  /// must read back as spaces or they glue into the token under the click and
  /// break scheme detection (and truncate NSLog output while debugging it).
  func testLineTextNormalizesNulCells() {
    let tv = ClaudeTerminalView(frame: NSRect(x: 0, y: 0, width: 643.0, height: 411.0))
    let term = tv.getTerminal()
    // Cursor-forward creates NUL cells before the URL; trailing spaces are
    // painted for real, as Ink does when clearing to the row edge.
    term.feed(text: "\u{1b}[4Chttps://github.com/migueldeicaza/SwiftTerm    ")

    let optimal = tv.getOptimalFrameSize()
    let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
    let cellWidth = (optimal.width - scroller) / CGFloat(term.cols)
    let cellHeight = optimal.height / CGFloat(term.rows)
    let point = CGPoint(x: 10.5 * cellWidth, y: tv.bounds.height - 0.5 * cellHeight)

    guard let (text, col) = tv.lineAndColumn(atLocal: point) else {
      return XCTFail("lineAndColumn returned nil")
    }
    XCTAssertEqual(text, "    https://github.com/migueldeicaza/SwiftTerm")
    XCTAssertFalse(text.contains("\u{0}"), "NUL cells must map to spaces")
    // The token under the click is the bare URL, not NUL-glued garbage.
    let token = ClaudeTerminalView.tokenAtClick(in: text, col: col)
    XCTAssertEqual(token, "https://github.com/migueldeicaza/SwiftTerm")
  }

  // MARK: - Wrap-group stitching

  /// Split `text` into hard-wrapped rows of width `cols`, the way Claude
  /// Code's TUI renders a long URL.
  private func hardWrap(_ text: String, cols: Int) -> [String] {
    var rows: [String] = []
    var rest = Substring(text)
    while !rest.isEmpty {
      rows.append(String(rest.prefix(cols)))
      rest = rest.dropFirst(cols)
    }
    return rows
  }

  /// The URL from the field report: spans three hard-wrapped rows, and
  /// SwiftTerm's own stitcher truncated it at the second row boundary.
  func testStitchedWebURLThreeRowWrap() {
    let url =
      "https://github.com/search?q=repo%3Amigueldeicaza%2FSwiftTerm+buildGhosttyImplicitLineMap"
      + "+OR+linkMatch+language%3ASwift&type=code&ref=advsearch&utm_source=draftframe-linkwrap"
      + "-test&utm_campaign=soft-wrap-verification"
    let rows = hardWrap(url, cols: 94)
    XCTAssertEqual(rows.count, 3, "test URL must span three rows to cover the broken case")

    // A click on any row of the group must resolve the complete URL.
    for (i, row) in rows.enumerated() {
      let got = ClaudeTerminalView.stitchedWebURL(rows: rows, clickedIndex: i, col: row.count / 2)
      XCTAssertEqual(got?.absoluteString, url, "row \(i) resolved a wrong or truncated URL")
    }
  }

  /// A single unwrapped row still resolves (degenerate one-row group), and
  /// leading prose on that row doesn't leak into the URL.
  func testStitchedWebURLSingleRow() {
    let url = "https://github.com/migueldeicaza/SwiftTerm"
    let row = "See \(url) for details"
    let got = ClaudeTerminalView.stitchedWebURL(rows: [row], clickedIndex: 0, col: 10)
    XCTAssertEqual(got?.absoluteString, url)
    // Click on the prose, not the URL: no match.
    XCTAssertNil(ClaudeTerminalView.stitchedWebURL(rows: [row], clickedIndex: 0, col: 1))
  }

  /// Clicking a schemeless token in a stitched group must not resolve — the
  /// stitcher only handles web URLs; file paths keep their own resolver.
  func testStitchedWebURLRejectsSchemelessToken() {
    let rows = ["Sources/DraftFrameKit/ClaudeTerminalView.swift:493"]
    XCTAssertNil(ClaudeTerminalView.stitchedWebURL(rows: rows, clickedIndex: 0, col: 5))
  }

  /// The shape Claude Code's TUI actually renders: the URL wraps inside a
  /// padded content box, so every row carries a left indent that is
  /// re-emitted on the continuation rows and must be dropped when joining.
  func testStitchedWebURLIndentedWrapGroup() {
    let url =
      "https://github.com/search?q=repo%3Amigueldeicaza%2FSwiftTerm+buildGhosttyImplicitLineMap"
      + "+OR+linkMatch+language%3ASwift&type=code&ref=advsearch&utm_source=draftframe-linkwrap"
      + "-test&utm_campaign=soft-wrap-verification"
    let indent = "    "
    let segments = hardWrap(url, cols: 90)
    XCTAssertEqual(segments.count, 3)
    let rows = segments.map { indent + $0 }

    for (i, row) in rows.enumerated() {
      let got = ClaudeTerminalView.stitchedWebURL(rows: rows, clickedIndex: i, col: row.count / 2)
      XCTAssertEqual(got?.absoluteString, url, "row \(i) resolved a wrong or truncated URL")
    }
    // A click inside the re-emitted indent of a continuation row is a
    // click on whitespace, not on the URL.
    XCTAssertNil(ClaudeTerminalView.stitchedWebURL(rows: rows, clickedIndex: 1, col: 2))
  }

  /// A full-width prose row above the URL joins the group (it reaches the
  /// right edge), but whitespace token boundaries keep the URL intact unless
  /// the seam directly concatenates a word onto the scheme.
  func testStitchedWebURLProseRowAboveDoesNotCorrupt() {
    let url = "https://github.com/migueldeicaza/SwiftTerm"
    let rows = ["word ends with space ", url]
    let got = ClaudeTerminalView.stitchedWebURL(rows: rows, clickedIndex: 1, col: 10)
    XCTAssertEqual(got?.absoluteString, url)
  }
}
