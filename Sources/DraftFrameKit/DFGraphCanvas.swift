import AppKit

/// Draws a `GraphModel` as draggable nodes with bezier edges. Read-only:
/// dragging only moves a node for the life of the view, and clicking a
/// session node jumps to its terminal. See docs/graph-engineering.md.
final class DFGraphCanvas: NSView {

  /// Called when the user clicks (without dragging) a node.
  var onSelectNode: ((GraphNode) -> Void)?

  private(set) var model = GraphModel()
  /// Auto-layout for the current model.
  private var layoutResult = GraphLayoutResult()
  private var layoutPositions: [String: CGPoint] { layoutResult.positions }
  /// User overrides from dragging, kept across refreshes.
  private var dragOverrides: [String: CGPoint] = [:]

  private var dragging: (id: String, grab: CGPoint, moved: Bool)?
  private var hoveredID: String?
  private var trackingArea: NSTrackingArea?

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = Theme.bg.cgColor
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  // MARK: - Model

  /// Replace the model, relayout, and resize to fit. Nodes the user has
  /// dragged keep their position; nodes that vanished drop their override.
  func update(model: GraphModel, minimumSize: CGSize) {
    let rootChanged =
      self.model.nodes(of: .session).map(\.id) != model.nodes(of: .session).map(\.id)
    self.model = model
    layoutResult = GraphLayout.layout(model)
    let live = Set(model.nodes.map(\.id))
    dragOverrides = dragOverrides.filter { live.contains($0.key) }

    var size = GraphLayout.contentSize(positions: positions())
    size.width = max(size.width, minimumSize.width)
    size.height = max(size.height, minimumSize.height)
    if frame.size != size {
      setFrameSize(size)
    }
    if rootChanged {
      dragOverrides.removeAll()
      enclosingScrollView?.contentView.scroll(to: .zero)
      enclosingScrollView?.reflectScrolledClipView(enclosingScrollView!.contentView)
    }
    needsDisplay = true
  }

  private func positions() -> [String: CGPoint] {
    var merged = layoutPositions
    for (id, p) in dragOverrides { merged[id] = p }
    return merged
  }

  private func rect(for id: String) -> CGRect? {
    guard let origin = positions()[id] else { return nil }
    return CGRect(origin: origin, size: GraphLayout.nodeSize)
  }

  private func nodeID(at point: CGPoint) -> String? {
    // Later nodes draw on top, so hit-test in reverse.
    for node in model.nodes.reversed() {
      if let r = rect(for: node.id), r.contains(point) { return node.id }
    }
    return nil
  }

  // MARK: - Drawing

  override func draw(_ dirtyRect: NSRect) {
    Theme.bg.setFill()
    dirtyRect.fill()

    drawColumnHeaders()
    for edge in model.edges { drawEdge(edge) }
    for node in model.nodes { drawNode(node) }

    if model.nodes.isEmpty {
      let text = "No session selected. Press Cmd+T to start one."
      draw(
        text, at: CGPoint(x: GraphLayout.margin, y: GraphLayout.margin + GraphLayout.headerHeight),
        font: Theme.mono(12), color: Theme.text3, maxWidth: bounds.width)
    }
  }

  private func drawColumnHeaders() {
    for (column, title) in layoutResult.columnTitles {
      let origin = GraphLayout.origin(column: column, row: 0)
      draw(
        title, at: CGPoint(x: origin.x, y: GraphLayout.margin),
        font: Theme.mono(10, weight: .bold), color: Theme.text3,
        maxWidth: GraphLayout.nodeSize.width)
    }
  }

  private func drawEdge(_ edge: GraphEdge) {
    guard let from = rect(for: edge.from), let to = rect(for: edge.to) else { return }
    let start = CGPoint(x: from.maxX, y: from.midY)
    let end = CGPoint(x: to.minX, y: to.midY)
    let dx = max(40, abs(end.x - start.x) / 2)

    let path = NSBezierPath()
    path.move(to: start)
    path.curve(
      to: end,
      controlPoint1: CGPoint(x: start.x + dx, y: start.y),
      controlPoint2: CGPoint(x: end.x - dx, y: end.y))
    path.lineWidth = 1.5
    if edge.style == .dashed {
      path.setLineDash([5, 4], count: 2, phase: 0)
    }

    let highlighted = hoveredID == edge.from || hoveredID == edge.to
    let color = highlighted ? Theme.accent : Theme.surface3
    color.setStroke()
    path.stroke()

    // Arrowhead at the target.
    let arrow = NSBezierPath()
    arrow.move(to: end)
    arrow.line(to: CGPoint(x: end.x - 7, y: end.y - 4))
    arrow.line(to: CGPoint(x: end.x - 7, y: end.y + 4))
    arrow.close()
    color.setFill()
    arrow.fill()
  }

  private func drawNode(_ node: GraphNode) {
    guard let r = rect(for: node.id) else { return }
    let alpha: CGFloat = node.isMuted ? 0.5 : 1

    let box = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
    Theme.surface2.withAlphaComponent(alpha).setFill()
    box.fill()

    let isHovered = hoveredID == node.id
    let isActive =
      node.sessionID != nil && node.sessionID == SessionManager.shared.activeSession?.id
    box.lineWidth = isActive ? 2 : 1
    (isHovered || isActive ? Theme.selectedBorder : Theme.surface3).setStroke()
    box.stroke()

    // Accent bar on the left edge, clipped to the rounded corners.
    NSGraphicsContext.saveGraphicsState()
    box.addClip()
    node.accent.withAlphaComponent(alpha).setFill()
    CGRect(x: r.minX, y: r.minY, width: 4, height: r.height).fill()
    NSGraphicsContext.restoreGraphicsState()

    let textX = r.minX + 14
    let textWidth = r.width - 22
    draw(
      node.kind.caption, at: CGPoint(x: textX, y: r.minY + 8),
      font: Theme.mono(8, weight: .bold), color: Theme.text3.withAlphaComponent(alpha),
      maxWidth: textWidth)
    draw(
      node.title, at: CGPoint(x: textX, y: r.minY + 20),
      font: Theme.mono(12, weight: .bold), color: Theme.text1.withAlphaComponent(alpha),
      maxWidth: textWidth)
    draw(
      node.subtitle, at: CGPoint(x: textX, y: r.minY + 38),
      font: Theme.mono(9), color: Theme.text2.withAlphaComponent(alpha), maxWidth: textWidth)
    draw(
      node.detail, at: CGPoint(x: textX, y: r.minY + 53),
      font: Theme.mono(9, weight: .medium), color: node.accent.withAlphaComponent(alpha),
      maxWidth: textWidth)
  }

  private func draw(
    _ text: String, at point: CGPoint, font: NSFont, color: NSColor, maxWidth: CGFloat
  ) {
    guard !text.isEmpty else { return }
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    let attributed = NSAttributedString(
      string: text,
      attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    let height = font.ascender - font.descender + 2
    attributed.draw(
      with: CGRect(x: point.x, y: point.y, width: maxWidth, height: height),
      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
  }

  // MARK: - Mouse

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let existing = trackingArea { removeTrackingArea(existing) }
    let area = NSTrackingArea(
      rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    trackingArea = area
  }

  override func mouseMoved(with event: NSEvent) {
    let id = nodeID(at: convert(event.locationInWindow, from: nil))
    if id != hoveredID {
      hoveredID = id
      needsDisplay = true
    }
  }

  override func mouseExited(with event: NSEvent) {
    if hoveredID != nil {
      hoveredID = nil
      needsDisplay = true
    }
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    guard let id = nodeID(at: point), let r = rect(for: id) else {
      dragging = nil
      return
    }
    dragging = (id, CGPoint(x: point.x - r.minX, y: point.y - r.minY), false)
  }

  override func mouseDragged(with event: NSEvent) {
    guard var drag = dragging else { return }
    let point = convert(event.locationInWindow, from: nil)
    let origin = CGPoint(x: max(0, point.x - drag.grab.x), y: max(0, point.y - drag.grab.y))
    drag.moved = true
    dragging = drag
    dragOverrides[drag.id] = origin

    var size = GraphLayout.contentSize(positions: positions())
    size.width = max(size.width, frame.width)
    size.height = max(size.height, frame.height)
    if size != frame.size { setFrameSize(size) }
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    defer { dragging = nil }
    guard let drag = dragging, !drag.moved, let node = model.node(id: drag.id) else { return }
    onSelectNode?(node)
  }
}
