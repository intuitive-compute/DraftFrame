import AppKit

/// The themed "New Group" / "Edit Group" sheet for the session bar: a name
/// field, a row of color swatches, and (when creating) the Status and
/// Project preset buttons. Mirrors the look of `NewWorktreeDialog`.
@MainActor
enum SessionGroupDialog {
  enum Result {
    /// Create or save a group with this name and color.
    case group(name: String, color: NSColor)
    /// Apply the Status preset (three lifecycle groups).
    case statusPreset
    /// Apply the Project preset (one group per repository).
    case projectPreset
  }

  /// Presents a create sheet. `completion` is called only on confirm.
  static func presentCreate(on window: NSWindow, completion: @escaping (Result) -> Void) {
    Sheet(
      title: "New Session Group",
      message: "Drag sessions onto the group to add them.",
      initialName: "",
      initialColor: SessionGrouping.randomColors(
        count: 1, avoiding: SessionManager.shared.groups.map(\.color))[0],
      showsPresets: true, confirmTitle: "Create", completion: completion
    ).present(on: window)
  }

  /// Presents an edit sheet prefilled from `group`.
  static func presentEdit(
    on window: NSWindow, group: SessionGroup, completion: @escaping (Result) -> Void
  ) {
    Sheet(
      title: "Edit Session Group",
      message: "Change the group's name or color.",
      initialName: group.name, initialColor: group.color,
      showsPresets: false, confirmTitle: "Save", completion: completion
    ).present(on: window)
  }

  // MARK: - Sheet

  @MainActor
  private final class Sheet: NSObject {
    private static var active: [Sheet] = []

    private let sheet: NSWindow
    private weak var parent: NSWindow?
    private let completion: (Result) -> Void

    private let nameField = NSTextField()
    private var swatches: [SwatchButton] = []
    private var selectedColor: NSColor

    init(
      title: String, message: String, initialName: String, initialColor: NSColor,
      showsPresets: Bool, confirmTitle: String, completion: @escaping (Result) -> Void
    ) {
      self.completion = completion
      self.selectedColor = initialColor
      sheet = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
        styleMask: [.titled, .fullSizeContentView],
        backing: .buffered, defer: false)
      super.init()

      sheet.titleVisibility = .hidden
      sheet.titlebarAppearsTransparent = true
      sheet.appearance = NSAppearance(named: .darkAqua)
      sheet.backgroundColor = Theme.surface1

      nameField.stringValue = initialName
      buildContent(
        title: title, message: message, showsPresets: showsPresets, confirmTitle: confirmTitle)
      selectColor(initialColor)
    }

    func present(on window: NSWindow) {
      Self.active.append(self)
      parent = window
      sheet.initialFirstResponder = nameField
      window.beginSheet(sheet)
    }

    // MARK: Layout

    private func buildContent(
      title: String, message: String, showsPresets: Bool, confirmTitle: String
    ) {
      guard let content = sheet.contentView else { return }

      let titleLabel = NSTextField(labelWithString: title)
      titleLabel.font = Theme.mono(14, weight: .semibold)
      titleLabel.textColor = Theme.text1

      let messageLabel = NSTextField(wrappingLabelWithString: message)
      messageLabel.font = Theme.mono(11)
      messageLabel.textColor = Theme.text2

      nameField.font = Theme.mono(12)
      nameField.placeholderString = "Group name"
      let nameRow = labeledRow(label: "Name", view: nameField)
      nameRow.heightAnchor.constraint(equalToConstant: 24).isActive = true

      let swatchRow = NSStackView()
      swatchRow.orientation = .horizontal
      swatchRow.spacing = 6
      for color in SessionGrouping.palette {
        let swatch = SwatchButton(color: color) { [weak self] c in self?.selectColor(c) }
        swatches.append(swatch)
        swatchRow.addArrangedSubview(swatch)
      }
      let colorRow = labeledRow(label: "Color", view: swatchRow)

      let cancelButton = NSButton(
        title: "Cancel", target: self, action: #selector(cancelClicked))
      cancelButton.bezelStyle = .rounded
      cancelButton.keyEquivalent = "\u{1b}"

      let confirmButton = NSButton(
        title: confirmTitle, target: self, action: #selector(confirmClicked))
      confirmButton.bezelStyle = .rounded
      confirmButton.keyEquivalent = "\r"
      confirmButton.bezelColor = Theme.accent

      let buttonRow = NSStackView(views: [NSView(), cancelButton, confirmButton])
      buttonRow.orientation = .horizontal
      buttonRow.spacing = 8

      var views: [NSView] = [titleLabel, messageLabel, nameRow, colorRow]
      var presetsRow: NSView?
      if showsPresets {
        let presetsLabel = NSTextField(labelWithString: "Presets")
        presetsLabel.font = Theme.mono(10)
        presetsLabel.textColor = Theme.text3

        let statusButton = NSButton(
          title: "Status", target: self, action: #selector(statusPresetClicked))
        statusButton.bezelStyle = .rounded
        statusButton.toolTip = "Create In Progress, In QA, and Done groups"
        let projectButton = NSButton(
          title: "Project", target: self, action: #selector(projectPresetClicked))
        projectButton.bezelStyle = .rounded
        projectButton.toolTip = "Group every session by the repository it lives in"
        for b in [statusButton, projectButton] {
          b.font = Theme.mono(11)
          b.controlSize = .small
        }

        let row = NSStackView(views: [presetsLabel, statusButton, projectButton, NSView()])
        row.orientation = .horizontal
        row.spacing = 8
        presetsRow = row
        views.append(row)
      }
      views.append(buttonRow)

      let stack = NSStackView(views: views)
      stack.orientation = .vertical
      stack.alignment = .leading
      stack.spacing = 10
      stack.setCustomSpacing(6, after: titleLabel)
      stack.setCustomSpacing(14, after: messageLabel)
      stack.setCustomSpacing(16, after: colorRow)
      if let presetsRow = presetsRow { stack.setCustomSpacing(16, after: presetsRow) }
      stack.translatesAutoresizingMaskIntoConstraints = false
      content.addSubview(stack)

      var constraints = [
        stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
        stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
        stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        nameRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        colorRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        content.widthAnchor.constraint(equalToConstant: 400),
      ]
      if let presetsRow = presetsRow {
        constraints.append(presetsRow.widthAnchor.constraint(equalTo: stack.widthAnchor))
      }
      NSLayoutConstraint.activate(constraints)
      sheet.setContentSize(content.fittingSize)
    }

    private func labeledRow(label: String, view: NSView) -> NSView {
      let row = NSView()
      let lbl = NSTextField(labelWithString: label)
      lbl.font = Theme.mono(11)
      lbl.textColor = Theme.text3
      lbl.alignment = .right
      for v in [lbl, view] {
        v.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(v)
      }
      NSLayoutConstraint.activate([
        lbl.leadingAnchor.constraint(equalTo: row.leadingAnchor),
        lbl.widthAnchor.constraint(equalToConstant: 48),
        lbl.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        view.leadingAnchor.constraint(equalTo: lbl.trailingAnchor, constant: 8),
        view.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
        view.topAnchor.constraint(equalTo: row.topAnchor),
        view.bottomAnchor.constraint(equalTo: row.bottomAnchor),
      ])
      return row
    }

    // MARK: Behavior

    private func selectColor(_ color: NSColor) {
      selectedColor = color
      let hex = SessionGrouping.hexString(color)
      for s in swatches { s.isSelected = SessionGrouping.hexString(s.color) == hex }
    }

    @objc private func confirmClicked() {
      let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else {
        NSSound.beep()
        sheet.makeFirstResponder(nameField)
        return
      }
      end(with: .group(name: name, color: selectedColor))
    }

    @objc private func statusPresetClicked() { end(with: .statusPreset) }
    @objc private func projectPresetClicked() { end(with: .projectPreset) }
    @objc private func cancelClicked() { end(with: nil) }

    private func end(with result: Result?) {
      parent?.endSheet(sheet)
      Self.active.removeAll { $0 === self }
      if let result = result { completion(result) }
    }
  }

  /// A round color swatch; the selected one gets a white ring.
  private final class SwatchButton: NSView {
    let color: NSColor
    private let onPick: (NSColor) -> Void
    var isSelected = false {
      didSet {
        layer?.borderWidth = isSelected ? 2 : 0
      }
    }

    init(color: NSColor, onPick: @escaping (NSColor) -> Void) {
      self.color = color
      self.onPick = onPick
      super.init(frame: .zero)
      wantsLayer = true
      layer?.backgroundColor = color.cgColor
      layer?.cornerRadius = 10
      layer?.borderColor = NSColor.white.cgColor
      translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        widthAnchor.constraint(equalToConstant: 20),
        heightAnchor.constraint(equalToConstant: 20),
      ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
      addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
      onPick(color)
    }
  }
}
