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
    let avatar = PixelAvatar(seed: session.name)
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
      avatar.widthAnchor.constraint(equalToConstant: 32),
      avatar.heightAnchor.constraint(equalToConstant: 32),

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

// MARK: - Pixel Avatar

final class PixelAvatar: NSView {
  let seed: String

  init(seed: String) {
    self.seed = seed
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 4
    layer?.masksToBounds = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func draw(_ dirtyRect: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    let grid = 6
    let cellW = bounds.width / CGFloat(grid)
    let cellH = bounds.height / CGFloat(grid)

    var hash: UInt64 = 5381
    for byte in seed.utf8 { hash = ((hash &<< 5) &+ hash) &+ UInt64(byte) }

    let hue = CGFloat(hash % 360) / 360.0
    let colors = [
      NSColor(hue: hue, saturation: 0.6, brightness: 0.9, alpha: 1),
      NSColor(
        hue: (hue + 0.15).truncatingRemainder(dividingBy: 1), saturation: 0.5, brightness: 0.7,
        alpha: 1),
      Theme.surface2,
    ]

    var rng = hash
    for row in 0..<grid {
      for col in 0..<(grid / 2 + 1) {
        rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let c = colors[Int(rng >> 32) % colors.count]
        ctx.setFillColor(c.cgColor)
        ctx.fill(
          CGRect(x: CGFloat(col) * cellW, y: CGFloat(row) * cellH, width: cellW, height: cellH))
        let mirror = grid - 1 - col
        if mirror != col {
          ctx.fill(
            CGRect(x: CGFloat(mirror) * cellW, y: CGFloat(row) * cellH, width: cellW, height: cellH)
          )
        }
      }
    }
  }
}
