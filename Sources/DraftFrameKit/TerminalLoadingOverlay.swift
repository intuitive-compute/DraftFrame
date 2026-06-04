import AppKit

/// Opaque overlay shown over a terminal while its shell (or Claude) boots.
/// Hides the noisy startup output and swallows all keyboard/mouse input so
/// typed-ahead characters can't interleave with the bootstrap command (which
/// would corrupt the `cd` path). Removed by `fadeOut` once the owner decides
/// the terminal is ready.
final class TerminalLoadingOverlay: NSView {
  private let message: String
  private var dotViews: [NSView] = []

  init(message: String) {
    self.message = message
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = Theme.bg.cgColor
    buildContent()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  private func buildContent() {
    // Three accent dots with a staggered opacity pulse — matches the
    // breathing-dot idiom used on the session cards.
    let dots = NSStackView()
    dots.orientation = .horizontal
    dots.spacing = 8
    dots.translatesAutoresizingMaskIntoConstraints = false
    for _ in 0..<3 {
      let dot = NSView()
      dot.wantsLayer = true
      dot.translatesAutoresizingMaskIntoConstraints = false
      dot.layer?.backgroundColor = Theme.accent.cgColor
      dot.layer?.cornerRadius = 4
      NSLayoutConstraint.activate([
        dot.widthAnchor.constraint(equalToConstant: 8),
        dot.heightAnchor.constraint(equalToConstant: 8),
      ])
      dots.addArrangedSubview(dot)
      dotViews.append(dot)
    }

    let label = NSTextField(labelWithString: message)
    label.font = Theme.mono(11)
    label.textColor = Theme.text3
    label.alignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false

    addSubview(dots)
    addSubview(label)
    NSLayoutConstraint.activate([
      dots.centerXAnchor.constraint(equalTo: centerXAnchor),
      dots.centerYAnchor.constraint(equalTo: centerYAnchor),
      label.centerXAnchor.constraint(equalTo: centerXAnchor),
      label.topAnchor.constraint(equalTo: dots.bottomAnchor, constant: 14),
    ])
  }

  /// (Re)start the dot pulse. CoreAnimation drops infinite animations when a
  /// layer leaves the window, so re-apply them whenever we're remounted —
  /// the parent panes detach and re-add the overlay as they swap terminals.
  private func startAnimating() {
    for (i, dot) in dotViews.enumerated() {
      let pulse = CABasicAnimation(keyPath: "opacity")
      pulse.fromValue = 0.25
      pulse.toValue = 1.0
      pulse.duration = 0.6
      pulse.autoreverses = true
      pulse.repeatCount = .infinity
      pulse.beginTime = CACurrentMediaTime() + Double(i) * 0.18
      pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      dot.layer?.add(pulse, forKey: "pulse")
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil { startAnimating() }
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
