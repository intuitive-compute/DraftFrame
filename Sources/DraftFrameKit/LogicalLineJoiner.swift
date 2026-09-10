import Foundation

/// Rebuilds logical lines from the rows Claude Code's TUI drew.
///
/// SwiftTerm already joins rows the *terminal* soft-wrapped (it tracks an
/// `isWrapped` flag per buffer line), but Claude Code's Ink renderer never
/// relies on terminal wrapping: it word-wraps text itself at a content width
/// short of the terminal edge and emits every visual row as its own line,
/// re-emitting the block's left indent on each continuation row. So a long
/// command that visibly wraps copies with a hard newline at every row
/// boundary, and pasting it into a shell runs it as several broken commands.
///
/// This replays Ink's wrapping decision (`wrap-ansi` with `hard: true`) in
/// reverse. For two adjacent rows `a` and `b`, `b` is a continuation of `a`
/// when Ink could not have fit `b`'s first word on `a`:
///
/// - **Hard split**: `a` is exactly as wide as the widest row selected (so it
///   fills the wrap column) and the token straddling the seam (`a`'s trailing
///   word plus `b`'s leading word) is wider than the block's text width, the
///   only case in which Ink splits inside a word. Joined with nothing.
/// - **Word wrap**: `a`'s width plus a space plus `b`'s first word overflows
///   the wrap column. Joined with a space.
///
/// Anything else stays a hard newline. In particular a row that starts a new
/// list item or structural glyph, a row whose indent is shallower than the
/// row above, or a blank row always breaks. The heuristic is necessarily
/// ambiguous for two independent lines that happen to satisfy the width test
/// (a code line that nearly fills the width followed by a line whose first
/// token would not have fit; a row that is exactly full and ends in a long
/// token followed by another long token, which is byte-identical to a hard
/// split), so it is only applied to Claude Code sessions, never to a plain
/// shell or another agent's TUI.
enum LogicalLineJoiner {

  /// The wrap column must reach this fraction of the terminal width before
  /// any joining happens. A selection whose rows all end well short of the
  /// edge (a few short lines, a narrow list) carries no wrap information, and
  /// joining on it would glue independent lines.
  static let minimumWrapFraction = 0.6

  /// Join the selection `text` (the newline-separated pieces SwiftTerm
  /// produced) into logical lines, using the visible `screenRows` to estimate
  /// Ink's wrap column and to recover the full width of the first selected
  /// row when the drag began mid-row.
  static func join(_ text: String, columns: Int, screenRows: [String?]) -> String {
    let head = text.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
    guard head.count > 1 else { return text }
    return join(
      text, columns: columns,
      screenWrapColumn: wrapColumn(forScreenRows: screenRows),
      firstRowWidth: fullRowWidth(
        endingWith: String(head[0]), followedBy: String(head[1]), in: screenRows))
  }

  /// Core of `join`. `screenWrapColumn` is the wrap column inferred from the
  /// screen (nil if unknown); the widest selected row is also consulted, so a
  /// wrapped command selected while scrolled into scrollback still joins.
  /// `firstRowWidth` is the on-screen width of the row the selection starts
  /// on, when the first line is only the tail of that row.
  static func join(
    _ text: String, columns: Int, screenWrapColumn: Int?, firstRowWidth: Int? = nil
  ) -> String {
    let lines = text.components(separatedBy: "\n")
    guard lines.count > 1, columns > 0 else { return text }

    // Widths of the rows as drawn. SwiftTerm has already joined
    // terminal-wrapped rows, and those can exceed the column count; they are
    // never the head of an Ink wrap so they are excluded from the estimate.
    var widths = lines.map { displayWidth(trimTrailingBlank($0)) }
    if let firstRowWidth, firstRowWidth > widths[0], firstRowWidth <= columns {
      widths[0] = firstRowWidth
    }
    // Chrome rows (a rule between turns, a box border) span the full width
    // and would otherwise stop any text row from counting as filled.
    let selectionMax =
      zip(lines, widths)
      .filter { $0.1 <= columns && isTextRow($0.0) }
      .map { $0.1 }.max() ?? 0
    let wrapColumn = max(selectionMax, min(screenWrapColumn ?? 0, columns))
    guard Double(wrapColumn) >= Double(columns) * minimumWrapFraction else { return text }

    var result: [String] = [lines[0]]
    for i in 1..<lines.count {
      let row = lines[i]
      let decision = continuation(
        from: lines[i - 1], width: widths[i - 1], to: row,
        wrapColumn: wrapColumn, fullRowColumn: selectionMax)
      switch decision {
      case .none:
        result.append(row)
      case .word, .hardSplit:
        var last = result.removeLast()
        while let c = last.last, isBlank(c) { last.removeLast() }
        if decision == .word { last.append(" ") }
        last.append(content(of: row))
        result.append(last)
      }
    }
    return result.joined(separator: "\n")
  }

  /// Estimate Ink's wrap column from the rows on screen: the widest row that
  /// carries text and is not part of the chrome. Rows bounded by box-drawing
  /// (the input box, tool-call frames) span the full terminal width and are
  /// ignored. Nil when nothing qualifies.
  static func wrapColumn(forScreenRows rows: [String?]) -> Int? {
    var best = 0
    for case let row? in rows where isTextRow(row) {
      best = max(best, displayWidth(trimTrailingBlank(row)))
    }
    return best > 0 ? best : nil
  }

  /// A row that carries text and is not chrome: rows bounded by box-drawing
  /// (the input box, tool-call frames, the rule between turns) span the full
  /// terminal width and say nothing about where Ink wrapped.
  static func isTextRow(_ row: String) -> Bool {
    let trimmed = trimTrailingBlank(row)
    guard trimmed.contains(where: isTextGlyph) else { return false }
    if let first = trimmed.first(where: { !isBlank($0) }), isBoxDrawing(first) { return false }
    if let last = trimmed.last, isBoxDrawing(last) { return false }
    return true
  }

  /// Width of the on-screen row the selection started on, when `line` (the
  /// first selected line) is only the tail of that row because the drag began
  /// mid-row. The match is anchored: the row must end with `line` at a word
  /// boundary *and* be followed on screen by the second selected line, so an
  /// unrelated row elsewhere that happens to end the same way is not taken.
  /// Nil when the selection is not on screen or already starts at the row's
  /// first column.
  static func fullRowWidth(endingWith line: String, followedBy next: String, in rows: [String?])
    -> Int?
  {
    let tail = trimTrailingBlank(line)
    let nextTrimmed = trimTrailingBlank(next)
    guard !tail.isEmpty, tail.contains(where: isTextGlyph) else { return nil }
    for i in rows.indices.dropLast() {
      guard let row = rows[i], let below = rows[i + 1] else { continue }
      let trimmed = trimTrailingBlank(row)
      guard trimmed.count > tail.count, trimmed.hasSuffix(tail) else { continue }
      guard trimTrailingBlank(below) == nextTrimmed else { continue }
      let boundary = trimmed.index(trimmed.endIndex, offsetBy: -tail.count)
      let before = trimmed[trimmed.index(before: boundary)]
      guard isBlank(before) || !isTextGlyph(before) || !isTextGlyph(tail.first!) else { continue }
      return displayWidth(trimmed)
    }
    return nil
  }

  // MARK: - Decision

  enum Continuation { case none, word, hardSplit }

  /// Decide whether row `b` continues row `a`. `width` is `a`'s drawn width
  /// (which may exceed the visible fragment when the selection began
  /// mid-row), `wrapColumn` the column Ink wrapped at, and `fullRowColumn`
  /// the widest row in the selection, used to recognise rows Ink filled
  /// completely.
  static func continuation(
    from a: String, width aWidth: Int, to b: String, wrapColumn: Int, fullRowColumn: Int
  ) -> Continuation {
    let a = trimTrailingBlank(a)
    let bIndent = leadingBlankCount(b)
    let bContent = content(of: b)
    guard !a.isEmpty, !bContent.isEmpty else { return .none }
    guard bIndent >= leadingBlankCount(a) else { return .none }
    guard !startsNewItem(bContent) else { return .none }
    // Only join onto something that reads as text: a border or rule row is
    // never the head of a wrapped line.
    guard a.contains(where: isTextGlyph), bContent.contains(where: isTextGlyph) else {
      return .none
    }
    guard aWidth <= wrapColumn else { return .none }

    let firstWord = displayWidth(String(bContent.prefix(while: { !$0.isWhitespace })))

    // Ink splits inside a word only when the word is wider than the block's
    // text region, which runs from the continuation indent to the row edge,
    // and when it does the row is filled exactly. The test must be exact: the
    // remainder of a split token typically ends a column or two short of the
    // edge, and a lenient match would glue the following word onto it.
    if aWidth == fullRowColumn {
      let tail = displayWidth(String(a.reversed().prefix(while: { !$0.isWhitespace })))
      if tail + firstWord > aWidth - bIndent { return .hardSplit }
    }
    if aWidth + 1 + firstWord > wrapColumn { return .word }
    return .none
  }

  // MARK: - Row anatomy

  /// Glyphs that open a new list item or structural row in Claude Code's
  /// output: bullets, tool-call markers, checkboxes, the quote bar, and the
  /// `|` of a Markdown table cell. A row beginning with one of these is never
  /// a continuation. Shell-significant `>`, `#` and `&` are deliberately
  /// absent so a wrapped command whose continuation starts with a redirect
  /// or comment still joins.
  private static let itemGlyphs: Set<Character> = Set<Character>([
    "•", "◦", "▪", "⏺", "⎿", "☐", "☒", "✓", "✔", "✗", "✘", "›", "❯", "|",
  ]).union(BlockquoteScanner.barGlyphs)

  /// "1. item", "2) item", and the line-number gutter of an Edit-tool diff
  /// ("12 +    let value = ..."), which is digits followed by whitespace.
  private static let numberedItem = try! NSRegularExpression(pattern: "^[0-9]{1,4}(?:[.)])?\\s")

  /// True when `content` (indent already stripped) opens a list item, a
  /// table cell, a diff gutter, a quote bar, a tool-call marker, or a
  /// box-drawing frame.
  static func startsNewItem(_ content: String) -> Bool {
    guard let first = content.first else { return false }
    if itemGlyphs.contains(first) || isBoxDrawing(first) { return true }
    // "- item" / "* item" bullets, but not "--flag" or "*.swift".
    if first == "-" || first == "*" {
      let second = content.dropFirst().first
      return second == " " || second == nil
    }
    if first.isNumber {
      let range = NSRange(location: 0, length: (content as NSString).length)
      return numberedItem.firstMatch(in: content, range: range) != nil
    }
    return false
  }

  private static func isBlank(_ c: Character) -> Bool {
    BlockquoteScanner.isSkippable(c)
  }

  private static func isBoxDrawing(_ c: Character) -> Bool {
    guard let v = c.unicodeScalars.first?.value else { return false }
    return (0x2500...0x257F).contains(v)
  }

  private static func leadingBlankCount(_ s: String) -> Int {
    s.prefix(while: isBlank).count
  }

  private static func content(of row: String) -> String {
    trimTrailingBlank(String(row.drop(while: isBlank)))
  }

  private static func trimTrailingBlank(_ s: String) -> String {
    var s = s
    while let last = s.last, isBlank(last) { s.removeLast() }
    return s
  }

  private static func isTextGlyph(_ c: Character) -> Bool {
    c.isLetter || c.isNumber
  }

  /// Terminal column width of `s`, matching what Ink's `string-width` sees:
  /// combining marks and joiners are zero, East Asian wide/fullwidth and
  /// emoji-presentation scalars are two, everything else is one.
  static func displayWidth(_ s: String) -> Int {
    var width = 0
    for scalar in s.unicodeScalars {
      let v = scalar.value
      let category = scalar.properties.generalCategory
      if v == 0 || v == 0x200B || v == 0x200D || (0xFE00...0xFE0F).contains(v)
        || category == .nonspacingMark || category == .enclosingMark
      {
        continue
      }
      width += isWide(scalar) ? 2 : 1
    }
    return width
  }

  private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
    if scalar.properties.isEmojiPresentation { return true }
    let v = scalar.value
    return (0x1100...0x115F).contains(v)  // Hangul Jamo
      || (0x2E80...0x303E).contains(v)  // CJK radicals, punctuation
      || (0x3041...0x33FF).contains(v)  // Hiragana, Katakana, CJK compat
      || (0x3400...0x4DBF).contains(v)  // CJK ext A
      || (0x4E00...0x9FFF).contains(v)  // CJK unified
      || (0xA000...0xA4CF).contains(v)  // Yi
      || (0xAC00...0xD7A3).contains(v)  // Hangul syllables
      || (0xF900...0xFAFF).contains(v)  // CJK compat ideographs
      || (0xFE30...0xFE4F).contains(v)  // CJK compat forms
      || (0xFF00...0xFF60).contains(v)  // Fullwidth forms
      || (0xFFE0...0xFFE6).contains(v)
      || (0x1F300...0x1F64F).contains(v)  // Pictographs, emoticons
      || (0x1F680...0x1F6FF).contains(v)  // Transport
      || (0x1F900...0x1F9FF).contains(v)  // Supplemental symbols
      || (0x1FA70...0x1FAFF).contains(v)  // Symbols ext A
      || (0x20000...0x3FFFD).contains(v)  // CJK ext B+
  }
}
