import AppKit

/// The shared "create a worktree" sheet used by the sidebar buttons and the
/// New Session with Worktree shortcut: a branch-name field plus an optional
/// ticket link. Pasting a recognizable ticket URL auto-fills the name with a
/// git-safe slug (until the user edits the name themselves), and the ticket
/// becomes the new session's kickoff prompt.
enum NewWorktreeDialog {
  struct Result {
    let name: String
    /// Trimmed ticket link, nil when the field was left empty.
    let ticket: String?
  }

  /// Presents the sheet on `window` and calls `completion` only when the
  /// user confirms with a non-empty name.
  static func present(
    on window: NSWindow, title: String, message: String,
    completion: @escaping (Result) -> Void
  ) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "Create")
    alert.addButton(withTitle: "Cancel")

    let accessory = AccessoryView()
    alert.accessoryView = accessory
    alert.window.initialFirstResponder = accessory.nameField

    alert.beginSheetModal(for: window) { response in
      guard response == .alertFirstButtonReturn else { return }
      let name = accessory.nameField.stringValue
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else { return }
      let ticket = accessory.ticketField.stringValue
        .trimmingCharacters(in: .whitespacesAndNewlines)
      completion(Result(name: name, ticket: ticket.isEmpty ? nil : ticket))
    }
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
      let errAlert = NSAlert()
      errAlert.messageText = "Worktree Error"
      errAlert.informativeText = error.localizedDescription
      errAlert.runModal()
      return nil
    }
  }

  /// Name + ticket fields with the paste-to-autofill behavior.
  private final class AccessoryView: NSView, NSTextFieldDelegate {
    let nameField = NSTextField()
    let ticketField = NSTextField()
    /// Set once the user types in the name field directly; from then on the
    /// ticket field stops overwriting their choice.
    private var nameEditedByUser = false

    init() {
      super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 76))

      nameField.placeholderString = "feature-name"
      ticketField.placeholderString = "Ticket link (optional)"
      nameField.delegate = self
      ticketField.delegate = self

      let ticketLabel = NSTextField(labelWithString: "Ticket:")
      let nameLabel = NSTextField(labelWithString: "Name:")
      for label in [ticketLabel, nameLabel] {
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
      }

      for v in [nameLabel, nameField, ticketLabel, ticketField] {
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
      }
      NSLayoutConstraint.activate([
        nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
        nameLabel.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
        ticketLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
        ticketLabel.centerYAnchor.constraint(equalTo: ticketField.centerYAnchor),
        nameLabel.widthAnchor.constraint(equalTo: ticketLabel.widthAnchor),

        nameField.topAnchor.constraint(equalTo: topAnchor, constant: 4),
        nameField.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 6),
        nameField.trailingAnchor.constraint(equalTo: trailingAnchor),

        ticketField.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 8),
        ticketField.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
        ticketField.trailingAnchor.constraint(equalTo: trailingAnchor),
        ticketField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
      ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been used") }

    func controlTextDidChange(_ obj: Notification) {
      guard let field = obj.object as? NSTextField else { return }
      if field === nameField {
        nameEditedByUser = !nameField.stringValue.isEmpty
      } else if field === ticketField, !nameEditedByUser {
        nameField.stringValue = TicketLink.suggestedName(from: ticketField.stringValue) ?? ""
      }
    }
  }
}
