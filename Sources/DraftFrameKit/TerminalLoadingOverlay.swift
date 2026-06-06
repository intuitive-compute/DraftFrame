import AppKit

/// Semi-transparent overlay shown over a terminal while its shell (or Claude)
/// boots. Dims the noisy startup output (still faintly visible behind it) and
/// swallows all keyboard/mouse input so
/// typed-ahead characters can't interleave with the bootstrap command (which
/// would corrupt the `cd` path). Removed by `fadeOut` once the owner decides
/// the terminal is ready.
final class TerminalLoadingOverlay: NSView {
  /// Which matrix animation to show.
  enum Style {
    /// Diagonal ripple of scaling cells. Used for the Claude session.
    case scalingWave
    /// An endless zoom-in: the matrix dives into one cell, which resolves into
    /// a fresh matrix as the dive continues. Used for the quick-terminal shell.
    case zoom
  }

  private let message: String
  private let animation: MatrixAnimationView

  init(message: String, style: Style = .scalingWave) {
    self.message = message
    self.animation = (style == .zoom) ? ZoomingMatrixView() : ScalingMatrixView()
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = Theme.bg.withAlphaComponent(0.85).cgColor
    buildContent()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  private func buildContent() {
    animation.translatesAutoresizingMaskIntoConstraints = false

    let label = NSTextField(labelWithString: message)
    label.font = Theme.mono(11)
    label.textColor = Theme.text3
    label.alignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false

    addSubview(animation)
    addSubview(label)
    NSLayoutConstraint.activate([
      animation.centerXAnchor.constraint(equalTo: centerXAnchor),
      animation.centerYAnchor.constraint(equalTo: centerYAnchor),
      label.centerXAnchor.constraint(equalTo: centerXAnchor),
      label.topAnchor.constraint(equalTo: animation.bottomAnchor, constant: 18),
    ])
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    // CoreAnimation drops infinite animations when a layer leaves the window,
    // so re-arm whenever we're remounted — the parent panes detach and re-add
    // the overlay as they swap terminals.
    if window != nil { animation.startAnimating() }
  }

  /// Fade out, detach from the view hierarchy, then run `completion`.
  func fadeOut(completion: @escaping () -> Void) {
    NSAnimationContext.runAnimationGroup(
      { ctx in
        ctx.duration = 0.22
        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
        animator().alphaValue = 0
      },
      completionHandler: { [weak self] in
        self?.removeFromSuperview()
        completion()
      })
  }

  // MARK: - Input blocking
  //
  // While installed, the overlay is the window's first responder instead of
  // the terminal, so the terminal's local key monitor sees `firstResponder
  // !== terminalView` and passes keystrokes straight through to us, where we
  // drop them. Sitting on top of the terminal also intercepts mouse events.

  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func keyDown(with event: NSEvent) {}
  override func keyUp(with event: NSEvent) {}
  override func mouseDown(with event: NSEvent) {}
  override func mouseDragged(with event: NSEvent) {}
  override func mouseUp(with event: NSEvent) {}
  override func rightMouseDown(with event: NSEvent) {}
}

/// Base for the loading grid animations. `startAnimating` is re-invoked on
/// every remount, so it must fully (re)establish its animations.
private class MatrixAnimationView: NSView {
  // Grid geometry shared by both animations.
  static let gridSize = 4
  static let cellSize: CGFloat = 9
  static let gap: CGFloat = 5
  static var gridSide: CGFloat {
    CGFloat(gridSize) * cellSize + CGFloat(gridSize - 1) * gap
  }

  func startAnimating() {}

  /// Lay out `cells` (in row-major order) edge-to-edge in a grid whose
  /// top-left corner is at `origin`, each cell centered on its slot.
  func position(_ cells: [CALayer], gridOrigin origin: CGPoint) {
    let stride = Self.cellSize + Self.gap
    for row in 0..<Self.gridSize {
      for col in 0..<Self.gridSize {
        cells[row * Self.gridSize + col].position = CGPoint(
          x: origin.x + CGFloat(col) * stride + Self.cellSize / 2,
          y: origin.y + CGFloat(row) * stride + Self.cellSize / 2)
      }
    }
  }

  /// A single accent grid cell layer, scaled around its center.
  static func makeCell() -> CALayer {
    let cell = CALayer()
    cell.backgroundColor = Theme.accent.cgColor
    cell.cornerRadius = 2
    cell.bounds = CGRect(x: 0, y: 0, width: cellSize, height: cellSize)
    cell.anchorPoint = CGPoint(x: 0.5, y: 0.5)
    return cell
  }
}

/// A square grid of accent cells that scale (and brighten) up and down. A
/// phase offset keyed to each cell's anti-diagonal makes the scaling ripple
/// across the matrix like a wave.
private final class ScalingMatrixView: MatrixAnimationView {
  /// One full breathe (grow + shrink) of a cell.
  private static let period: CFTimeInterval = 1.3

  private var cells: [CALayer] = []

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.masksToBounds = false
    for _ in 0..<(Self.gridSize * Self.gridSize) {
      let cell = Self.makeCell()
      layer?.addSublayer(cell)
      cells.append(cell)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override var intrinsicContentSize: NSSize {
    NSSize(width: Self.gridSide, height: Self.gridSide)
  }

  override func layout() {
    super.layout()
    position(
      cells,
      gridOrigin: CGPoint(
        x: (bounds.width - Self.gridSide) / 2,
        y: (bounds.height - Self.gridSide) / 2))
  }

  override func startAnimating() {
    let now = CACurrentMediaTime()
    let maxDiagonal = Double((Self.gridSize - 1) * 2)
    for row in 0..<Self.gridSize {
      for col in 0..<Self.gridSize {
        // Anti-diagonal index → 0…1 phase, so the wave travels corner-to-corner.
        let phase = Double(row + col) / maxDiagonal

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.3
        scale.toValue = 1.0
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0.25
        opacity.toValue = 1.0

        let group = CAAnimationGroup()
        group.animations = [scale, opacity]
        group.duration = Self.period / 2
        group.autoreverses = true
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // Negative begin time so every cell starts mid-cycle, already forming
        // the diagonal wave instead of all blooming together on the first tick.
        group.beginTime = now - phase * Self.period

        cells[row * Self.gridSize + col].add(group, forKey: "matrix")
      }
    }
  }
}

/// An endless fractal zoom-in. The matrix scales up toward one (random) cell
/// until that cell fills the frame — but every cell hides a matrix-shaped copy
/// of itself that crossfades in as the dive closes, so the cell visibly
/// *becomes* the matrix. At the peak the frame holds a full matrix again, which
/// is pixel-identical to the start, so the loop reset is invisible and the dive
/// simply continues into a cell of the new matrix. One grid, clipped to the
/// frame; neighbors slide out of view as we close in.
private final class ZoomingMatrixView: MatrixAnimationView {
  /// One dive from the full matrix into a single cell.
  private static let diveDuration: CFTimeInterval = 2.2
  /// Scale at which a single cell fills the frame.
  private static var zoomScale: CGFloat { gridSide / cellSize }
  /// Scale that shrinks a full matrix down to fit inside one cell (= 1/zoom).
  private static var subScale: CGFloat { cellSize / gridSide }

  private let grid = CALayer()
  private var cells: [CALayer] = []
  /// A full matrix shrunk into the focused cell; crossfades in as the dive
  /// closes so the cell resolves into the matrix. Rides the grid's transform,
  /// so at the peak its content lands back at scale 1, filling the frame.
  private let subGrid = CALayer()
  /// Bumped on each (re)start so a stale dive's completion can't keep looping.
  private var generation = 0
  /// Cell we're currently diving into (its base square fades for the reveal).
  private var focusedIndex = 0

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.masksToBounds = true  // clip to the frame so only the focused cell shows

    grid.bounds = CGRect(x: 0, y: 0, width: Self.gridSide, height: Self.gridSide)
    grid.anchorPoint = CGPoint(x: 0.5, y: 0.5)
    for _ in 0..<(Self.gridSize * Self.gridSize) {
      let cell = Self.makeCell()
      grid.addSublayer(cell)
      cells.append(cell)
    }
    position(cells, gridOrigin: .zero)  // cells live in the grid's own space

    // The sub-matrix is a second full grid, scaled down to a single cell and
    // hidden until the dive closes in. It's a child of `grid`, so the dive's
    // zoom carries it from cell-sized back up to full-frame.
    subGrid.bounds = grid.bounds
    subGrid.anchorPoint = CGPoint(x: 0.5, y: 0.5)
    subGrid.transform = CATransform3DMakeScale(Self.subScale, Self.subScale, 1)
    subGrid.opacity = 0
    var subCells: [CALayer] = []
    for _ in 0..<(Self.gridSize * Self.gridSize) {
      let cell = Self.makeCell()
      subGrid.addSublayer(cell)
      subCells.append(cell)
    }
    position(subCells, gridOrigin: .zero)
    grid.addSublayer(subGrid)  // drawn above the base cells

    layer?.addSublayer(grid)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override var intrinsicContentSize: NSSize {
    NSSize(width: Self.gridSide, height: Self.gridSide)
  }

  private var gridCenter: CGPoint {
    CGPoint(x: Self.gridSide / 2, y: Self.gridSide / 2)
  }

  /// Center of cell `index` in the grid's own coordinate space.
  private func cellCenter(_ index: Int) -> CGPoint {
    let stride = Self.cellSize + Self.gap
    return CGPoint(
      x: CGFloat(index % Self.gridSize) * stride + Self.cellSize / 2,
      y: CGFloat(index / Self.gridSize) * stride + Self.cellSize / 2)
  }

  override func layout() {
    super.layout()
    grid.position = gridCenter
  }

  override func startAnimating() {
    generation += 1
    runDive(generation)
  }

  /// Dive into a fresh cell, then loop. The end state (a full matrix filling
  /// the frame, drawn by the sub-grid) is identical to the start, so when the
  /// animations are removed the layers snap back invisibly and the next dive
  /// continues the zoom.
  private func runDive(_ token: Int) {
    guard token == generation, window != nil else { return }

    // Restore the previous focus and aim the sub-matrix at a fresh cell. The
    // base/sub opacities only ever changed in the presentation layer, so their
    // models are already back at the resting state — but reset explicitly so
    // intent is clear. No implicit animation, or the reset would be visible.
    var index = Int.random(in: 0..<cells.count)
    if cells.count > 1, index == focusedIndex { index = (index + 1) % cells.count }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    cells[focusedIndex].opacity = 1
    focusedIndex = index
    subGrid.opacity = 0
    subGrid.position = cellCenter(index)
    CATransaction.commit()

    // Pan + scale so the focused cell ends centered and frame-filling, sampled
    // along a geometric (exponential) zoom under a cosine ease. Equal time
    // multiplies the scale by an equal factor, so the zoom reads as uniform and
    // unhurried instead of rushing early and crawling late; the cosine ease
    // brings velocity to zero at both ends, so the dive eases out as the cell
    // settles into the matrix and eases gently back in for the next one. The
    // focused cell pans straight to center as it grows.
    let z = Double(Self.zoomScale)
    let ox = Double(cellCenter(index).x - Self.gridSide / 2)
    let oy = Double(cellCenter(index).y - Self.gridSide / 2)
    let cx = Double(gridCenter.x)
    let cy = Double(gridCenter.y)
    let steps = 24
    var scaleValues: [NSNumber] = []
    var positionValues: [NSValue] = []
    var keyTimes: [NSNumber] = []
    for i in 0...steps {
      let u = Double(i) / Double(steps)
      let e = (1 - cos(.pi * u)) / 2  // cosine ease: zero velocity at both ends
      let s = pow(z, e)  // geometric zoom: uniform perceived speed
      scaleValues.append(NSNumber(value: s))
      positionValues.append(
        NSValue(
          point: CGPoint(
            x: cx + ox * (1 - e) - ox * s,
            y: cy + oy * (1 - e) - oy * s)))
      keyTimes.append(NSNumber(value: u))
    }

    let scale = CAKeyframeAnimation(keyPath: "transform.scale")
    scale.values = scaleValues
    scale.keyTimes = keyTimes
    scale.duration = Self.diveDuration

    let move = CAKeyframeAnimation(keyPath: "position")
    move.values = positionValues
    move.keyTimes = keyTimes
    move.duration = Self.diveDuration

    // Late in the dive the focused square fades out as its sub-matrix fades in,
    // so its gaps open up and the cell becomes the matrix.
    let fadeOut = CAKeyframeAnimation(keyPath: "opacity")
    fadeOut.values = [1.0, 1.0, 0.0, 0.0]
    fadeOut.keyTimes = [0.0, 0.55, 0.9, 1.0]
    fadeOut.duration = Self.diveDuration
    let fadeIn = CAKeyframeAnimation(keyPath: "opacity")
    fadeIn.values = [0.0, 0.0, 1.0, 1.0]
    fadeIn.keyTimes = [0.0, 0.55, 0.9, 1.0]
    fadeIn.duration = Self.diveDuration

    CATransaction.begin()
    CATransaction.setCompletionBlock { [weak self] in self?.runDive(token) }
    grid.add(scale, forKey: "scale")
    grid.add(move, forKey: "position")
    cells[index].add(fadeOut, forKey: "fade")
    subGrid.add(fadeIn, forKey: "fade")
    CATransaction.commit()
  }
}
