import AppKit

/// In-app editor window for the toolkit JSON config.
/// Singleton — reuses the same window across show/hide cycles.
final class DFToolkitEditor: NSObject, NSTextFieldDelegate, NSWindowDelegate {
  static let shared = DFToolkitEditor()

  private var window: NSWindow?
  private var editingCommands: [ToolkitManager.ToolkitCommand] = []
  private var stackView: NSStackView!
  private var pathLabel: NSTextField!

  private override init() { super.init() }

  func show() {
    if window == nil { buildWindow() }
    ToolkitManager.shared.ensureProjectConfig()
    loadCommands()
    rebuildRows()
    updatePathLabel()
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  // MARK: - Data

  private func loadCommands() {
    editingCommands = ToolkitManager.shared.commands
  }

  private func updatePathLabel() {
    pathLabel?.stringValue = ToolkitManager.shared.activeConfigPath
  }

  // MARK: - Row Building

  private func rebuildRows() {
    for v in stackView.arrangedSubviews {
      stackView.removeArrangedSubview(v)
      v.removeFromSuperview()
    }

    for (i, cmd) in editingCommands.enumerated() {
      let row = makeCommandRow(index: i, command: cmd)
      stackView.addArrangedSubview(row)
    }
  }

  private func makeCommandRow(index: Int, command: ToolkitManager.ToolkitCommand) -> NSView {
    let row = NSView()
    row.translatesAutoresizingMaskIntoConstraints = false
    row.wantsLayer = true
    row.layer?.backgroundColor = Theme.surface1.cgColor
    row.layer?.cornerRadius = 6

    // Icon preview
    let iconPreview = NSImageView()
    iconPreview.translatesAutoresizingMaskIntoConstraints = false
    iconPreview.contentTintColor = Theme.accent
    iconPreview.imageScaling = .scaleProportionallyDown
    if let img = NSImage(systemSymbolName: command.icon, accessibilityDescription: nil) {
      let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
      iconPreview.image = img.withSymbolConfiguration(config) ?? img
    }
    row.addSubview(iconPreview)

    // Icon text field
    let iconField = makeField(value: command.icon, placeholder: "SF Symbol name")
    iconField.tag = index
    iconField.identifier = NSUserInterfaceItemIdentifier("icon")
    iconField.delegate = self
    row.addSubview(iconField)

    // Vertical separator
    let sep1 = makeSep()
    row.addSubview(sep1)

    // Name field
    let nameField = makeField(value: command.name, placeholder: "Display name")
    nameField.font = Theme.mono(12, weight: .medium)
    nameField.tag = index
    nameField.identifier = NSUserInterfaceItemIdentifier("name")
    nameField.delegate = self
    row.addSubview(nameField)

    // Vertical separator
    let sep2 = makeSep()
    row.addSubview(sep2)

    // Command field
    let cmdField = makeField(value: command.command, placeholder: "Shell command")
    cmdField.textColor = Theme.text2
    cmdField.tag = index
    cmdField.identifier = NSUserInterfaceItemIdentifier("command")
    cmdField.delegate = self
    row.addSubview(cmdField)

    // Delete button
    let deleteBtn = NSButton(
      title: "", target: self, action: #selector(deleteRow(_:)))
    deleteBtn.image = NSImage(
      systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove")
    deleteBtn.isBordered = false
    deleteBtn.contentTintColor = Theme.text3
    deleteBtn.tag = index
    deleteBtn.translatesAutoresizingMaskIntoConstraints = false
    row.addSubview(deleteBtn)

    NSLayoutConstraint.activate([
      row.heightAnchor.constraint(equalToConstant: 38),

      nameField.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
      nameField.centerYAnchor.constraint(equalTo: row.centerYAnchor),
      nameField.widthAnchor.constraint(equalToConstant: 120),

      sep1.leadingAnchor.constraint(equalTo: nameField.trailingAnchor, constant: 8),
      sep1.topAnchor.constraint(equalTo: row.topAnchor, constant: 8),
      sep1.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -8),
      sep1.widthAnchor.constraint(equalToConstant: 1),

      iconPreview.leadingAnchor.constraint(equalTo: sep1.trailingAnchor, constant: 8),
      iconPreview.centerYAnchor.constraint(equalTo: row.centerYAnchor),
      iconPreview.widthAnchor.constraint(equalToConstant: 20),
      iconPreview.heightAnchor.constraint(equalToConstant: 20),

      iconField.leadingAnchor.constraint(equalTo: iconPreview.trailingAnchor, constant: 6),
      iconField.centerYAnchor.constraint(equalTo: row.centerYAnchor),
      iconField.widthAnchor.constraint(equalToConstant: 110),

      sep2.leadingAnchor.constraint(equalTo: iconField.trailingAnchor, constant: 8),
      sep2.topAnchor.constraint(equalTo: row.topAnchor, constant: 8),
      sep2.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -8),
      sep2.widthAnchor.constraint(equalToConstant: 1),

      cmdField.leadingAnchor.constraint(equalTo: sep2.trailingAnchor, constant: 8),
      cmdField.centerYAnchor.constraint(equalTo: row.centerYAnchor),
      cmdField.trailingAnchor.constraint(equalTo: deleteBtn.leadingAnchor, constant: -8),

      deleteBtn.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
      deleteBtn.centerYAnchor.constraint(equalTo: row.centerYAnchor),
      deleteBtn.widthAnchor.constraint(equalToConstant: 18),
      deleteBtn.heightAnchor.constraint(equalToConstant: 18),
    ])

    return row
  }

  private func makeField(value: String, placeholder: String) -> NSTextField {
    let field = NSTextField()
    field.stringValue = value
    field.placeholderString = placeholder
    field.font = Theme.mono(12)
    field.textColor = Theme.text1
    field.backgroundColor = .clear
    field.drawsBackground = false
    field.isBordered = false
    field.isBezeled = false
    field.isEditable = true
    field.focusRingType = .none
    field.translatesAutoresizingMaskIntoConstraints = false
    field.cell?.lineBreakMode = .byTruncatingTail
    return field
  }

  private func makeSep() -> NSView {
    let v = NSView()
    v.translatesAutoresizingMaskIntoConstraints = false
    v.wantsLayer = true
    v.layer?.backgroundColor = Theme.surface3.cgColor
    return v
  }

  // MARK: - NSTextFieldDelegate

  func controlTextDidEndEditing(_ obj: Notification) {
    guard let field = obj.object as? NSTextField else { return }
    let idx = field.tag
    guard idx >= 0, idx < editingCommands.count else { return }

    switch field.identifier?.rawValue {
    case "name": editingCommands[idx].name = field.stringValue
    case "command": editingCommands[idx].command = field.stringValue
    case "icon":
      editingCommands[idx].icon = field.stringValue
      // Update the icon preview in the same row
      if let row = field.superview,
        let preview = row.subviews.compactMap({ $0 as? NSImageView }).first
      {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let img = NSImage(
          systemSymbolName: field.stringValue, accessibilityDescription: nil)
        preview.image = img?.withSymbolConfiguration(config) ?? img
      }
    default: break
    }
  }

  private func save() {
    let valid = editingCommands.filter { !$0.name.isEmpty && !$0.command.isEmpty }
    ToolkitManager.shared.saveConfig(commands: valid)
  }

  /// Flush the active text field editor so any in-progress edits are committed
  /// to `editingCommands` before saving.
  private func commitActiveField() {
    guard let win = window, let fieldEditor = win.fieldEditor(false, for: nil) else { return }
    win.makeFirstResponder(nil)
    _ = fieldEditor  // silence unused warning
  }

  // MARK: - NSWindowDelegate

  func windowWillClose(_ notification: Notification) {
    commitActiveField()
    save()
  }

  // MARK: - Actions

  @objc private func addRow() {
    editingCommands.append(
      ToolkitManager.ToolkitCommand(
        name: "New Command", command: "echo hello", icon: "terminal"))
    rebuildRows()
    save()
  }

  @objc private func deleteRow(_ sender: NSButton) {
    let idx = sender.tag
    guard idx >= 0, idx < editingCommands.count else { return }
    editingCommands.remove(at: idx)
    rebuildRows()
    save()
  }

  // MARK: - Window

  private func buildWindow() {
    let win = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    win.title = "Toolkit Editor"
    win.titlebarAppearsTransparent = true
    win.titleVisibility = .hidden
    win.backgroundColor = Theme.bg
    win.isReleasedWhenClosed = false
    win.minSize = NSSize(width: 520, height: 280)
    win.delegate = self
    win.center()

    let container = NSView()
    container.translatesAutoresizingMaskIntoConstraints = false
    container.wantsLayer = true
    container.layer?.backgroundColor = Theme.bg.cgColor
    win.contentView = container

    // Header
    let titleLabel = NSTextField(labelWithString: "TOOLKIT EDITOR")
    titleLabel.font = Theme.mono(12, weight: .medium)
    titleLabel.textColor = Theme.text1
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(titleLabel)

    let pLabel = NSTextField(labelWithString: "")
    pLabel.font = Theme.mono(10)
    pLabel.textColor = Theme.text3
    pLabel.lineBreakMode = .byTruncatingMiddle
    pLabel.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(pLabel)
    pathLabel = pLabel

    // Column headers
    let colHeaders = NSView()
    colHeaders.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(colHeaders)

    func colLabel(_ text: String) -> NSTextField {
      let l = NSTextField(labelWithString: text)
      l.font = Theme.mono(9, weight: .medium)
      l.textColor = Theme.text3
      l.translatesAutoresizingMaskIntoConstraints = false
      return l
    }

    let nameH = colLabel("Name")
    colHeaders.addSubview(nameH)
    let iconH = colLabel("Icon")
    colHeaders.addSubview(iconH)
    let cmdH = colLabel("Command")
    colHeaders.addSubview(cmdH)

    NSLayoutConstraint.activate([
      colHeaders.heightAnchor.constraint(equalToConstant: 16),
      nameH.leadingAnchor.constraint(equalTo: colHeaders.leadingAnchor, constant: 10),
      nameH.centerYAnchor.constraint(equalTo: colHeaders.centerYAnchor),
      iconH.leadingAnchor.constraint(equalTo: colHeaders.leadingAnchor, constant: 147),
      iconH.centerYAnchor.constraint(equalTo: colHeaders.centerYAnchor),
      cmdH.leadingAnchor.constraint(equalTo: colHeaders.leadingAnchor, constant: 300),
      cmdH.centerYAnchor.constraint(equalTo: colHeaders.centerYAnchor),
    ])

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

    stackView = stack

    // Bottom bar
    let bottomBar = NSView()
    bottomBar.translatesAutoresizingMaskIntoConstraints = false
    bottomBar.wantsLayer = true
    bottomBar.layer?.backgroundColor = Theme.surface1.cgColor
    container.addSubview(bottomBar)

    // Separator above bottom bar
    let barSep = NSView()
    barSep.translatesAutoresizingMaskIntoConstraints = false
    barSep.wantsLayer = true
    barSep.layer?.backgroundColor = Theme.surface3.cgColor
    container.addSubview(barSep)

    let addBtn = NSButton(title: "+ Add Command", target: self, action: #selector(addRow))
    addBtn.isBordered = false
    addBtn.font = Theme.mono(11, weight: .medium)
    addBtn.contentTintColor = Theme.accent
    addBtn.translatesAutoresizingMaskIntoConstraints = false
    bottomBar.addSubview(addBtn)

    NSLayoutConstraint.activate([
      titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 36),
      titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),

      pLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
      pLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
      pLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

      colHeaders.topAnchor.constraint(equalTo: pLabel.bottomAnchor, constant: 14),
      colHeaders.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
      colHeaders.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

      scrollView.topAnchor.constraint(equalTo: colHeaders.bottomAnchor, constant: 6),
      scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
      scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
      scrollView.bottomAnchor.constraint(equalTo: barSep.topAnchor),

      docView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
      docView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
      docView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),

      stack.topAnchor.constraint(equalTo: docView.topAnchor, constant: 2),
      stack.leadingAnchor.constraint(equalTo: docView.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: docView.trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: docView.bottomAnchor, constant: -2),

      barSep.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      barSep.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      barSep.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
      barSep.heightAnchor.constraint(equalToConstant: 1),

      bottomBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      bottomBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      bottomBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      bottomBar.heightAnchor.constraint(equalToConstant: 44),

      addBtn.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 14),
      addBtn.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
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
}

// MARK: - Flipped helpers for top-down scroll layout

private final class FlippedClipView: NSClipView {
  override var isFlipped: Bool { true }
}

private final class FlippedDocView: NSView {
  override var isFlipped: Bool { true }
}
