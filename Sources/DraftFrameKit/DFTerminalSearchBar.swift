import AppKit
import SwiftTerm

/// Floating find bar for terminals. One instance sits in the top-right corner
/// of each window that hosts terminals — the main window and the quick
/// terminal — and drives SwiftTerm's search engine on whichever terminal its
/// owner points it at. Typing searches incrementally; Enter / Shift+Enter (or
/// the ▲/▼ buttons) step to the next / previous match, which SwiftTerm
/// selects and scrolls into view; Escape or × closes the bar and hands focus
/// back to the terminal.
final class DFTerminalSearchBar: NSView, NSTextFieldDelegate {

  /// A find request routed from a shortcut or menu item.
  enum Action {
    /// Cmd+F: open the bar, or re-focus its field (text selected) if open.
    case open
    /// Cmd+G: step to the next match (opens the bar first if it's closed).
    case next
    /// Cmd+Shift+G: step to the previous match (opens the bar if closed).
    case previous
  }

  /// The terminal being searched. Owners retarget this as the active
  /// session / tab / pane changes; an open bar re-runs its search on the new
  /// target so the current match stays visible there too.
  weak var target: ClaudeTerminalView? {
    didSet {
      guard oldValue !== target else { return }
      retargeted(from: oldValue)
    }
  }

  /// Whether the bar is on screen.
  var isOpen: Bool { !isHidden }

  /// Current status text ("No matches" or empty). Read by QABridge.
  var statusText: String { statusLabel.stringValue }

  /// Whether the caret is in the search field. Read by QABridge.
  var isFieldFocused: Bool {
    guard let editor = field.currentEditor() else { return false }
    return window?.firstResponder === editor
  }

  /// Result of the most recent search, if one has run since the term last
  /// changed. Read by QABridge.
  private(set) var lastFound: Bool?

  private let field = NSTextField()
  private let statusLabel = NSTextField(labelWithString: "")

  private static let height: CGFloat = 28

  override init(frame: NSRect) {
    super.init(frame: frame)
    translatesAutoresizingMaskIntoConstraints = false
    isHidden = true

    wantsLayer = true
    layer?.backgroundColor = Theme.surface2.cgColor
    layer?.cornerRadius = 6
    layer?.borderWidth = 1
    layer?.borderColor = Theme.surface3.cgColor
    // The bar floats over window content (and the titlebar band), so cast a
    // soft shadow to lift it off whatever is underneath.
    layer?.masksToBounds = false
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowOpacity = 0.45
    layer?.shadowRadius = 8
    layer?.shadowOffset = CGSize(width: 0, height: -2)

    field.placeholderAttributedString = NSAttributedString(
      string: "Find in terminal",
      attributes: [.font: Theme.mono(12), .foregroundColor: Theme.text3])
    field.font = Theme.mono(12)
    field.textColor = Theme.text1
    field.backgroundColor = Theme.surface1
    field.drawsBackground = true
    field.isBezeled = false
    field.isBordered = false
    field.focusRingType = .none
    field.lineBreakMode = .byClipping
    field.cell?.usesSingleLineMode = true
    field.cell?.isScrollable = true
    field.wantsLayer = true
    field.layer?.cornerRadius = 4
    field.layer?.masksToBounds = true
    field.delegate = self
    field.translatesAutoresizingMaskIntoConstraints = false
    addSubview(field)

    statusLabel.font = Theme.mono(10)
    statusLabel.textColor = Theme.text2
    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    addSubview(statusLabel)

    let prevBtn = makeButton("\u{25B2}", action: #selector(findPreviousClicked), tip: "Previous match (⇧⌘G)")
    let nextBtn = makeButton("\u{25BC}", action: #selector(findNextClicked), tip: "Next match (⌘G)")
    let closeBtn = makeButton("\u{00D7}", action: #selector(closeClicked), tip: "Close search (⎋)")
    closeBtn.font = Theme.mono(12, weight: .medium)
    closeBtn.contentTintColor = Theme.text3
    addSubview(prevBtn)
    addSubview(nextBtn)
    addSubview(closeBtn)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: Self.height),

      field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
      field.centerYAnchor.constraint(equalTo: centerYAnchor),
      field.widthAnchor.constraint(equalToConstant: 170),
      field.heightAnchor.constraint(equalToConstant: 20),

      statusLabel.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 6),
      statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

      prevBtn.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 4),
      prevBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
      prevBtn.widthAnchor.constraint(equalToConstant: 20),

      nextBtn.leadingAnchor.constraint(equalTo: prevBtn.trailingAnchor),
      nextBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
      nextBtn.widthAnchor.constraint(equalToConstant: 20),

      closeBtn.leadingAnchor.constraint(equalTo: nextBtn.trailingAnchor, constant: 2),
      closeBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
      closeBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
      closeBtn.widthAnchor.constraint(equalToConstant: 20),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  /// The bar lives in the window's titlebar band (both host windows use
  /// `.fullSizeContentView`), where AppKit treats clicks as a window drag
  /// unless the view underneath refuses it.
  override var mouseDownCanMoveWindow: Bool { false }

  private func makeButton(_ title: String, action: Selector, tip: String) -> NSButton {
    let btn = NSButton(title: title, target: self, action: action)
    btn.isBordered = false
    btn.font = Theme.mono(10)
    btn.contentTintColor = Theme.text2
    btn.toolTip = tip
    btn.translatesAutoresizingMaskIntoConstraints = false
    return btn
  }

  // MARK: - Actions

  func perform(_ action: Action) {
    switch action {
    case .open: show()
    case .next: findNext()
    case .previous: findPrevious()
    }
  }

  /// Open the bar (if closed) and put the caret in the field with any
  /// previous term selected, so typing replaces it and Enter reuses it.
  func show() {
    guard target != nil else { return }
    isHidden = false
    focusField()
  }

  /// Close the bar, drop the search selection, and return focus to the
  /// terminal. The term is kept so reopening (or Cmd+G) reuses it.
  func hide() {
    guard isOpen else { return }
    isHidden = true
    setStatus(nil)
    lastFound = nil
    target?.clearSearch()
    if let tv = target, let win = tv.window, win === window {
      win.makeFirstResponder(tv)
    }
  }

  /// Step to the next match. Opens the bar first when it's closed.
  func findNext() {
    if !isOpen {
      show()
      guard isOpen else { return }
    }
    step(forward: true)
  }

  /// Step to the previous match. Opens the bar first when it's closed.
  func findPrevious() {
    if !isOpen {
      show()
      guard isOpen else { return }
    }
    step(forward: false)
  }

  /// Replace the search term programmatically and run the incremental
  /// search, exactly as if it had been typed. Used by QABridge.
  func setTerm(_ term: String) {
    field.stringValue = term
    searchTermChanged()
  }

  private func focusField() {
    // selectText(_:) makes the field first responder and selects its text.
    field.selectText(nil)
  }

  private var term: String { field.stringValue }

  private func step(forward: Bool) {
    guard !term.isEmpty, let tv = target else {
      setStatus(nil)
      return
    }
    let found = forward ? tv.findNext(term) : tv.findPrevious(term)
    lastFound = found
    setStatus(found ? nil : "No matches")
  }

  /// Incremental search: SwiftTerm restarts from the start of the current
  /// match when the term changes, so extending "err" to "error" stays put
  /// while that match still fits, and jumps forward only once it doesn't.
  private func searchTermChanged() {
    lastFound = nil
    if term.isEmpty {
      target?.clearSearch()
      setStatus(nil)
      return
    }
    step(forward: true)
  }

  private func retargeted(from old: ClaudeTerminalView?) {
    guard isOpen else { return }
    old?.clearSearch()
    if target == nil {
      hide()
      return
    }
    // The owner may be mid-rebuild (swapping terminal views in the window);
    // let the current turn finish so the match scrolls in the settled view.
    DispatchQueue.main.async { [weak self] in
      self?.searchTermChanged()
    }
  }

  private func setStatus(_ text: String?) {
    statusLabel.stringValue = text ?? ""
  }

  @objc private func findNextClicked() { findNext() }
  @objc private func findPreviousClicked() { findPrevious() }
  @objc private func closeClicked() { hide() }

  // MARK: - NSTextFieldDelegate

  func controlTextDidChange(_ obj: Notification) {
    searchTermChanged()
  }

  func control(
    _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
  ) -> Bool {
    switch commandSelector {
    case #selector(NSResponder.insertNewline(_:)),
      #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
      #selector(NSResponder.insertLineBreak(_:)):
      let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
      step(forward: !shift)
      return true
    case #selector(NSResponder.cancelOperation(_:)):
      hide()
      return true
    default:
      return false
    }
  }
}
