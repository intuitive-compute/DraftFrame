import AppKit

/// Help window listing all keyboard shortcuts.
/// Singleton — reuses the same window across show/hide cycles.
final class DFShortcutsWindow: NSObject, NSWindowDelegate {
  static let shared = DFShortcutsWindow()

  private var window: NSWindow?

  private override init() { super.init() }

  func show() {
    if window == nil { buildWindow() }
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  // MARK: - Data

  private struct Shortcut {
    let keys: [String]
    let detail: String
  }

  private struct Section {
    let title: String
    let shortcuts: [Shortcut]
  }

  private let sections: [Section] = [
    Section(
      title: "General",
      shortcuts: [
        Shortcut(keys: ["⌘", "O"], detail: "Open project"),
        Shortcut(keys: ["⌘", "Q"], detail: "Quit DraftFrame"),
      ]),
    Section(
      title: "Sessions",
      shortcuts: [
        Shortcut(keys: ["⌘", "T"], detail: "New session"),
        Shortcut(keys: ["⌘", "N"], detail: "New session with worktree"),
        Shortcut(keys: ["⌘", "W"], detail: "Close session"),
        Shortcut(keys: ["⌘", "1–9"], detail: "Switch to session 1–9"),
      ]),
    Section(
      title: "View",
      shortcuts: [
        Shortcut(keys: ["⌘", "D"], detail: "Toggle dashboard"),
        Shortcut(keys: ["⌘", "\\"], detail: "Toggle sidebar"),
        Shortcut(keys: ["⌘", "E"], detail: "Toggle code editor"),
        Shortcut(keys: ["⌘", "`"], detail: "Toggle quick terminal"),
      ]),
    Section(
      title: "Terminal",
      shortcuts: [
        Shortcut(keys: ["⌘", "⇧", "V"], detail: "Hold for voice transcription"),
        Shortcut(keys: ["⇧", "↩"], detail: "Insert newline instead of submitting"),
        Shortcut(keys: ["⌘", "Click"], detail: "Open link, file path, or PR/issue ref"),
      ]),
    Section(
      title: "Code Editor",
      shortcuts: [
        Shortcut(keys: ["⌘", "F"], detail: "Toggle search"),
        Shortcut(keys: ["⎋"], detail: "Close search"),
      ]),
  ]

  // MARK: - Window

  private func buildWindow() {
    let win = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1020, height: 540),
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    win.title = "Keyboard Shortcuts"
    win.titlebarAppearsTransparent = true
    win.titleVisibility = .hidden
    win.backgroundColor = Theme.bg
    win.isReleasedWhenClosed = false
    win.minSize = NSSize(width: 760, height: 360)
    win.delegate = self
    win.center()

    let container = NSView()
    container.translatesAutoresizingMaskIntoConstraints = false
    container.wantsLayer = true
    container.layer?.backgroundColor = Theme.bg.cgColor
    win.contentView = container

    // Header
    let titleLabel = NSTextField(labelWithString: "KEYBOARD SHORTCUTS")
    titleLabel.font = Theme.mono(14, weight: .medium)
    titleLabel.textColor = Theme.text1
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(titleLabel)

    // Scroll view
    let scrollView = NSScrollView()
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.scrollerStyle = .overlay
    container.addSubview(scrollView)

    let stack = NSStackView()
    stack.orientation = .vertical
    stack.spacing = 6
    stack.alignment = .leading
    stack.translatesAutoresizingMaskIntoConstraints = false

    let flipper = FlippedClipView()
    flipper.drawsBackground = false
    scrollView.contentView = flipper

    let docView = FlippedDocView()
    docView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.documentView = docView
    docView.addSubview(stack)

    for (i, section) in sections.enumerated() {
      stack.addArrangedSubview(makeSectionHeader(section.title, isFirst: i == 0))

      // Lay shortcuts out two per row: keys + description | keys + description.
      var idx = 0
      while idx < section.shortcuts.count {
        let rowStack = NSStackView()
        rowStack.orientation = .horizontal
        rowStack.spacing = 8
        rowStack.distribution = .fillEqually
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        let left = makeShortcutItem(section.shortcuts[idx])
        rowStack.addArrangedSubview(left)
        let right: NSView
        if idx + 1 < section.shortcuts.count {
          right = makeShortcutItem(section.shortcuts[idx + 1])
        } else {
          // Pad odd rows so the lone item keeps half width
          right = NSView()
          right.translatesAutoresizingMaskIntoConstraints = false
        }
        rowStack.addArrangedSubview(right)

        stack.addArrangedSubview(rowStack)
        NSLayoutConstraint.activate([
          rowStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
          // Force exact halves regardless of label content pressure
          left.widthAnchor.constraint(equalTo: right.widthAnchor),
        ])
        idx += 2
      }
    }

    NSLayoutConstraint.activate([
      titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 36),
      titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),

      scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
      scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
      scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
      scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),

      docView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
      docView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
      docView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),

      stack.topAnchor.constraint(equalTo: docView.topAnchor, constant: 2),
      stack.leadingAnchor.constraint(equalTo: docView.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: docView.trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: docView.bottomAnchor, constant: -2),
    ])

    // Escape key closes the window
    let escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak win] event in
      if event.keyCode == 53, win?.isKeyWindow == true {
        win?.close()
        return nil
      }
      return event
    }
    // Store so it lives as long as the window
    objc_setAssociatedObject(win, "escMonitor", escMonitor, .OBJC_ASSOCIATION_RETAIN)

    self.window = win
  }

  // MARK: - Row Building

  private func makeSectionHeader(_ title: String, isFirst: Bool) -> NSView {
    let header = NSView()
    header.translatesAutoresizingMaskIntoConstraints = false

    let label = NSTextField(labelWithString: title.uppercased())
    label.font = Theme.mono(11, weight: .medium)
    label.textColor = Theme.text3
    label.translatesAutoresizingMaskIntoConstraints = false
    header.addSubview(label)

    NSLayoutConstraint.activate([
      header.heightAnchor.constraint(equalToConstant: isFirst ? 24 : 40),
      label.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
      label.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -4),
    ])
    return header
  }

  /// One cell: a run of keycaps joined by "+", then the description.
  private func makeShortcutItem(_ shortcut: Shortcut) -> NSView {
    let item = NSView()
    item.translatesAutoresizingMaskIntoConstraints = false
    item.wantsLayer = true
    item.layer?.backgroundColor = Theme.surface1.cgColor
    item.layer?.cornerRadius = 6

    let keysStack = NSStackView()
    keysStack.orientation = .horizontal
    keysStack.spacing = 6
    keysStack.alignment = .centerY
    keysStack.translatesAutoresizingMaskIntoConstraints = false
    item.addSubview(keysStack)

    for (i, key) in shortcut.keys.enumerated() {
      if i > 0 {
        let plus = NSTextField(labelWithString: "+")
        plus.font = Theme.mono(13, weight: .medium)
        plus.textColor = Theme.text3
        keysStack.addArrangedSubview(plus)
      }
      keysStack.addArrangedSubview(makeKeyCap(key))
    }

    let detailLabel = NSTextField(labelWithString: shortcut.detail)
    detailLabel.font = Theme.mono(13)
    detailLabel.textColor = Theme.text2
    detailLabel.lineBreakMode = .byTruncatingTail
    // Truncate rather than push the cell wider than its half of the row
    detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    detailLabel.translatesAutoresizingMaskIntoConstraints = false
    item.addSubview(detailLabel)

    NSLayoutConstraint.activate([
      item.heightAnchor.constraint(equalToConstant: 46),

      keysStack.leadingAnchor.constraint(equalTo: item.leadingAnchor, constant: 12),
      keysStack.centerYAnchor.constraint(equalTo: item.centerYAnchor),
      keysStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),

      detailLabel.leadingAnchor.constraint(equalTo: item.leadingAnchor, constant: 170),
      detailLabel.trailingAnchor.constraint(equalTo: item.trailingAnchor, constant: -12),
      detailLabel.centerYAnchor.constraint(equalTo: item.centerYAnchor),
    ])
    return item
  }

  /// A single bordered keycap.
  private func makeKeyCap(_ key: String) -> NSView {
    let cap = NSView()
    cap.translatesAutoresizingMaskIntoConstraints = false
    cap.wantsLayer = true
    cap.layer?.backgroundColor = Theme.surface2.cgColor
    cap.layer?.cornerRadius = 5
    cap.layer?.borderWidth = 1
    cap.layer?.borderColor = Theme.surface3.cgColor

    let label = NSTextField(labelWithString: key)
    label.font = Theme.mono(14, weight: .medium)
    label.textColor = Theme.accent
    label.alignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false
    cap.addSubview(label)

    NSLayoutConstraint.activate([
      cap.heightAnchor.constraint(equalToConstant: 28),
      cap.widthAnchor.constraint(greaterThanOrEqualToConstant: 28),
      label.leadingAnchor.constraint(equalTo: cap.leadingAnchor, constant: 7),
      label.trailingAnchor.constraint(equalTo: cap.trailingAnchor, constant: -7),
      label.centerYAnchor.constraint(equalTo: cap.centerYAnchor),
    ])
    return cap
  }
}

// MARK: - Flipped helpers for top-down scroll layout

private final class FlippedClipView: NSClipView {
  override var isFlipped: Bool { true }
}

private final class FlippedDocView: NSView {
  override var isFlipped: Bool { true }
}
