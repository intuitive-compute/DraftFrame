import AppKit

/// A user-defined bucket of sessions in the session bar. Groups render as a
/// collapsible header above their member cards; membership lives on each
/// `Session.groupID`, ordering lives in `SessionManager.groups`.
@MainActor
final class SessionGroup {
  let id: UUID
  var name: String
  var color: NSColor
  var isCollapsed: Bool

  init(id: UUID = UUID(), name: String, color: NSColor, isCollapsed: Bool = false) {
    self.id = id
    self.name = name
    self.color = color
    self.isCollapsed = isCollapsed
  }
}

/// Group colors, presets, and the ordering rule the session bar relies on.
/// Pure functions so the tests can cover them without a live SessionManager.
enum SessionGrouping {

  /// Swatches offered in the group dialog and drawn from for preset groups.
  /// Chosen to read clearly against the dark surfaces.
  static let palette: [NSColor] = [
    NSColor(r: 0xFF, g: 0x6B, b: 0x6B),  // coral
    NSColor(r: 0xFF, g: 0x95, b: 0x00),  // orange
    NSColor(r: 0xFF, g: 0xD1, b: 0x4A),  // yellow
    NSColor(r: 0x7B, g: 0xD8, b: 0x8F),  // green
    NSColor(r: 0x34, g: 0xC7, b: 0xA0),  // teal
    NSColor(r: 0x32, g: 0xD4, b: 0xDE),  // cyan
    NSColor(r: 0x5A, g: 0xA9, b: 0xFF),  // blue
    NSColor(r: 0x8E, g: 0x7C, b: 0xFF),  // violet
    NSColor(r: 0xE0, g: 0x7A, b: 0xFF),  // magenta
    NSColor(r: 0xFF, g: 0x7E, b: 0xB6),  // pink
    NSColor(r: 0xC8, g: 0xA2, b: 0x7A),  // sand
    NSColor(r: 0x9A, g: 0xA5, b: 0xB1),  // slate
  ]

  /// Pick `count` random palette colors, avoiding repeats until the palette
  /// is exhausted and avoiding `used` (colors already on existing groups)
  /// where possible, so preset groups are distinguishable at a glance.
  static func randomColors(count: Int, avoiding used: [NSColor] = []) -> [NSColor] {
    let usedHex = Set(used.map(hexString))
    var pool = palette.filter { !usedHex.contains(hexString($0)) }.shuffled()
    var result: [NSColor] = []
    for _ in 0..<count {
      if pool.isEmpty { pool = palette.shuffled() }
      result.append(pool.removeFirst())
    }
    return result
  }

  /// The three lifecycle buckets the Status preset creates.
  static let statusPresetNames = ["In Progress", "In QA", "Done"]

  /// Stable ordering the session bar renders and Cmd+N indexes: sessions in
  /// the first group, then the second, ..., then ungrouped sessions, with
  /// relative order inside each block preserved. `groupIDs[i]` is the group
  /// of the session currently at index `i` (nil = ungrouped); `groupOrder`
  /// is the group list order. A session whose group is unknown counts as
  /// ungrouped. Returns the permutation of original indices.
  static func displayOrder(groupIDs: [UUID?], groupOrder: [UUID]) -> [Int] {
    var rank: [UUID: Int] = [:]
    for (i, id) in groupOrder.enumerated() { rank[id] = i }
    func rankOf(_ g: UUID?) -> Int {
      guard let g = g, let r = rank[g] else { return groupOrder.count }
      return r
    }
    return groupIDs.indices.sorted { a, b in
      let ra = rankOf(groupIDs[a])
      let rb = rankOf(groupIDs[b])
      return ra != rb ? ra < rb : a < b
    }
  }

  /// `items` with the element at `from` moved so it sits at insertion index
  /// `to` of the original list (0 = first, `items.count` = last), the same
  /// convention `SessionManager.moveSession` uses. Returns nil when either
  /// index is out of range or the move would leave the order unchanged.
  static func moving<T>(_ items: [T], from: Int, to: Int) -> [T]? {
    guard from >= 0, from < items.count, to >= 0, to <= items.count else { return nil }
    // Inserting right before or right after itself is a no-op.
    guard to != from, to != from + 1 else { return nil }
    var result = items
    let moved = result.remove(at: from)
    result.insert(moved, at: to > from ? to - 1 : to)
    return result
  }

  // MARK: - Color <-> hex

  /// `#RRGGBB` for persistence.
  static func hexString(_ color: NSColor) -> String {
    let c = color.usingColorSpace(.sRGB) ?? color
    let r = Int((c.redComponent * 255).rounded())
    let g = Int((c.greenComponent * 255).rounded())
    let b = Int((c.blueComponent * 255).rounded())
    return String(format: "#%02X%02X%02X", r, g, b)
  }

  static func color(fromHex hex: String) -> NSColor? {
    var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
    return NSColor(r: UInt8((v >> 16) & 0xFF), g: UInt8((v >> 8) & 0xFF), b: UInt8(v & 0xFF))
  }
}
