import Foundation

/// Formats terminal text the user selected as a markdown blockquote, ready to
/// drop into the agent's input so the next message is anchored to it.
enum ReplyQuote {

  /// Longest quote body, in characters, before it is cut short. Keeps a
  /// runaway Select All from flooding the agent's input.
  static let defaultLimit = 2000

  /// Appended to a quote that was cut at the limit.
  static let truncationMarker = " […]"

  /// `text` as a blockquote: every line prefixed with `> ` (a bare `>` for a
  /// blank line), then a blank line so the reply starts clear of the quote.
  /// Returns nil when there is nothing to quote.
  static func format(_ text: String, limit: Int = defaultLimit) -> String? {
    var lines = sanitize(text).components(separatedBy: "\n").map(trimTrailingBlank)
    while let first = lines.first, first.isEmpty { lines.removeFirst() }
    while let last = lines.last, last.isEmpty { lines.removeLast() }
    guard !lines.isEmpty else { return nil }

    var body = lines.joined(separator: "\n")
    if body.count > limit {
      body = trimTrailingBlank(String(body.prefix(max(limit, 0)))) + truncationMarker
    }
    let quoted = body.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 }
    return quoted.joined(separator: "\n") + "\n\n"
  }

  /// Normalise line endings and drop control characters. The quote is sent
  /// inside a bracketed paste, and a stray ESC in it could end the paste
  /// early and let the rest be read as keystrokes.
  private static func sanitize(_ text: String) -> String {
    let unified = text.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    let scalars = unified.unicodeScalars.filter {
      $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0)
    }
    return String(String.UnicodeScalarView(scalars))
  }

  private static func trimTrailingBlank(_ s: String) -> String {
    var end = s.endIndex
    while end > s.startIndex {
      let prev = s.index(before: end)
      guard s[prev].isWhitespace else { break }
      end = prev
    }
    return String(s[..<end])
  }
}
