import AppKit

/// Dashboard overlay showing all sessions as a grid of cards.
/// Toggled with Cmd+D.
final class DFDashboard: NSView {

  private let scrollView = NSScrollView()
  private let gridContainer = NSView()
  private var cardViews: [DashboardCard] = []
  private let modeSelector = NSSegmentedControl(
    labels: ["Grid", "Summary"], trackingMode: .selectOne, target: nil, action: nil)

  enum Mode: Int { case grid = 0, summary = 1 }
  private(set) var mode: Mode = .grid

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = Theme.bg.cgColor
    isHidden = true
    setupUI()

    NotificationCenter.default.addObserver(
      self, selector: #selector(sessionsChanged),
      name: .sessionsDidChange, object: nil
    )
    NotificationCenter.default.addObserver(
      self, selector: #selector(sessionsChanged),
      name: .prStatusDidChange, object: nil
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
      needsLayout = true
      layoutSubtreeIfNeeded()
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

    // Grid / Summary mode selector
    modeSelector.selectedSegment = 0
    modeSelector.target = self
    modeSelector.action = #selector(modeChanged)
    modeSelector.translatesAutoresizingMaskIntoConstraints = false
    addSubview(modeSelector)

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    addSubview(scrollView)

    scrollView.documentView = gridContainer

    NSLayoutConstraint.activate([
      title.topAnchor.constraint(equalTo: topAnchor, constant: 40),
      title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),

      subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
      subtitle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),

      modeSelector.centerYAnchor.constraint(equalTo: title.centerYAnchor),
      modeSelector.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),

      scrollView.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 20),
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -30),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -30),
    ])
  }

  @objc private func modeChanged(_ sender: NSSegmentedControl) {
    mode = Mode(rawValue: sender.selectedSegment) ?? .grid
    refresh()
  }

  private func refresh() {
    // Remove all subviews from grid (cards + any empty-state labels)
    for sub in gridContainer.subviews { sub.removeFromSuperview() }
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

    switch mode {
    case .grid: layoutGrid(sessions: sessions)
    case .summary: layoutSummary(sessions: sessions)
    }
  }

  private func layoutGrid(sessions: [Session]) {
    let cardWidth: CGFloat = 300
    let cardHeight: CGFloat = 210
    let spacing: CGFloat = 16
    // Use the scroll view's visible width; fall back to our own bounds minus padding.
    let containerWidth = max(scrollView.bounds.width, bounds.width - 60)
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

    // Set grid container size for scrolling
    let rows = (sessions.count + cols - 1) / cols
    let totalHeight = CGFloat(rows) * (cardHeight + spacing) + 20
    let visibleHeight = max(scrollView.bounds.height, bounds.height - 100)
    gridContainer.frame = NSRect(
      x: 0, y: 0,
      width: containerWidth,
      height: max(totalHeight, visibleHeight))
  }

  private func layoutSummary(sessions: [Session]) {
    let spacing: CGFloat = 12
    let cardHeight: CGFloat = 140
    let containerWidth = max(scrollView.bounds.width, bounds.width - 60)
    let cardWidth = containerWidth - 20

    for (i, session) in sessions.enumerated() {
      let card = SummaryCard(session: session)
      card.translatesAutoresizingMaskIntoConstraints = false
      gridContainer.addSubview(card)

      NSLayoutConstraint.activate([
        card.widthAnchor.constraint(equalToConstant: cardWidth),
        card.heightAnchor.constraint(equalToConstant: cardHeight),
        card.leadingAnchor.constraint(equalTo: gridContainer.leadingAnchor, constant: 10),
        card.topAnchor.constraint(
          equalTo: gridContainer.topAnchor,
          constant: CGFloat(i) * (cardHeight + spacing) + 10),
      ])
    }

    let totalHeight = CGFloat(sessions.count) * (cardHeight + spacing) + 20
    let visibleHeight = max(scrollView.bounds.height, bounds.height - 100)
    gridContainer.frame = NSRect(
      x: 0, y: 0,
      width: containerWidth,
      height: max(totalHeight, visibleHeight))
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

    // PR / CI section — only shown for sessions with a worktree.
    let prHeader = NSTextField(labelWithString: prSectionHeader())
    prHeader.font = Theme.mono(10, weight: .medium)
    prHeader.textColor = prHeaderColor()
    prHeader.translatesAutoresizingMaskIntoConstraints = false
    addSubview(prHeader)

    let autoFixBox = makeToggle(title: "Auto-fix", action: #selector(toggleAutoFix(_:)))
    let autoMergeBox = makeToggle(title: "Auto-merge", action: #selector(toggleAutoMerge(_:)))
    let autoArchiveBox = makeToggle(title: "Auto-archive", action: #selector(toggleAutoArchive(_:)))

    let effectivePath = sessionEffectivePath()
    let config = PRMonitor.shared.config(for: effectivePath)
    autoFixBox.state = config.autoFix ? .on : .off
    autoMergeBox.state = config.autoMerge ? .on : .off
    autoArchiveBox.state = config.autoArchive ? .on : .off

    // Only enable toggles when we have a directory to key config by.
    let canConfigure = effectivePath != nil
    autoFixBox.isEnabled = canConfigure
    autoMergeBox.isEnabled = canConfigure
    autoArchiveBox.isEnabled = canConfigure

    addSubview(autoFixBox)
    addSubview(autoMergeBox)
    addSubview(autoArchiveBox)

    NSLayoutConstraint.activate([
      // Avatar
      avatar.topAnchor.constraint(equalTo: topAnchor, constant: 24),
      avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      avatar.widthAnchor.constraint(equalToConstant: 36),
      avatar.heightAnchor.constraint(equalToConstant: 36),

      // Name + status centered vertically against avatar
      nameLabel.topAnchor.constraint(equalTo: avatar.topAnchor, constant: 2),
      nameLabel.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 10),

      dot.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
      dot.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 10),
      dot.widthAnchor.constraint(equalToConstant: 8),
      dot.heightAnchor.constraint(equalToConstant: 8),

      statusLabel.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
      statusLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5),

      // Cost + tokens aligned to top-right
      costLabel.topAnchor.constraint(equalTo: avatar.topAnchor, constant: 2),
      costLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

      tokensLabel.topAnchor.constraint(equalTo: costLabel.bottomAnchor, constant: 3),
      tokensLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

      // Branch + model in middle section
      branchLabel.topAnchor.constraint(equalTo: avatar.bottomAnchor, constant: 12),
      branchLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      branchLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

      modelLabel.topAnchor.constraint(equalTo: branchLabel.bottomAnchor, constant: 4),
      modelLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),

      // PR header + toggles between model row and action buttons
      prHeader.topAnchor.constraint(equalTo: modelLabel.bottomAnchor, constant: 12),
      prHeader.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      prHeader.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

      autoFixBox.topAnchor.constraint(equalTo: prHeader.bottomAnchor, constant: 4),
      autoFixBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),

      autoMergeBox.centerYAnchor.constraint(equalTo: autoFixBox.centerYAnchor),
      autoMergeBox.leadingAnchor.constraint(equalTo: autoFixBox.trailingAnchor, constant: 4),

      autoArchiveBox.centerYAnchor.constraint(equalTo: autoFixBox.centerYAnchor),
      autoArchiveBox.leadingAnchor.constraint(equalTo: autoMergeBox.trailingAnchor, constant: 4),

      // Action buttons pinned to bottom-right
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

  // MARK: - PR section helpers

  private func prSectionHeader() -> String {
    guard sessionEffectivePath() != nil else {
      return "No project dir — PR tracking unavailable"
    }
    guard let status = PRMonitor.shared.status(for: session.id) else {
      return "No PR for this branch · auto actions save to config"
    }
    switch status.state {
    case "MERGED": return "PR #\(status.number) merged"
    case "CLOSED": return "PR #\(status.number) closed"
    default:
      let total = status.checks.count
      if total == 0 {
        return "PR #\(status.number) · no checks"
      }
      return "PR #\(status.number) · \(status.passingCount)/\(total) \(status.rollup.label)"
    }
  }

  private func prHeaderColor() -> NSColor {
    guard sessionEffectivePath() != nil else { return Theme.text3 }
    guard let status = PRMonitor.shared.status(for: session.id) else { return Theme.text3 }
    switch status.state {
    case "MERGED": return Theme.accent
    case "CLOSED": return Theme.text3
    default: return status.rollup.color
    }
  }

  /// The directory PR monitoring should key on for this session: its
  /// explicit worktree or, failing that, the active project directory.
  private func sessionEffectivePath() -> String? {
    if let path = session.worktreePath { return path }
    return SessionManager.shared.projectDir
  }

  private func makeToggle(title: String, action: Selector) -> NSButton {
    let btn = NSButton(checkboxWithTitle: title, target: self, action: action)
    btn.translatesAutoresizingMaskIntoConstraints = false
    btn.font = Theme.mono(10)
    btn.contentTintColor = Theme.text2
    return btn
  }

  private func writeConfig(mutate: (inout PRMonitorConfig) -> Void) {
    guard let path = sessionEffectivePath() else { return }
    var config = PRMonitor.shared.config(for: path)
    mutate(&config)
    PRMonitor.shared.setConfig(config, for: path)
    PRMonitor.shared.refreshNow(sessionID: session.id)
  }

  @objc private func toggleAutoFix(_ sender: NSButton) {
    writeConfig { $0.autoFix = (sender.state == .on) }
  }

  @objc private func toggleAutoMerge(_ sender: NSButton) {
    writeConfig { $0.autoMerge = (sender.state == .on) }
  }

  @objc private func toggleAutoArchive(_ sender: NSButton) {
    writeConfig { $0.autoArchive = (sender.state == .on) }
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

// MARK: - Summary Card

/// Row in the dashboard's Summary view: session header + preview of
/// Claude's most recent assistant response, sourced from the JSONL stream.
final class SummaryCard: NSView {
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

    // Click the card to switch to that session in the terminal pane.
    let click = NSClickGestureRecognizer(target: self, action: #selector(cardClicked))
    addGestureRecognizer(click)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  @objc private func cardClicked() {
    if let idx = SessionManager.shared.sessions.firstIndex(where: { $0.id == session.id }) {
      SessionManager.shared.switchTo(index: idx)
    }
  }

  private func buildUI() {
    let avatar = PixelAvatar(seed: session.name)
    avatar.translatesAutoresizingMaskIntoConstraints = false
    addSubview(avatar)

    let nameLabel = NSTextField(labelWithString: session.name)
    nameLabel.font = Theme.mono(13, weight: .bold)
    nameLabel.textColor = Theme.text1
    nameLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(nameLabel)

    let dot = NSView()
    dot.wantsLayer = true
    dot.layer?.backgroundColor = session.state.color.cgColor
    dot.layer?.cornerRadius = 3.5
    dot.translatesAutoresizingMaskIntoConstraints = false
    addSubview(dot)

    let statusLabel = NSTextField(labelWithString: session.state.label)
    statusLabel.font = Theme.mono(10, weight: .medium)
    statusLabel.textColor = session.state.color
    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(statusLabel)

    let timestamp = NSTextField(labelWithString: formatTimestamp())
    timestamp.font = Theme.mono(10)
    timestamp.textColor = Theme.text3
    timestamp.translatesAutoresizingMaskIntoConstraints = false
    addSubview(timestamp)

    // Message preview — wraps on words, caps at 4 lines. We leave
    // lineBreakMode at the default .byWordWrapping; setting it to a
    // truncating mode here would collapse the whole label to one line.
    let messageField = NSTextField(wrappingLabelWithString: previewText())
    messageField.font = Theme.mono(11)
    messageField.textColor = Theme.text2
    messageField.maximumNumberOfLines = 4
    messageField.translatesAutoresizingMaskIntoConstraints = false
    addSubview(messageField)

    NSLayoutConstraint.activate([
      avatar.topAnchor.constraint(equalTo: topAnchor, constant: 12),
      avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      avatar.widthAnchor.constraint(equalToConstant: 28),
      avatar.heightAnchor.constraint(equalToConstant: 28),

      nameLabel.topAnchor.constraint(equalTo: avatar.topAnchor),
      nameLabel.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 10),

      dot.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 5),
      dot.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 10),
      dot.widthAnchor.constraint(equalToConstant: 7),
      dot.heightAnchor.constraint(equalToConstant: 7),

      statusLabel.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
      statusLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5),

      timestamp.topAnchor.constraint(equalTo: avatar.topAnchor),
      timestamp.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

      messageField.topAnchor.constraint(equalTo: avatar.bottomAnchor, constant: 14),
      messageField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      messageField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
      messageField.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
    ])
  }

  private func previewText() -> String {
    if let text = session.jsonlWatcher?.latestAssistantText, !text.isEmpty {
      return text
    }
    return "No assistant response yet for this session."
  }

  private func formatTimestamp() -> String {
    guard let date = session.jsonlWatcher?.latestAssistantAt else { return "" }
    let interval = Date().timeIntervalSince(date)
    if interval < 60 { return "just now" }
    if interval < 3600 { return "\(Int(interval / 60))m ago" }
    if interval < 86400 { return "\(Int(interval / 3600))h ago" }
    return "\(Int(interval / 86400))d ago"
  }
}
