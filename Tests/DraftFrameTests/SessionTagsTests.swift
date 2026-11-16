import XCTest

@testable import DraftFrameKit

final class SessionTagsTests: XCTestCase {

  // MARK: - Single-emoji validation

  func testAcceptsSingleEmojiGraphemes() {
    // Plain, skin-toned, ZWJ sequence, flag, keycap, variation-selector form.
    for emoji in ["🔥", "👍🏽", "👩‍💻", "🇨🇦", "1️⃣", "❤️"] {
      XCTAssertEqual(SessionTags.normalized(emoji), emoji, emoji)
    }
  }

  func testRejectsNonEmojiAndMultipleGraphemes() {
    for text in ["", " ", "a", "1", "#", "*", "©", "ab", "🔥🔥", "🔥a", "fire"] {
      XCTAssertNil(SessionTags.normalized(text), text)
    }
  }

  func testTrimsSurroundingWhitespace() {
    XCTAssertEqual(SessionTags.normalized(" 🔥\n"), "🔥")
  }

  func testTextPresentationSymbolGainsEmojiSelector() {
    // Bare U+2764 and the picker's U+2764 U+FE0F are the same tag.
    XCTAssertEqual(SessionTags.normalized("\u{2764}"), "\u{2764}\u{FE0F}")
    XCTAssertEqual(SessionTags.toggling("\u{2764}", in: ["\u{2764}\u{FE0F}"]), [])
  }

  func testLastEmojiSkipsStrayText() {
    XCTAssertEqual(SessionTags.lastEmoji(in: "ab🔥"), "🔥")
    XCTAssertEqual(SessionTags.lastEmoji(in: "🔥👀x"), "👀")
    XCTAssertNil(SessionTags.lastEmoji(in: "abc"))
    XCTAssertNil(SessionTags.lastEmoji(in: ""))
  }

  // MARK: - Toggling

  func testToggleAddsInOrder() {
    var tags: [String] = []
    for emoji in ["🔥", "👀", "🧪"] {
      tags = SessionTags.toggling(emoji, in: tags) ?? tags
    }
    XCTAssertEqual(tags, ["🔥", "👀", "🧪"])
  }

  func testToggleRemovesExistingAndKeepsOrder() {
    XCTAssertEqual(SessionTags.toggling("👀", in: ["🔥", "👀", "🧪"]), ["🔥", "🧪"])
  }

  func testToggleRejectsPastCap() {
    let full = ["🔥", "👀", "🧪"]
    XCTAssertEqual(full.count, SessionTags.maxTags)
    XCTAssertNil(SessionTags.toggling("✅", in: full))
    // Removal still works at the cap.
    XCTAssertEqual(SessionTags.toggling("🔥", in: full), ["👀", "🧪"])
  }

  func testToggleRejectsNonEmoji() {
    XCTAssertNil(SessionTags.toggling("urgent", in: []))
    XCTAssertNil(SessionTags.toggling("🔥🔥", in: []))
  }

  // MARK: - Loading

  func testSanitizedDropsInvalidDuplicateAndExcessTags() {
    XCTAssertEqual(
      SessionTags.sanitized(["🔥", "nope", "🔥", "👀", "🧪", "✅"]), ["🔥", "👀", "🧪"])
  }

  // MARK: - Menu and recents

  func testRecordingMovesToFrontAndCaps() {
    XCTAssertEqual(SessionTags.recording("👀", in: ["🔥", "👀"]), ["👀", "🔥"])
    let distinct = ["😀", "😁", "😂", "🤣", "😃", "😄", "😅", "😆"]
    let recorded = SessionTags.recording("🔥", in: distinct)
    XCTAssertEqual(recorded.count, SessionTags.maxRecents)
    XCTAssertEqual(recorded.first, "🔥")
    XCTAssertFalse(recorded.contains("😆"))
  }

  func testMenuListsTagsThenRecentsThenSuggestions() {
    let menu = SessionTags.menuEmojis(tags: ["🎯"], recents: ["🐛", "🔥"])
    XCTAssertEqual(Array(menu.prefix(3)), ["🎯", "🐛", "🔥"])
    XCTAssertEqual(menu.count, SessionTags.menuCount)
    XCTAssertEqual(Set(menu).count, menu.count)
    // Suggestions fill the rest, minus the one already listed as a recent.
    XCTAssertEqual(Array(menu.dropFirst(3)), SessionTags.suggested.filter { $0 != "🔥" })
  }

  func testSuggestionsAreValidTags() {
    for emoji in SessionTags.suggested {
      XCTAssertEqual(SessionTags.normalized(emoji), emoji, emoji)
    }
  }
}
