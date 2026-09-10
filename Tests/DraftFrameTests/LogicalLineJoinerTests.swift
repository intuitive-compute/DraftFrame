import XCTest

@testable import DraftFrameKit

final class LogicalLineJoinerTests: XCTestCase {

  /// Wrap column of a 60-column terminal once Claude Code's right margin is
  /// taken off. Every fixture below is laid out against this width.
  private let wrap = 58

  /// Replay Ink's layout (`wrap-ansi`, `hard: true`) for one logical line:
  /// word-wrap into rows no wider than `width`, splitting a word inside only
  /// when the word alone is wider than the width. Each row is prefixed with
  /// `indent` spaces (the first with `firstIndent`), so the rows end at the
  /// same absolute column Ink would have used.
  private func inkRows(_ text: String, width: Int, firstIndent: String, indent: String) -> [String]
  {
    var rows: [String] = [""]
    func available(_ rowIndex: Int) -> Int {
      width - (rowIndex == 0 ? firstIndent.count : indent.count)
    }
    for word in text.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
      var word = word
      var current = rows[rows.count - 1]
      let cols = available(rows.count - 1)
      if !current.isEmpty {
        if current.count + 1 + word.count <= cols {
          rows[rows.count - 1] = current + " " + word
          continue
        }
        if word.count <= cols {
          rows.append(word)
          continue
        }
        // Hard split: fill the rest of this row, then whole rows.
        let room = cols - current.count - 1
        if room > 0 {
          rows[rows.count - 1] = current + " " + word.prefix(room)
          word = String(word.dropFirst(room))
        }
        rows.append("")
        current = ""
      }
      while word.count > available(rows.count - 1) {
        let cols = available(rows.count - 1)
        rows[rows.count - 1] = String(word.prefix(cols))
        word = String(word.dropFirst(cols))
        rows.append("")
      }
      rows[rows.count - 1] = word
    }
    return rows.enumerated().map { ($0 == 0 ? firstIndent : indent) + $1 }
  }

  /// Join as `copy(_:)` would on a 60-column terminal whose screen estimate
  /// resolved to `wrap`.
  private func join(_ rows: [String], screenWrapColumn: Int? = 58, firstRowWidth: Int? = nil)
    -> String
  {
    LogicalLineJoiner.join(
      rows.joined(separator: "\n"), columns: 60, screenWrapColumn: screenWrapColumn,
      firstRowWidth: firstRowWidth)
  }

  // MARK: - Wrapped commands

  func testWordWrappedCommandJoinsWithSpace() {
    let command =
      "git commit --no-verify -m 'refactor the wrapper' && git push origin HEAD --force-with-lease"
    let rows = inkRows(command, width: wrap, firstIndent: "⏺ Bash(", indent: "      ")
    XCTAssertGreaterThan(rows.count, 1, "fixture must wrap")
    XCTAssertEqual(join(rows), "⏺ Bash(" + command)
  }

  func testFlagOnContinuationRowIsNotABullet() {
    // Continuation rows beginning with "--flag" must not read as "- item".
    let rows = [
      "  npm run build -- --configuration production --output-dir",
      "  --no-cache dist",
    ]
    XCTAssertEqual(rows[0].count, wrap)
    XCTAssertEqual(
      join(rows),
      "  npm run build -- --configuration production --output-dir --no-cache dist")
  }

  func testHardSplitTokenJoinsWithoutSeparator() {
    // The URL is split at the row edge (joined with nothing); its remainder
    // then ends short of the edge, so the following "-o" word-wraps (joined
    // with a space). Note the remainder must not fill its row exactly: if it
    // did, "remainder | -o" would be indistinguishable by width from a single
    // split token, and no heuristic can tell those apart.
    let url = "https://example.com/" + String(repeating: "a", count: 60) + "/bbb.tar.gz"
    let command = "curl -fsSL \(url) -o out.tgz"
    let rows = inkRows(command, width: wrap, firstIndent: "  ", indent: "  ")
    XCTAssertEqual(rows.count, 3, "fixture must hard-split the URL once, then word-wrap")
    XCTAssertEqual(rows[0].count, wrap)
    XCTAssertLessThan(rows[1].count, wrap)
    XCTAssertEqual(join(rows), "  " + command)
  }

  func testSoftWrappedRowAlreadyJoinedBySwiftTermIsLeftAlone() {
    // A row wider than the wrap column can only come from SwiftTerm joining
    // terminal-wrapped rows; it is never the head of an Ink wrap.
    let long = String(repeating: "x", count: wrap + 10)
    XCTAssertEqual(join([long, "next"]), long + "\nnext")
  }

  // MARK: - Prose and structure

  func testParagraphJoinsAndBlankLineSeparatesParagraphs() {
    let p1 =
      "Terminals draw text into a fixed grid of cells, so any line longer than the grid is wrapped."
    let p2 = "Some programs wrap the text themselves before it ever reaches the terminal."
    let rows =
      inkRows(p1, width: wrap, firstIndent: "  ", indent: "  ") + [""]
      + inkRows(p2, width: wrap, firstIndent: "  ", indent: "  ")
    XCTAssertEqual(join(rows), "  " + p1 + "\n\n  " + p2)
  }

  func testShortLinesWithSameIndentStaySeparate() {
    let rows = ["  Here is the plan:", "  First, look at the tests."]
    XCTAssertEqual(join(rows), rows.joined(separator: "\n"))
  }

  func testListItemsStaySeparateButWrappedItemJoins() {
    let item1 = "Read the buffer line by line and note which rows carry the wrapped flag"
    let rows =
      inkRows(item1, width: wrap, firstIndent: "  - ", indent: "    ")
      + ["  - Short second item", "  1. Numbered item", "  2. Another one", "  • Bulleted"]
    XCTAssertGreaterThan(rows.count, 5)
    XCTAssertEqual(
      join(rows),
      "  - " + item1 + "\n  - Short second item\n  1. Numbered item\n  2. Another one\n  • Bulleted"
    )
  }

  func testIndentDecreaseBreaksLine() {
    let rows = [
      "      " + String(repeating: "word ", count: 9).trimmingCharacters(in: .whitespaces),
      "  " + String(repeating: "w", count: 40),
    ]
    XCTAssertEqual(join(rows), rows.joined(separator: "\n"))
  }

  func testToolCallRowsStaySeparate() {
    let rows = [
      "⏺ Bash(git status --short && git log --oneline -3 && git diff",
      "  ⎿  M Sources/App.swift",
      "     M Tests/AppTests.swift",
    ]
    // "⎿" opens a result row; the last row is shallower-indented than the
    // one above only relative to the glyph, so it stays a distinct row too.
    XCTAssertEqual(join(rows), rows.joined(separator: "\n"))
  }

  func testBoxDrawingRowsNeverJoin() {
    let rows = [
      "╭" + String(repeating: "─", count: wrap - 2) + "╮",
      "│ > some prompt text                                      │",
      "╰" + String(repeating: "─", count: wrap - 2) + "╯",
    ]
    XCTAssertEqual(join(rows), rows.joined(separator: "\n"))
  }

  func testNarrowSelectionWithNoScreenEstimateLeavesTextUntouched() {
    // Two independent lines that would satisfy the width test against their
    // own widest row must not join: without a plausible wrap column (>= 60%
    // of the terminal width) there is no wrap information to act on.
    let rows = ["  Here is the plan for today:", "  First, look at the tests"]
    XCTAssertEqual(join(rows, screenWrapColumn: nil), rows.joined(separator: "\n"))
  }

  func testWrappedCommandJoinsFromSelectionWidthAloneWhenScreenIsChrome() {
    // Scrolled back to the bottom before Cmd+C: the screen offers no
    // estimate, but the selection's own full row does.
    let command =
      "git commit --no-verify -m 'refactor the wrapper' && git push origin HEAD --force-with-lease"
    let rows = inkRows(command, width: wrap, firstIndent: "⏺ Bash(", indent: "      ")
    XCTAssertEqual(join(rows, screenWrapColumn: nil), "⏺ Bash(" + command)
  }

  // MARK: - Review scenarios

  func testHardSplitInsideIndentedBlockUsesBlockTextWidth() {
    // Ink splits a word when it exceeds the block's text width (wrap minus the
    // continuation indent), not the full wrap column. A 55-char URL in a
    // "⏺ Bash(" block (51 columns of text) is split; the seam must close.
    let url = "https://x.io/" + String(repeating: "a", count: 42)
    XCTAssertEqual(url.count, 55)
    let head = "⏺ Bash(curl -fsSL "
    let a = head + String(url.prefix(wrap - head.count))
    let b = "      " + String(url.dropFirst(wrap - head.count)) + " -o out"
    XCTAssertEqual(a.count, wrap)
    XCTAssertEqual(join([a, b]), head + url + " -o out")
  }

  func testRedirectOnContinuationRowStillJoins() {
    let rows = [
      "⏺ Bash(make build 2>&1 | tee build.log && cat build.log &&",
      "      > /dev/null || exit 1",
    ]
    XCTAssertEqual(
      join(rows),
      "⏺ Bash(make build 2>&1 | tee build.log && cat build.log && > /dev/null || exit 1")
  }

  func testTrailingSpacesOnHeadRowCollapseToOneSeparator() {
    let a = "  git commit -m 'x' && git push origin main --force-with  "
    let rows = [a, "  lease"]
    XCTAssertEqual(join(rows), "  git commit -m 'x' && git push origin main --force-with lease")
  }

  func testSelectionStartingMidRowUsesFullRowWidth() {
    let command =
      "git commit --no-verify -m 'refactor the wrapper' && git push origin HEAD --force-with-lease"
    let rows = inkRows(command, width: wrap, firstIndent: "⏺ Bash(", indent: "      ")
    // The drag began at the "g" of "git": SwiftTerm hands us only the tail
    // of the first row.
    var partial = rows
    partial[0] = String(rows[0].dropFirst("⏺ Bash(".count))
    XCTAssertEqual(join(partial, firstRowWidth: rows[0].count), command)
    // The screen-driven entry point recovers that width itself.
    let screen: [String?] = ["  header"] + rows.map { Optional($0) } + [nil]
    XCTAssertEqual(
      LogicalLineJoiner.join(partial.joined(separator: "\n"), columns: 60, screenRows: screen),
      command)
  }

  func testFullRowWidthRequiresWordBoundary() {
    let rows: [String?] = ["  foo ls -la", "  something else"]
    XCTAssertEqual(LogicalLineJoiner.fullRowWidth(endingWith: "ls -la", in: rows), 12)
    XCTAssertNil(LogicalLineJoiner.fullRowWidth(endingWith: "s -la", in: rows))
    XCTAssertNil(LogicalLineJoiner.fullRowWidth(endingWith: "  foo ls -la", in: rows))
  }

  func testWrapColumnIgnoresInputBoxRowWithText() {
    let screen: [String?] = [
      "  " + String(repeating: "t", count: wrap - 2),
      "│ > Try \"fix the bug\"" + String(repeating: " ", count: 60 - 22) + "│",
      "╭" + String(repeating: "─", count: 58) + "╮",
    ]
    XCTAssertEqual(LogicalLineJoiner.wrapColumn(forScreenRows: screen), wrap)
  }

  // MARK: - Wrap column estimate

  func testWrapColumnIgnoresBorderRowsAndTakesWidestTextRow() {
    let border = String(repeating: "─", count: 60)
    let screen: [String?] = [
      "  Some short text",
      "  " + String(repeating: "t", count: wrap - 2),
      border,
      "> ",
      nil,
    ]
    XCTAssertEqual(LogicalLineJoiner.wrapColumn(forScreenRows: screen), wrap)
  }

  func testWrapColumnIsNilForEmptyScreen() {
    XCTAssertNil(LogicalLineJoiner.wrapColumn(forScreenRows: [nil, "", "> "]))
  }

  func testDisplayWidthCountsWideGlyphsAsTwo() {
    XCTAssertEqual(LogicalLineJoiner.displayWidth("abc"), 3)
    XCTAssertEqual(LogicalLineJoiner.displayWidth("日本"), 4)
    XCTAssertEqual(LogicalLineJoiner.displayWidth("e\u{301}"), 1)
    // Emoji-presentation scalars outside the pictograph block, and transport
    // symbols, are two columns to Ink's string-width as well.
    XCTAssertEqual(LogicalLineJoiner.displayWidth("🚀✅⚡🙂日"), 10)
  }
}
