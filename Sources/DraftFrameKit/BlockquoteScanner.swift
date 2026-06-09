import Foundation

/// Detects markdown blockquotes by their *rendered* form in the terminal.
///
/// Claude Code draws a blockquote as a left bar glyph on every quoted row (the
/// raw `>` markers never reach the screen). Sourcing the copy text from the
/// visible buffer — rather than the JSONL session log — keeps the feature
/// working no matter how far the conversation has moved on or scrolled, since
/// the JSONL only ever retains the single latest assistant message.
enum BlockquoteScanner {
  /// Left block-element glyphs Claude Code uses for the quote bar. Box-drawing
  /// verticals (`│`/`┃`) are deliberately excluded so the input box and
  /// tool-call frames — which use those — never read as blockquotes.
  static let barGlyphs: Set<Character> = ["▏", "▎", "▍", "▌", "▋", "▊", "▉"]

  /// Leading characters that carry no content: spaces, tabs, and NUL. SwiftTerm
  /// returns NUL (U+0000) for cells Claude Code hasn't written — a blockquote's
  /// indent often arrives as NUL cells before the bar glyph rather than spaces,
  /// so we must skip those too or the bar is never found.
  private static func isSkippable(_ c: Character) -> Bool {
    c == " " || c == "\t" || c == "\u{0}"
  }

  /// The quoted content of a rendered row: leading skippable cells and bar
  /// glyphs (including the repeated bars of a nested quote) stripped. Nil when
  /// `line` is blank or doesn't begin with a bar glyph. A bar-only row gives "".
  static func quoteContent(of line: String?) -> String? {
    guard let line else { return nil }
    guard let firstSignificant = line.first(where: { !isSkippable($0) }) else { return nil }
    guard barGlyphs.contains(firstSignificant) else { return nil }
    var content = String(line.drop(while: { isSkippable($0) || barGlyphs.contains($0) }))
    while let last = content.last, isSkippable(last) { content.removeLast() }
    return content
  }

  /// All blockquotes visible in `lines` (`lines[i]` is the rendered text of row
  /// `i`, nil if unavailable), in top-to-bottom order. Each is a contiguous run
  /// of blockquote rows with its dequoted text — bars stripped, rows joined by
  /// newline, trailing blank quoted lines trimmed. Blocks whose text is empty
  /// are skipped.
  static func allBlocks(in lines: [String?]) -> [(range: ClosedRange<Int>, text: String)] {
    var result: [(range: ClosedRange<Int>, text: String)] = []
    var i = 0
    while i < lines.count {
      guard quoteContent(of: lines[i]) != nil else {
        i += 1
        continue
      }
      var j = i
      while j + 1 < lines.count, quoteContent(of: lines[j + 1]) != nil { j += 1 }

      var contents = (i...j).map { quoteContent(of: lines[$0]) ?? "" }
      while let last = contents.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
        contents.removeLast()
      }
      let text = contents.joined(separator: "\n")
      if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        result.append((i...j, text))
      }
      i = j + 1
    }
    return result
  }

  /// The blockquote covering `row` (probing its neighbours too, since pixel→row
  /// mapping is approximate). Used by the right-click context menu.
  static func block(in lines: [String?], at row: Int) -> (range: ClosedRange<Int>, text: String)? {
    let blocks = allBlocks(in: lines)
    for probe in [row, row - 1, row + 1] {
      if let hit = blocks.first(where: { $0.range.contains(probe) }) { return hit }
    }
    return nil
  }
}
