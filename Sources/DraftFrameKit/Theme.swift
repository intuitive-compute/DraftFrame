import AppKit

enum Theme {
  // Backgrounds
  static let bg = NSColor(r: 0x0D, g: 0x0D, b: 0x0D)
  static let surface1 = NSColor(r: 0x1A, g: 0x1A, b: 0x1A)
  static let surface2 = NSColor(r: 0x26, g: 0x26, b: 0x26)
  static let surface3 = NSColor(r: 0x33, g: 0x33, b: 0x33)

  // Text
  static let text1 = NSColor.white.withAlphaComponent(0.85)
  static let text2 = NSColor.white.withAlphaComponent(0.70)
  static let text3 = NSColor.white.withAlphaComponent(0.35)

  // Accent
  static let accent = NSColor(r: 0xFF, g: 0x95, b: 0x00)

  // Status
  static let green = NSColor(r: 0x34, g: 0xC7, b: 0x59)
  static let yellow = NSColor(r: 0xFF, g: 0xCC, b: 0x00)
  static let red = NSColor(r: 0xFF, g: 0x3B, b: 0x30)
  static let cyan = NSColor(r: 0x32, g: 0xD4, b: 0xDE)

  // Selection
  static let selected = NSColor(r: 0xFF, g: 0xA5, b: 0x00, a: 0.35)
  static let selectedBorder = NSColor(r: 0xFF, g: 0xA5, b: 0x00, a: 0.60)

  // Mono font
  static func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
    NSFont.monospacedSystemFont(ofSize: size, weight: weight)
  }
}

extension NSColor {
  convenience init(r: UInt8, g: UInt8, b: UInt8, a: CGFloat = 1.0) {
    self.init(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
  }
}
