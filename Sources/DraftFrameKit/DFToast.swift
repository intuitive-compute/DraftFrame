import AppKit

/// Transient error banner shown at the bottom of a window, floating just
/// above the status bar. Fades in, auto-dismisses after `duration` seconds,
/// and can be dismissed early with a click. Showing a new toast replaces any
/// toast currently on screen.
enum DFToast {
  private static weak var current: ToastView?

  static func show(_ message: String, in window: NSWindow, duration: TimeInterval = 5) {
    guard let content = window.contentView else { return }
    current?.dismiss(animated: false)

    let toast = ToastView(message: message)
    current = toast
    content.addSubview(toast)
    NSLayoutConstraint.activate([
      toast.centerXAnchor.constraint(equalTo: content.centerXAnchor),
      toast.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -40),
      toast.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -80),
    ])

    toast.alphaValue = 0
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.2
      toast.animator().alphaValue = 1
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak toast] in
      toast?.dismiss(animated: true)
    }
  }

  private final class ToastView: NSView {
    init(message: String) {
      super.init(frame: .zero)
      translatesAutoresizingMaskIntoConstraints = false
      wantsLayer = true
      layer?.backgroundColor = Theme.surface2.cgColor
      layer?.cornerRadius = 6
      layer?.borderWidth = 1
      layer?.borderColor = Theme.red.withAlphaComponent(0.4).cgColor

      let icon = NSImageView()
      icon.image = NSImage(
        systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Error")
      icon.contentTintColor = Theme.red
      icon.translatesAutoresizingMaskIntoConstraints = false

      let label = NSTextField(wrappingLabelWithString: message)
      label.font = Theme.mono(11)
      label.textColor = Theme.text1
      label.translatesAutoresizingMaskIntoConstraints = false

      addSubview(icon)
      addSubview(label)
      NSLayoutConstraint.activate([
        icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
        icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        icon.widthAnchor.constraint(equalToConstant: 14),
        icon.heightAnchor.constraint(equalToConstant: 14),
        label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
        label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
        label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
      ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
      dismiss(animated: true)
    }

    func dismiss(animated: Bool) {
      guard superview != nil else { return }
      if !animated {
        removeFromSuperview()
        return
      }
      NSAnimationContext.runAnimationGroup(
        { ctx in
          ctx.duration = 0.25
          animator().alphaValue = 0
        },
        completionHandler: { [weak self] in
          self?.removeFromSuperview()
        })
    }
  }
}
