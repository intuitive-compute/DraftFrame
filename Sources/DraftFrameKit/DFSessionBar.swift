import AppKit

extension NSPasteboard.PasteboardType {
  fileprivate static let dfSessionDrag = NSPasteboard.PasteboardType("com.draftframe.sessiondrag")
}

/// Right sidebar: session cards with live status, driven by SessionManager.
final class DFSessionBar: NSView {

  private let cardStack = NSStackView()
  private let dropIndicator = NSView()
  private var lastDropIndex: Int?

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = Theme.surface1.cgColor
    buildUI()
    registerForDraggedTypes([.dfSessionDrag])

    NotificationCenter.default.addObserver(
      self, selector: #selector(sessionsChanged),
      name: .sessionsDidChange, object: nil
    )
    NotificationCenter.default.addObserver(
      self, selector: #selector(sessionsChanged),
      name: .activeSessionDidChange, object: nil
    )
    NotificationCenter.default.addObserver(
      self, selector: #selector(sessionsChanged),
      name: .prStatusDidChange, object: nil
    )
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  @objc private func sessionsChanged() {
    refreshCards()
  }

  private func buildUI() {
    let title = NSTextField(labelWithString: "SESSIONS")
    title.font = Theme.mono(10, weight: .medium)
    title.textColor = Theme.text3
    title.translatesAutoresizingMaskIntoConstraints = false
    addSubview(title)

    let sep = NSView()
    sep.wantsLayer = true
    sep.layer?.backgroundColor = Theme.surface3.cgColor
    sep.translatesAutoresizingMaskIntoConstraints = false
    addSubview(sep)

    cardStack.orientation = .vertical
    cardStack.spacing = 6
    cardStack.alignment = .leading
    cardStack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(cardStack)

    dropIndicator.wantsLayer = true
    dropIndicator.layer?.backgroundColor = Theme.accent.cgColor
    dropIndicator.layer?.cornerRadius = 1
    dropIndicator.isHidden = true
    addSubview(dropIndicator)

    NSLayoutConstraint.activate([
      title.topAnchor.constraint(equalTo: topAnchor, constant: 38),
      title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      sep.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
      sep.leadingAnchor.constraint(equalTo: leadingAnchor),
      sep.trailingAnchor.constraint(equalTo: trailingAnchor),
      sep.heightAnchor.constraint(equalToConstant: 1),
      cardStack.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 8),
      cardStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      cardStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
    ])
  }

  private func refreshCards() {
    // Remove existing cards
    for view in cardStack.arrangedSubviews {
      cardStack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }

    let sessions = SessionManager.shared.sessions
    let activeIdx = SessionManager.shared.activeSessionIndex

    if sessions.isEmpty {
      let empty = NSTextField(labelWithString: "No sessions.\nCmd+T to create one.")
      empty.font = Theme.mono(10)
      empty.textColor = Theme.text3
      empty.maximumNumberOfLines = 2
      empty.translatesAutoresizingMaskIntoConstraints = false
      cardStack.addArrangedSubview(empty)
      return
    }

    for (i, session) in sessions.enumerated() {
      let card = SessionCard(session: session, isActive: i == activeIdx, index: i)
      card.translatesAutoresizingMaskIntoConstraints = false
      card.widthAnchor.constraint(equalToConstant: 284).isActive = true
      cardStack.addArrangedSubview(card)
    }
  }

  // MARK: - Drag & Drop reordering

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    sourceIndex(from: sender) == nil ? [] : .move
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard sourceIndex(from: sender) != nil else { return [] }
    showDropIndicator(at: targetIndex(for: sender))
    return .move
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    hideDropIndicator()
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    guard let from = sourceIndex(from: sender) else { return false }
    let to = targetIndex(for: sender)
    hideDropIndicator()
    SessionManager.shared.moveSession(from: from, to: to)
    return true
  }

  override func concludeDragOperation(_ sender: NSDraggingInfo?) {
    hideDropIndicator()
  }

  private func sourceIndex(from info: NSDraggingInfo) -> Int? {
    guard
      let items = info.draggingPasteboard.pasteboardItems,
      let str = items.first?.string(forType: .dfSessionDrag),
      let idx = Int(str)
    else { return nil }
    return idx
  }

  /// Map the current drag location to an insertion index in `cardStack`.
  /// Returns 0 if above the first card, `count` if below the last.
  private func targetIndex(for info: NSDraggingInfo) -> Int {
    let cards = cardStack.arrangedSubviews.compactMap { $0 as? SessionCard }
    guard !cards.isEmpty else { return 0 }
    let pointInStack = cardStack.convert(info.draggingLocation, from: nil)
    for (i, card) in cards.enumerated() {
      if pointInStack.y > card.frame.midY { return i }
    }
    return cards.count
  }

  private func showDropIndicator(at index: Int) {
    if !dropIndicator.isHidden, lastDropIndex == index { return }
    let cards = cardStack.arrangedSubviews.compactMap { $0 as? SessionCard }
    guard !cards.isEmpty else {
      hideDropIndicator()
      return
    }

    let stackFrame = cardStack.frame
    let lineY: CGFloat
    if index <= 0 {
      lineY = cards[0].frame.maxY + stackFrame.minY + 2
    } else if index >= cards.count {
      lineY = cards[cards.count - 1].frame.minY + stackFrame.minY - 3
    } else {
      let above = cards[index - 1]
      let below = cards[index]
      let gapMid = (above.frame.minY + below.frame.maxY) / 2
      lineY = gapMid + stackFrame.minY
    }

    dropIndicator.frame = NSRect(
      x: stackFrame.minX, y: lineY - 1, width: stackFrame.width, height: 2)
    dropIndicator.isHidden = false
    lastDropIndex = index
  }

  private func hideDropIndicator() {
    dropIndicator.isHidden = true
    lastDropIndex = nil
  }
}

// MARK: - Session Card (Live Data)

final class SessionCard: NSView {

  private let session: Session
  private let index: Int
  private let isActive: Bool
  private var glowLayer: CALayer?
  private var mouseDownPoint: NSPoint?

  init(session: Session, isActive: Bool, index: Int) {
    self.session = session
    self.index = index
    self.isActive = isActive
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.backgroundColor = Theme.surface2.cgColor
    layer?.cornerRadius = 8

    if isActive {
      // Bright background + status-coloured border and left bar so the
      // active card visually telegraphs what claude is currently doing.
      let stateColor = session.state.color
      layer?.backgroundColor = Theme.surface3.cgColor
      layer?.borderColor = stateColor.cgColor
      layer?.borderWidth = 1.5

      let accentBar = CALayer()
      accentBar.backgroundColor = stateColor.cgColor
      accentBar.frame = CGRect(x: 0, y: 0, width: 4, height: bounds.height)
      accentBar.autoresizingMask = [.layerHeightSizable]
      accentBar.cornerRadius = 0
      layer?.masksToBounds = true
      layer?.addSublayer(accentBar)
    } else {
      // Dimmed inactive card
      layer?.backgroundColor = Theme.surface1.cgColor
      layer?.borderWidth = 0
      alphaValue = 0.6
    }

    // Pulsing border glow for attention/input states
    let needsPulse = session.state == .needsAttention || session.state == .userInput
    if needsPulse {
      let glow = CALayer()
      glow.cornerRadius = 8
      glow.borderWidth = 1.5
      glow.borderColor = session.state.color.cgColor
      glow.frame = bounds
      glow.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
      layer?.addSublayer(glow)
      glowLayer = glow

      let pulse = CABasicAnimation(keyPath: "opacity")
      pulse.fromValue = 0.3
      pulse.toValue = 1.0
      pulse.duration = 1.4
      pulse.autoreverses = true
      pulse.repeatCount = .infinity
      pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      glow.add(pulse, forKey: "borderPulse")
    }

    buildCard()

    // Click to switch
    let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
    addGestureRecognizer(click)

    // Double-click to rename
    let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(doubleClicked))
    doubleClick.numberOfClicksRequired = 2
    addGestureRecognizer(doubleClick)

    // On macOS, single-click fires alongside double-click; the session
    // switch is idempotent so this is acceptable behavior.
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  @objc private func clicked() {
    SessionManager.shared.switchTo(index: index)
  }

  @objc private func doubleClicked() {
    let alert = NSAlert()
    alert.messageText = "Rename Session"
    alert.informativeText = "Enter a new name for \"\(session.name)\":"
    alert.addButton(withTitle: "Rename")
    alert.addButton(withTitle: "Cancel")

    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
    input.stringValue = session.name
    alert.accessoryView = input

    guard let win = window else { return }
    alert.beginSheetModal(for: win) { [weak self] response in
      guard response == .alertFirstButtonReturn, let self = self else { return }
      let newName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !newName.isEmpty else { return }
      self.session.name = newName
      NotificationCenter.default.post(name: .sessionsDidChange, object: nil)
    }
  }

  private func buildCard() {
    // Avatar
    let avatar = GenerativeAvatar(seed: session.avatarSeed)
    avatar.translatesAutoresizingMaskIntoConstraints = false

    // Name
    let nameLabel = NSTextField(labelWithString: session.displayName)
    nameLabel.font = Theme.mono(12, weight: .medium)
    nameLabel.textColor = Theme.text1
    nameLabel.lineBreakMode = .byTruncatingTail
    nameLabel.maximumNumberOfLines = 1
    nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    nameLabel.translatesAutoresizingMaskIntoConstraints = false

    // Status dot + label
    let dot = NSView()
    dot.wantsLayer = true
    dot.layer?.backgroundColor = session.state.color.cgColor
    dot.layer?.cornerRadius = 3.5
    dot.translatesAutoresizingMaskIntoConstraints = false

    // Breathing pulse on the dot for attention/input states
    if session.state == .needsAttention || session.state == .userInput {
      let dotPulse = CABasicAnimation(keyPath: "opacity")
      dotPulse.fromValue = 0.35
      dotPulse.toValue = 1.0
      dotPulse.duration = 1.4
      dotPulse.autoreverses = true
      dotPulse.repeatCount = .infinity
      dotPulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      dot.layer?.add(dotPulse, forKey: "dotPulse")

      // Soft glow shadow behind the dot
      dot.layer?.shadowColor = session.state.color.cgColor
      dot.layer?.shadowOffset = .zero
      dot.layer?.shadowRadius = 6
      dot.layer?.shadowOpacity = 0.8
      dot.layer?.masksToBounds = false
    }

    let statusLabel = NSTextField(labelWithString: session.state.label)
    statusLabel.font = Theme.mono(9, weight: .medium)
    statusLabel.textColor = session.state.color
    statusLabel.translatesAutoresizingMaskIntoConstraints = false

    // Model
    let modelLabel = NSTextField(labelWithString: session.model)
    modelLabel.font = Theme.mono(9)
    modelLabel.textColor = Theme.text3
    modelLabel.translatesAutoresizingMaskIntoConstraints = false

    // Cost
    let costLabel = NSTextField(labelWithString: String(format: "$%.2f", session.cost))
    costLabel.font = Theme.mono(11)
    costLabel.textColor = Theme.text2
    costLabel.translatesAutoresizingMaskIntoConstraints = false

    // Context window usage (e.g. "42.1K / 200K"). Hidden until the JSONL
    // watcher has parsed at least one assistant turn.
    let contextLabel: NSTextField? = {
      guard session.contextTokens > 0 else { return nil }
      let label = NSTextField(
        labelWithString:
          "\(TokenFormat.short(session.contextTokens)) / \(TokenFormat.short(session.maxContextTokens))"
      )
      label.font = Theme.mono(9)
      label.textColor = Theme.text3
      label.translatesAutoresizingMaskIntoConstraints = false
      return label
    }()

    for v in [avatar, nameLabel, dot, statusLabel, modelLabel, costLabel] as [NSView] {
      addSubview(v)
    }
    if let cl = contextLabel { addSubview(cl) }

    // PR status pill (only if gh reports a PR for this worktree).
    let prStatus = PRMonitor.shared.status(for: session.id)
    let prPill: NSTextField? = prStatus.map { status in
      let label = makePRPill(status: status)
      label.translatesAutoresizingMaskIntoConstraints = false
      addSubview(label)
      return label
    }

    let cardHeight: CGFloat = contextLabel == nil ? 56 : 72

    var constraints: [NSLayoutConstraint] = [
      heightAnchor.constraint(equalToConstant: cardHeight),

      avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      avatar.topAnchor.constraint(equalTo: topAnchor, constant: 10),
      avatar.widthAnchor.constraint(equalToConstant: 40),
      avatar.heightAnchor.constraint(equalToConstant: 40),

      nameLabel.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 8),
      nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
      nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: costLabel.leadingAnchor, constant: -8),

      costLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      costLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),

      dot.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 8),
      dot.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 5),
      dot.widthAnchor.constraint(equalToConstant: 7),
      dot.heightAnchor.constraint(equalToConstant: 7),

      statusLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 4),
      statusLabel.centerYAnchor.constraint(equalTo: dot.centerYAnchor),

      modelLabel.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 8),
      modelLabel.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
    ]
    if let cl = contextLabel {
      constraints.append(contentsOf: [
        cl.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 8),
        cl.topAnchor.constraint(equalTo: dot.bottomAnchor, constant: 5),
      ])
    }
    if let pill = prPill {
      constraints.append(contentsOf: [
        pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        pill.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
      ])
    }
    NSLayoutConstraint.activate(constraints)
  }

  private func makePRPill(status: PRStatus) -> NSTextField {
    let field = NSTextField(labelWithString: status.displayText)
    field.font = Theme.mono(9, weight: .medium)
    field.textColor = status.displayColor
    field.toolTip = status.url
    return field
  }

  // MARK: - Drag source

  override func mouseDown(with event: NSEvent) {
    mouseDownPoint = event.locationInWindow
    super.mouseDown(with: event)
  }

  override func mouseDragged(with event: NSEvent) {
    guard let start = mouseDownPoint else {
      super.mouseDragged(with: event)
      return
    }
    let dx = event.locationInWindow.x - start.x
    let dy = event.locationInWindow.y - start.y
    // 4pt threshold so click and double-click still register.
    if dx * dx + dy * dy < 16 { return }
    mouseDownPoint = nil
    beginDrag(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    mouseDownPoint = nil
    super.mouseUp(with: event)
  }

  private func beginDrag(with event: NSEvent) {
    let item = NSPasteboardItem()
    item.setString(String(index), forType: .dfSessionDrag)
    let dragItem = NSDraggingItem(pasteboardWriter: item)
    dragItem.setDraggingFrame(bounds, contents: snapshotImage())
    let dragSession = beginDraggingSession(with: [dragItem], event: event, source: self)
    dragSession.animatesToStartingPositionsOnCancelOrFail = true
  }

  private func snapshotImage() -> NSImage {
    guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return NSImage() }
    cacheDisplay(in: bounds, to: rep)
    let img = NSImage(size: bounds.size)
    img.addRepresentation(rep)
    return img
  }
}

extension SessionCard: NSDraggingSource {
  func draggingSession(
    _ session: NSDraggingSession,
    sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    context == .withinApplication ? .move : []
  }

  func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
    alphaValue = 0.3
  }

  func draggingSession(
    _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
  ) {
    alphaValue = isActive ? 1.0 : 0.6
  }
}

// MARK: - Generative Avatar

/// A unique pixel-art robot generated from the session seed. The same seed
/// always produces the same robot, so each session keeps a stable, friendly,
/// instantly recognizable identity. The seeded DJB2 -> LCG stream picks the
/// robot's palette, head shape, antenna, eyes, mouth and side details, so the
/// structure (not just the colour) varies between sessions and look-alikes are
/// rare.
final class GenerativeAvatar: NSView {
  let seed: String

  init(seed: String) {
    self.seed = seed
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 9
    layer?.masksToBounds = true
    layer?.borderWidth = 1
    layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  // Keep the corner radius proportional across the sizes the avatar is used at.
  override func layout() {
    super.layout()
    layer?.cornerRadius = bounds.width * 0.22
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    drawPixelRobot(seed: seed, into: ctx, bounds: bounds)
  }
}

/// Renders a deterministic pixel-art robot for `seed` into `ctx`, filling
/// `bounds`. Kept as a free function (not a method) so it can be reused outside
/// the view. Pure CoreGraphics, no asset files.
func drawPixelRobot(seed: String, into ctx: CGContext, bounds: CGRect) {
  // ---- Seeded RNG: a DJB2 hash of the seed feeds an LCG we pull every choice
  // from, so the same seed always grows the same robot. ----
  var hash: UInt64 = 5381
  for byte in seed.utf8 { hash = ((hash &<< 5) &+ hash) &+ UInt64(byte) }
  var rngState = hash | 1
  func bits() -> UInt64 {
    rngState = rngState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return rngState >> 17
  }
  func roll(_ n: Int) -> Int { Int(bits() % UInt64(n)) }
  func chance(_ p: Int, outOf q: Int) -> Bool { roll(q) < p }

  // ---- Palette: a single seeded hue drives a small, cohesive metal palette. ----
  func color(_ h: CGFloat, _ s: CGFloat, _ b: CGFloat) -> CGColor {
    let c = NSColor(hue: h, saturation: s, brightness: b, alpha: 1)
    let srgb = c.usingColorSpace(.sRGB) ?? c
    return CGColor(
      srgbRed: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent, alpha: 1)
  }
  func wrapHue(_ h: CGFloat) -> CGFloat {
    let m = h.truncatingRemainder(dividingBy: 1)
    return m < 0 ? m + 1 : m
  }
  let baseHue = CGFloat(hash % 360) / 360
  let bg = color(baseHue, 0.40, 0.13)  // dark tinted tile
  let body = color(baseHue, 0.16, 0.80)  // robot "metal"
  let bodyShade = color(baseHue, 0.24, 0.52)  // darker metal for depth
  let bodyLight = color(baseHue, 0.08, 0.95)  // highlight sheen
  // Eyes glow either warm amber (the app's energy) or a vivid complementary hue.
  let eye =
    chance(1, outOf: 2) ? color(34.0 / 360, 0.88, 1.0) : color(wrapHue(baseHue + 0.5), 0.80, 1.0)

  // ---- Pixel grid: chunky cells, left/right symmetric like a face. ----
  let grid = 11
  let center = grid / 2  // 5
  let side = min(bounds.width, bounds.height)
  let ox = bounds.minX + (bounds.width - side) / 2
  let oy = bounds.minY + (bounds.height - side) / 2
  // Pixel-snapped edges so neighbouring cells share crisp seams at any size.
  func edge(_ i: Int) -> CGFloat { (CGFloat(i) * side / CGFloat(grid)).rounded() }

  var cells = [[CGColor?]](repeating: [CGColor?](repeating: nil, count: grid), count: grid)
  func put(_ col: Int, _ row: Int, _ c: CGColor) {
    guard row >= 0, row < grid, col >= 0, col < grid else { return }
    cells[row][col] = c
  }
  // Mirror across the vertical centre line so the robot is symmetric.
  func sym(_ col: Int, _ row: Int, _ c: CGColor) {
    put(col, row, c)
    put(grid - 1 - col, row, c)
  }

  // Background tile.
  ctx.setFillColor(bg)
  ctx.fill(CGRect(x: ox, y: oy, width: side, height: side))

  // ---- Head: rows 0-1 hold the antenna, the head spans rows 2...9. ----
  let headTop = 2
  let headBot = 9
  let headW = chance(1, outOf: 2) ? 9 : 7
  let hl = (grid - headW) / 2
  let hr = grid - 1 - hl
  for r in headTop...headBot {
    for c in hl...hr { put(c, r, body) }
  }
  for c in hl...hr { put(c, headBot, bodyShade) }  // chin shadow
  put(hl, headTop, bodyLight)  // top-left sheen
  if chance(1, outOf: 2) {  // rounded head corners
    sym(hl, headTop, bg)
    sym(hl, headBot, bg)
  }

  // ---- Antenna ----
  switch roll(3) {
  case 0:
    break  // none
  case 1:  // single centre antenna
    put(center, 1, bodyShade)
    put(center, 0, eye)
  default:  // twin antennae
    sym(hl + 1, 1, bodyShade)
    sym(hl + 1, 0, eye)
  }

  // ---- Side bolts / ears ----
  if chance(1, outOf: 2), hl - 1 >= 0 {
    sym(hl - 1, 5, bodyShade)
  }

  // ---- Eyes (row 4) ----
  switch roll(4) {
  case 0:  // two dot eyes
    sym(center - 2, 4, eye)
  case 1:  // tall eyes
    sym(center - 2, 4, eye)
    sym(center - 2, 5, eye)
  case 2:  // visor bar
    for c in (center - 2)...(center + 2) { put(c, 4, eye) }
  default:  // single wide eye
    for c in (center - 1)...(center + 1) { put(c, 4, eye) }
  }

  // ---- Mouth (rows 6-7) ----
  switch roll(4) {
  case 0:  // grille teeth
    put(center - 2, 7, bodyShade)
    put(center, 7, bodyShade)
    put(center + 2, 7, bodyShade)
  case 1:  // straight bar
    for c in (center - 2)...(center + 2) { put(c, 7, bodyShade) }
  case 2:  // smile
    sym(center - 2, 6, bodyShade)
    for c in (center - 1)...(center + 1) { put(c, 7, bodyShade) }
  default:  // grid grille
    for r in 6...7 {
      for c in (center - 2)...(center + 2) where (r + c) % 2 == 0 { put(c, r, bodyShade) }
    }
  }

  // ---- Cheek lights ----
  if chance(1, outOf: 3) {
    sym(hl + 1, 5, eye)
  }

  // ---- Render: row 0 is the top row. ----
  for r in 0..<grid {
    for c in 0..<grid {
      guard let cellColor = cells[r][c] else { continue }
      let x0 = ox + edge(c)
      let x1 = ox + edge(c + 1)
      let yTop = oy + side - edge(r)
      let yBot = oy + side - edge(r + 1)
      ctx.setFillColor(cellColor)
      ctx.fill(CGRect(x: x0, y: yBot, width: x1 - x0, height: yTop - yBot))
    }
  }
}
