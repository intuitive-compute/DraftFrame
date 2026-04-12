import AppKit

/// Dashboard overlay showing all sessions as a grid of cards.
/// Toggled with Cmd+D.
final class DFDashboard: NSView {

  private let scrollView = NSScrollView()
  private let gridContainer = NSView()
  private var cardViews: [DashboardCard] = []

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = Theme.bg.withAlphaComponent(0.95).cgColor
    isHidden = true
    setupUI()

    NotificationCenter.default.addObserver(
      self, selector: #selector(sessionsChanged),
      name: .sessionsDidChange, object: nil
    )
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  func toggle() {
    isHidden = !isHidden
    if !isHidden {
      refresh()
    }
  }

  @objc private func sessionsChanged() {
    if !isHidden { refresh() }
  }

  private func setupUI() {
    // Title
    let title = NSTextField(labelWithString: "DASHBOARD")
    title.font = Theme.mono(14, weight: .bold)
    title.textColor = Theme.text1
    title.translatesAutoresizingMaskIntoConstraints = false
    addSubview(title)

    let subtitle = NSTextField(labelWithString: "All sessions at a glance. Press Cmd+D to close.")
    subtitle.font = Theme.mono(11)
    subtitle.textColor = Theme.text3
    subtitle.translatesAutoresizingMaskIntoConstraints = false
    addSubview(subtitle)

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    addSubview(scrollView)

    gridContainer.translatesAutoresizingMaskIntoConstraints = false
    scrollView.documentView = gridContainer

    NSLayoutConstraint.activate([
      title.topAnchor.constraint(equalTo: topAnchor, constant: 40),
      title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),

      subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
      subtitle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),

      scrollView.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 20),
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -30),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -30),
    ])
  }

  private func refresh() {
    // Remove old cards
    for card in cardViews { card.removeFromSuperview() }
    cardViews.removeAll()

    let sessions = SessionManager.shared.sessions
    if sessions.isEmpty {
      let empty = NSTextField(labelWithString: "No active sessions. Press Cmd+T to create one.")
      empty.font = Theme.mono(12)
      empty.textColor = Theme.text3
      empty.translatesAutoresizingMaskIntoConstraints = false
      gridContainer.addSubview(empty)
      NSLayoutConstraint.activate([
        empty.centerXAnchor.constraint(equalTo: gridContainer.centerXAnchor),
        empty.topAnchor.constraint(equalTo: gridContainer.topAnchor, constant: 40),
      ])
      return
    }

    let cardWidth: CGFloat = 300
    let cardHeight: CGFloat = 160
    let spacing: CGFloat = 16
    let containerWidth = scrollView.contentSize.width
    let cols = max(1, Int((containerWidth + spacing) / (cardWidth + spacing)))

    for (i, session) in sessions.enumerated() {
      let card = DashboardCard(session: session)
      card.translatesAutoresizingMaskIntoConstraints = false
      gridContainer.addSubview(card)
      cardViews.append(card)

      let row = i / cols
      let col = i % cols

      NSLayoutConstraint.activate([
        card.widthAnchor.constraint(equalToConstant: cardWidth),
        card.heightAnchor.constraint(equalToConstant: cardHeight),
        card.leadingAnchor.constraint(
          equalTo: gridContainer.leadingAnchor,
          constant: CGFloat(col) * (cardWidth + spacing) + 10),
        card.topAnchor.constraint(
          equalTo: gridContainer.topAnchor,
          constant: CGFloat(row) * (cardHeight + spacing) + 10),
      ])
    }

    // Set grid container size
    let rows = (sessions.count + cols - 1) / cols
    let totalHeight = CGFloat(rows) * (cardHeight + spacing) + 20
    gridContainer.frame = NSRect(
      x: 0, y: 0,
      width: scrollView.contentSize.width,
      height: max(totalHeight, scrollView.contentSize.height))
  }

  override func layout() {
    super.layout()
    if !isHidden { refresh() }
  }
}

// MARK: - Dashboard Card

final class DashboardCard: NSView {
  private let session: Session

  init(session: Session) {
    self.session = session
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = Theme.surface2.cgColor
    layer?.cornerRadius = 10
    layer?.borderColor = Theme.surface3.cgColor
    layer?.borderWidth = 1
    buildUI()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  private func buildUI() {
    // Avatar
    let avatar = PixelAvatar(seed: session.name)
    avatar.translatesAutoresizingMaskIntoConstraints = false
    addSubview(avatar)

    // Name
    let nameLabel = NSTextField(labelWithString: session.name)
    nameLabel.font = Theme.mono(14, weight: .bold)
    nameLabel.textColor = Theme.text1
    nameLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(nameLabel)

    // Status
    let dot = NSView()
    dot.wantsLayer = true
    dot.layer?.backgroundColor = session.state.color.cgColor
    dot.layer?.cornerRadius = 4
    dot.translatesAutoresizingMaskIntoConstraints = false
    addSubview(dot)

    let statusLabel = NSTextField(labelWithString: session.state.label)
    statusLabel.font = Theme.mono(11, weight: .medium)
    statusLabel.textColor = session.state.color
    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(statusLabel)

    // Branch
    let branchLabel = NSTextField(labelWithString: session.worktreePath ?? "main")
    branchLabel.font = Theme.mono(10)
    branchLabel.textColor = Theme.text3
    branchLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(branchLabel)

    // Model
    let modelLabel = NSTextField(labelWithString: "Model: \(session.model)")
    modelLabel.font = Theme.mono(10)
    modelLabel.textColor = Theme.text3
    modelLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(modelLabel)

    // Cost & Tokens
    let costLabel = NSTextField(labelWithString: String(format: "Cost: $%.2f", session.cost))
    costLabel.font = Theme.mono(11)
    costLabel.textColor = Theme.text2
    costLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(costLabel)

    let tokenStr = formatTokens(session.tokensIn)
    let tokensLabel = NSTextField(labelWithString: "Tokens: \(tokenStr)")
    tokensLabel.font = Theme.mono(10)
    tokensLabel.textColor = Theme.text3
    tokensLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(tokensLabel)

    // Action buttons
    let terminateBtn = makeButton(title: "Terminate", color: Theme.red)
    terminateBtn.target = self
    terminateBtn.action = #selector(terminateSession(_:))
    addSubview(terminateBtn)

    let restartBtn = makeButton(title: "Restart", color: Theme.accent)
    restartBtn.target = self
    restartBtn.action = #selector(restartSession(_:))
    addSubview(restartBtn)

    NSLayoutConstraint.activate([
      avatar.topAnchor.constraint(equalTo: topAnchor, constant: 14),
      avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      avatar.widthAnchor.constraint(equalToConstant: 36),
      avatar.heightAnchor.constraint(equalToConstant: 36),

      nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
      nameLabel.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 10),

      dot.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 5),
      dot.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 10),
      dot.widthAnchor.constraint(equalToConstant: 8),
      dot.heightAnchor.constraint(equalToConstant: 8),

      statusLabel.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
      statusLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5),

      branchLabel.topAnchor.constraint(equalTo: avatar.bottomAnchor, constant: 10),
      branchLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),

      modelLabel.topAnchor.constraint(equalTo: branchLabel.bottomAnchor, constant: 3),
      modelLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),

      costLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
      costLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

      tokensLabel.topAnchor.constraint(equalTo: costLabel.bottomAnchor, constant: 3),
      tokensLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

      terminateBtn.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
      terminateBtn.trailingAnchor.constraint(equalTo: restartBtn.leadingAnchor, constant: -8),
      terminateBtn.heightAnchor.constraint(equalToConstant: 24),
      terminateBtn.widthAnchor.constraint(equalToConstant: 80),

      restartBtn.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
      restartBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
      restartBtn.heightAnchor.constraint(equalToConstant: 24),
      restartBtn.widthAnchor.constraint(equalToConstant: 70),
    ])
  }

  private func makeButton(title: String, color: NSColor) -> NSButton {
    let btn = NSButton(title: title, target: nil, action: nil)
    btn.translatesAutoresizingMaskIntoConstraints = false
    btn.isBordered = false
    btn.wantsLayer = true
    btn.layer?.backgroundColor = color.withAlphaComponent(0.15).cgColor
    btn.layer?.cornerRadius = 4
    btn.font = Theme.mono(10, weight: .medium)
    btn.contentTintColor = color
    return btn
  }

  @objc private func terminateSession(_ sender: NSButton) {
    flashButton(sender, color: Theme.red)
    // Slight delay so the user sees the flash before the card disappears
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
      SessionManager.shared.closeSession(id: self.session.id)
    }
  }

  @objc private func restartSession(_ sender: NSButton) {
    flashButton(sender, color: Theme.accent)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
      SessionManager.shared.restartSession(id: self.session.id)
    }
  }

  private func flashButton(_ button: NSButton, color: NSColor) {
    let original = button.layer?.backgroundColor
    button.layer?.backgroundColor = color.withAlphaComponent(0.5).cgColor
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
      button.layer?.backgroundColor = original
    }
  }

  private func formatTokens(_ count: Int) -> String {
    if count >= 1000 {
      return String(format: "%.1fK", Double(count) / 1000.0)
    }
    return "\(count)"
  }
}
