import Foundation

/// Rules for the emoji tags a user can pin on a session card (issue #56).
/// Tags are cosmetic markers: they never affect sorting, grouping, or
/// notifications. Pure functions so the tests can cover them without a live
/// SessionManager.
enum SessionTags {

  /// Most tags one session can carry, so the card layout stays stable.
  static let maxTags = 3

  /// Offered in the Tag menu until the user builds up their own recents.
  static let suggested = ["🔥", "👀", "🧪", "✅", "🚧", "⭐️"]

  /// How many recently used emojis are remembered.
  static let maxRecents = 8

  /// How many one-click emojis the Tag menu lists (a session's own tags are
  /// always listed, even past this).
  static let menuCount = 8

  /// `text` as a tag, or nil unless it is exactly one emoji grapheme
  /// (surrounding whitespace ignored). A bare text-presentation symbol such
  /// as U+2764 gets the emoji variation selector appended, so it draws as an
  /// emoji and compares equal to the picker's form of the same emoji.
  static func normalized(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count == 1, let char = trimmed.first else { return nil }
    let scalars = Array(char.unicodeScalars)
    guard let first = scalars.first else { return nil }
    if scalars.contains(where: { $0.properties.isEmojiPresentation }) { return trimmed }
    guard first.properties.isEmoji else { return nil }
    // Sequences built on a text-presentation base: keycaps, or a symbol
    // already carrying the variation selector.
    if scalars.count > 1 { return trimmed }
    // A lone text-presentation scalar. Digits, `#`, `*`, © and ® are "emoji"
    // to Unicode but read as plain text, so they are not tags.
    guard first.value >= 0x203C else { return nil }
    return trimmed + "\u{FE0F}"
  }

  /// The last single emoji in `text`, for input fields where the emoji
  /// picker may insert after stray characters.
  static func lastEmoji(in text: String) -> String? {
    for char in text.reversed() {
      if let emoji = normalized(String(char)) { return emoji }
    }
    return nil
  }

  /// `tags` after toggling `emoji`: removed when present, appended when
  /// absent. Returns nil when nothing changes: `emoji` is not a single
  /// emoji, or the session is already at `maxTags`.
  static func toggling(_ emoji: String, in tags: [String]) -> [String]? {
    guard let emoji = normalized(emoji) else { return nil }
    if let i = tags.firstIndex(of: emoji) {
      var out = tags
      out.remove(at: i)
      return out
    }
    guard tags.count < maxTags else { return nil }
    return tags + [emoji]
  }

  /// Tags read from disk, made to satisfy the same rules as toggling:
  /// single emojis only, no repeats, at most `maxTags`, order kept.
  static func sanitized(_ tags: [String]) -> [String] {
    var out: [String] = []
    for tag in tags {
      guard out.count < maxTags else { break }
      if let emoji = normalized(tag), !out.contains(emoji) { out.append(emoji) }
    }
    return out
  }

  /// `recents` with `emoji` moved to the front, capped at `maxRecents`.
  static func recording(_ emoji: String, in recents: [String]) -> [String] {
    Array(([emoji] + recents.filter { $0 != emoji }).prefix(maxRecents))
  }

  /// One-click emojis for a session's Tag menu: its own tags first (so each
  /// can be toggled off), then recents, then the suggestions.
  static func menuEmojis(tags: [String], recents: [String]) -> [String] {
    var out = tags
    for emoji in recents + suggested {
      guard out.count < max(menuCount, tags.count) else { break }
      if !out.contains(emoji) { out.append(emoji) }
    }
    return out
  }
}
