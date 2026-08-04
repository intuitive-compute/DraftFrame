import AppKit

/// The shared "create a worktree" sheet used by the sidebar buttons, worktree
/// context menus, and the New Session with Worktree shortcut. Two modes,
/// switchable via a segmented control:
///
/// - New Branch: branch-name field plus an optional ticket link. Pasting a
///   recognizable ticket URL auto-fills the name with a git-safe slug (until
///   the user edits the name themselves), and the ticket becomes the new
///   session's kickoff prompt.
/// - Existing Branch: a single field naming a branch to check out into a
///   worktree. Opens a session in it with no kickoff prompt.
enum NewWorktreeDialog {
  enum Mode {
    case newBranch
    case existingBranch
  }

  enum Result {
    /// Create a fresh branch + worktree (and the caller opens a session).
    case newBranch(name: String, ticket: String?)
    /// Check out an already-existing branch into a worktree (and the caller
    /// opens a session with no kickoff prompt).
    case existingBranch(branch: String)
  }

  /// Presents the sheet on `window` and calls `completion` only when the
  /// user confirms with a non-empty name/branch.
  static func present(
    on window: NSWindow, title: String, message: String,
    initialMode: Mode = .newBranch,
    completion: @escaping (Result) -> Void
  ) {
    Sheet(title: title, message: message, initialMode: initialMode, completion: completion)
      .present(on: window)
  }

  /// Runs a `WorktreeManager` create and wraps failures in the standard
  /// "Worktree Error" alert; returns the worktree path on success.
  static func createWorktreeReportingErrors(
    repoRoot: String?, name: String, baseBranch: String? = nil
  ) -> String? {
    do {
      if let root = repoRoot {
        return try WorktreeManager.shared.createWorktree(
          repoRoot: root, name: name, baseBranch: baseBranch)
      }
      return try WorktreeManager.shared.createWorktree(name: name, baseBranch: baseBranch)
    } catch {
      reportError(error)
      return nil
    }
  }

  /// Runs a `WorktreeManager` branch checkout and wraps failures in the
  /// standard "Worktree Error" alert; returns the worktree path on success.
  static func checkoutWorktreeReportingErrors(repoRoot: String?, branch: String) -> String? {
    do {
      guard let root = repoRoot ?? WorktreeManager.shared.repoRoot else {
        throw WorktreeManager.WorktreeError.creationFailed(
          "Not in a git repository. Open a terminal in a git repo first.")
      }
      return try WorktreeManager.shared.createWorktree(repoRoot: root, checkoutBranch: branch)
    } catch {
      reportError(error)
      return nil
    }
  }

  private static func reportError(_ error: Error) {
    let errAlert = NSAlert()
    errAlert.messageText = "Worktree Error"
    errAlert.informativeText = error.localizedDescription
    errAlert.runModal()
  }

  // MARK: - Sheet

  /// The themed sheet window plus its controls. Instances keep themselves
  /// alive in `active` while presented.
  private final class Sheet: NSObject, NSTextFieldDelegate {
    private static var active: [Sheet] = []

    private let sheet: NSWindow
    private weak var parent: NSWindow?
    private let completion: (Result) -> Void

    private let modeControl = NSSegmentedControl(
      labels: ["New Branch", "Existing Branch"], trackingMode: .selectOne,
      target: nil, action: nil)
    private let nameField = NSTextField()
    private let ticketField = NSTextField()
    private let branchField = NSTextField()
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private var nameRow: NSView!
    private var ticketRow: NSView!
    private var branchRow: NSView!
    /// Set once the user types in the name field directly; from then on the
    /// ticket field stops overwriting their choice.
    private var nameEditedByUser = false

    private var mode: Mode {
      modeControl.selectedSegment == 1 ? .existingBranch : .newBranch
    }

    init(
      title: String, message: String, initialMode: Mode,
      completion: @escaping (Result) -> Void
    ) {
      self.completion = completion
      sheet = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
        styleMask: [.titled, .fullSizeContentView],
        backing: .buffered, defer: false)
      super.init()

      sheet.titleVisibility = .hidden
      sheet.titlebarAppearsTransparent = true
      sheet.appearance = NSAppearance(named: .darkAqua)
      sheet.backgroundColor = Theme.surface1

      buildContent(title: title, message: message)
      modeControl.selectedSegment = initialMode == .existingBranch ? 1 : 0
      applyMode()
    }

    func present(on window: NSWindow) {
      Self.active.append(self)
      parent = window
      sheet.initialFirstResponder = mode == .newBranch ? nameField : branchField
      window.beginSheet(sheet)
    }

    // MARK: Layout

    private func buildContent(title: String, message: String) {
      guard let content = sheet.contentView else { return }

      let titleLabel = NSTextField(labelWithString: title)
      titleLabel.font = Theme.mono(14, weight: .semibold)
      titleLabel.textColor = Theme.text1

      let messageLabel = NSTextField(wrappingLabelWithString: message)
      messageLabel.font = Theme.mono(11)
      messageLabel.textColor = Theme.text2

      modeControl.target = self
      modeControl.action = #selector(modeChanged)
      modeControl.segmentDistribution = .fillEqually
      modeControl.font = Theme.mono(11)

      for field in [nameField, ticketField, branchField] {
        field.font = Theme.mono(12)
        field.delegate = self
      }
      nameField.placeholderString = "feature-name"
      ticketField.placeholderString = "Ticket link (optional)"
      branchField.placeholderString = "existing-branch-name"

      nameRow = fieldRow(label: "Name", field: nameField)
      ticketRow = fieldRow(label: "Ticket", field: ticketField)
      branchRow = fieldRow(label: "Branch", field: branchField)

      hintLabel.font = Theme.mono(10)
      hintLabel.textColor = Theme.text3

      // Fixed-height slot sized for the taller (two-row) mode so switching
      // modes never resizes the sheet.
      let fieldsSlot = NSView()
      for row in [nameRow!, ticketRow!, branchRow!] {
        row.translatesAutoresizingMaskIntoConstraints = false
        fieldsSlot.addSubview(row)
        NSLayoutConstraint.activate([
          row.leadingAnchor.constraint(equalTo: fieldsSlot.leadingAnchor),
          row.trailingAnchor.constraint(equalTo: fieldsSlot.trailingAnchor),
          row.topAnchor.constraint(equalTo: fieldsSlot.topAnchor, constant: row === ticketRow ? 32 : 0),
          row.heightAnchor.constraint(equalToConstant: 24),
        ])
      }
      fieldsSlot.heightAnchor.constraint(equalToConstant: 56).isActive = true

      let cancelButton = NSButton(
        title: "Cancel", target: self, action: #selector(cancelClicked))
      cancelButton.bezelStyle = .rounded
      cancelButton.keyEquivalent = "\u{1b}"

      let createButton = NSButton(
        title: "Create", target: self, action: #selector(createClicked))
      createButton.bezelStyle = .rounded
      createButton.keyEquivalent = "\r"
      createButton.bezelColor = Theme.accent

      let buttonRow = NSStackView(views: [NSView(), cancelButton, createButton])
      buttonRow.orientation = .horizontal
      buttonRow.spacing = 8

      let stack = NSStackView(views: [
        titleLabel, messageLabel, modeControl, fieldsSlot, hintLabel, buttonRow,
      ])
      stack.orientation = .vertical
      stack.alignment = .leading
      stack.spacing = 10
      stack.setCustomSpacing(6, after: titleLabel)
      stack.setCustomSpacing(14, after: messageLabel)
      stack.setCustomSpacing(14, after: fieldsSlot)
      stack.setCustomSpacing(16, after: hintLabel)
      stack.translatesAutoresizingMaskIntoConstraints = false
      content.addSubview(stack)

      NSLayoutConstraint.activate([
        stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
        stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
        stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        modeControl.widthAnchor.constraint(equalTo: stack.widthAnchor),
        fieldsSlot.widthAnchor.constraint(equalTo: stack.widthAnchor),
        hintLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        content.widthAnchor.constraint(equalToConstant: 400),
      ])
      sheet.setContentSize(content.fittingSize)
    }

    private func fieldRow(label: String, field: NSTextField) -> NSView {
      let row = NSView()
      let lbl = NSTextField(labelWithString: label)
      lbl.font = Theme.mono(11)
      lbl.textColor = Theme.text3
      lbl.alignment = .right
      for v in [lbl, field] {
        v.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(v)
      }
      NSLayoutConstraint.activate([
        lbl.leadingAnchor.constraint(equalTo: row.leadingAnchor),
        lbl.widthAnchor.constraint(equalToConstant: 48),
        lbl.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        field.leadingAnchor.constraint(equalTo: lbl.trailingAnchor, constant: 8),
        field.trailingAnchor.constraint(equalTo: row.trailingAnchor),
        field.centerYAnchor.constraint(equalTo: row.centerYAnchor),
      ])
      return row
    }

    // MARK: Behavior

    @objc private func modeChanged() {
      applyMode()
      sheet.makeFirstResponder(mode == .newBranch ? nameField : branchField)
    }

    private func applyMode() {
      let newBranch = mode == .newBranch
      nameRow.isHidden = !newBranch
      ticketRow.isHidden = !newBranch
      branchRow.isHidden = newBranch
      hintLabel.stringValue =
        newBranch
        ? "Creates a new branch and worktree, then opens a session in it."
        : "Checks out the existing branch (local or origin) into a worktree and opens an idle session in it."
    }

    func controlTextDidChange(_ obj: Notification) {
      guard let field = obj.object as? NSTextField else { return }
      if field === nameField {
        nameEditedByUser = !nameField.stringValue.isEmpty
      } else if field === ticketField, !nameEditedByUser {
        nameField.stringValue = TicketLink.suggestedName(from: ticketField.stringValue) ?? ""
      }
    }

    @objc private func createClicked() {
      switch mode {
      case .newBranch:
        let name = trimmed(nameField)
        guard !name.isEmpty else { return rejectEmpty(nameField) }
        let ticket = trimmed(ticketField)
        end(with: .newBranch(name: name, ticket: ticket.isEmpty ? nil : ticket))
      case .existingBranch:
        let branch = trimmed(branchField)
        guard !branch.isEmpty else { return rejectEmpty(branchField) }
        end(with: .existingBranch(branch: branch))
      }
    }

    @objc private func cancelClicked() {
      end(with: nil)
    }

    private func trimmed(_ field: NSTextField) -> String {
      field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func rejectEmpty(_ field: NSTextField) {
      NSSound.beep()
      sheet.makeFirstResponder(field)
    }

    private func end(with result: Result?) {
      parent?.endSheet(sheet)
      Self.active.removeAll { $0 === self }
      if let result = result { completion(result) }
    }
  }
}
