import AppKit

/// A transient, floating HUD shown on the first ⌘Q press to confirm the user
/// really means to quit. It tells them to press ⌘Q again, then fades itself out
/// after the confirmation window lapses. Purely visual — the double-press logic
/// lives in `DFAppDelegate.requestQuit`; this just mirrors that window on screen
/// so a second press lands while the hint is still up.
final class QuitConfirmationHUD {
  static let shared = QuitConfirmationHUD()

  private var panel: NSPanel?
  private var dismissWorkItem: DispatchWorkItem?

  private init() {}

  /// Fade the hint in and schedule it to fade out after `duration` seconds.
  /// Calling again while visible just re-arms the auto-dismiss timer.
  func show(duration: TimeInterval) {
    let panel = panel ?? makePanel()
    self.panel = panel

    position(panel)
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.12
      ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
      panel.animator().alphaValue = 1
    }

    dismissWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.hide() }
    dismissWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
  }

  /// Fade out and tear down. Safe to call when nothing is showing.
  func hide() {
    dismissWorkItem?.cancel()
    dismissWorkItem = nil
    guard let panel = panel else { return }
    NSAnimationContext.runAnimationGroup(
      { ctx in
        ctx.duration = 0.18
        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
        panel.animator().alphaValue = 0
      },
      completionHandler: { [weak self] in
        panel.orderOut(nil)
        self?.panel = nil
      })
  }

  // MARK: - Construction

  private func makePanel() -> NSPanel {
    // Pure frame-based layout: no Auto Layout. The view assigned as a window's
    // contentView must keep translatesAutoresizingMaskIntoConstraints = true
    // (the default) so the window can size it — otherwise it collapses to a
    // tiny empty box.
    let label = NSTextField(labelWithAttributedString: hintText())
    label.sizeToFit()

    let hPad: CGFloat = 24
    let vPad: CGFloat = 15
    let size = NSSize(
      width: ceil(label.frame.width) + hPad * 2,
      height: ceil(label.frame.height) + vPad * 2)
    label.setFrameOrigin(NSPoint(x: hPad, y: vPad))

    let card = NSView(frame: NSRect(origin: .zero, size: size))
    card.wantsLayer = true
    card.layer?.backgroundColor = Theme.surface2.withAlphaComponent(0.96).cgColor
    card.layer?.cornerRadius = 12
    card.layer?.borderWidth = 1
    card.layer?.borderColor = Theme.surface3.cgColor
    card.addSubview(label)

    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [
      .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
    ]
    panel.contentView = card
    return panel
  }

  private func hintText() -> NSAttributedString {
    let result = NSMutableAttributedString()
    let regular: [NSAttributedString.Key: Any] = [
      .font: Theme.mono(13), .foregroundColor: Theme.text1,
    ]
    let key: [NSAttributedString.Key: Any] = [
      .font: Theme.mono(13, weight: .semibold), .foregroundColor: Theme.accent,
    ]
    result.append(NSAttributedString(string: "Press ", attributes: regular))
    result.append(NSAttributedString(string: "\u{2318}Q", attributes: key))
    result.append(NSAttributedString(string: " again to quit", attributes: regular))
    return result
  }

  /// Center horizontally and sit a little above center on the screen showing
  /// the key window (falling back to the main screen).
  private func position(_ panel: NSPanel) {
    let screen = NSApp.keyWindow?.screen ?? NSScreen.main
    guard let frame = screen?.visibleFrame else { return }
    let size = panel.frame.size
    let origin = NSPoint(
      x: frame.midX - size.width / 2,
      y: frame.midY - size.height / 2 + frame.height * 0.18)
    panel.setFrameOrigin(origin)
  }
}
