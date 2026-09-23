import AppKit

extension NSPasteboard.PasteboardType {
  fileprivate static let dfSessionDrag = NSPasteboard.PasteboardType("com.draftframe.sessiondrag")
  /// A whole group (header plus members) being reordered; payload is the group ID.
  fileprivate static let dfGroupDrag = NSPasteboard.PasteboardType("com.draftframe.groupdrag")
}

/// Right sidebar: session cards with live status, driven by SessionManager.
/// Cards are laid out under collapsible group headers (see `SessionGroup`),
/// with ungrouped sessions last.
final class DFSessionBar: NSView {

  private let cardStack = NSStackView()
  private let dropIndicator = NSView()
  private var lastDropIndex: Int?
  private weak var highlightedHeader: SessionGroupHeader?

  /// What `cardStack` currently holds, top to bottom. Drag and drop maps a
  /// pointer location onto this list to decide which group and index a
  /// dropped card lands at.
  private enum Entry {
    case header(SessionGroup, SessionGroupHeader)
    /// The "Ungrouped" label that opens the ungrouped block once any group
    /// exists, so cards can be dragged back out of groups.
    case ungroupedDivider(NSView)
    /// `container` is the arranged view (the card itself, or the indented
    /// row wrapping it inside a group); `index` is the session's index in
    /// `SessionManager.sessions`.
    case card(SessionCard, container: NSView, index: Int, groupID: UUID?)

    var view: NSView {
      switch self {
      case .header(_, let v): return v
      case .ungroupedDivider(let v): return v
      case .card(_, let c, _, _): return c
      }
    }
  }
  private var entries: [Entry] = []

  /// Where a drag would land: the group (nil = ungrouped), the global
  /// insertion index, and how to draw it.
  private struct DropTarget {
    let groupID: UUID?
    let index: Int
    /// Entry position to draw the line before; `entries.count` = below all.
    let lineBefore: Int
    /// Header to highlight instead of a line (dropping onto a collapsed group).
    let header: SessionGroupHeader?
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = Theme.surface1.cgColor
    buildUI()
    registerForDraggedTypes([.dfSessionDrag, .dfGroupDrag])

    // Structural changes (membership, order, active card, PR pills) rebuild
    // the cards; state and usage ticks update the existing cards in place so
    // a working agent doesn't tear the bar down once a second.
    NotificationCenter.default.addObserver(
      self, selector: #selector(sessionsChanged),
      name: .sessionListDidChange, object: nil
    )
    NotificationCenter.default.addObserver(
      self, selector: #selector(sessionsChanged),
      name: .activeSessionDidChange, object: nil
    )
    NotificationCenter.default.addObserver(
      self, selector: #selector(sessionsChanged),
      name: .prStatusDidChange, object: nil
    )
    NotificationCenter.default.addObserver(
      self, selector: #selector(sessionDynamicsChanged),
      name: .sessionStateDidChange, object: nil
    )
    NotificationCenter.default.addObserver(
      self, selector: #selector(sessionDynamicsChanged),
      name: .sessionUsageDidChange, object: nil
    )
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  @objc private func sessionsChanged() {
    refreshCards()
  }

  private var allCards: [SessionCard] {
    entries.compactMap { entry in
      if case .card(let card, _, _, _) = entry { return card }
      return nil
    }
  }

  private var allHeaders: [SessionGroupHeader] {
    entries.compactMap { entry in
      if case .header(_, let header) = entry { return header }
      return nil
    }
  }

  /// State/usage tick: refresh every card in place. Falls back to a full
  /// rebuild when a card reports a structural change (its context row
  /// appearing for the first time). Collapsed headers re-read their
  /// members' states for the status dots.
  @objc private func sessionDynamicsChanged() {
    var needsRebuild = false
    for card in allCards {
      if !card.refreshDynamic() { needsRebuild = true }
    }
    for header in allHeaders { header.refreshDynamic() }
    if needsRebuild { refreshCards() }
  }

  private func buildUI() {
    let title = NSTextField(labelWithString: "SESSIONS")
    title.font = Theme.mono(10, weight: .medium)
    title.textColor = Theme.text3
    title.translatesAutoresizingMaskIntoConstraints = false
    addSubview(title)

    // "+" opens the new-group sheet.
    let addButton = NSButton(
      image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New Group") ?? NSImage(),
      target: self, action: #selector(addGroupClicked))
    addButton.isBordered = false
    addButton.bezelStyle = .inline
    addButton.contentTintColor = Theme.text3
    addButton.toolTip = "New Session Group"
    addButton.setAccessibilityLabel("New Session Group")
    addButton.translatesAutoresizingMaskIntoConstraints = false
    addSubview(addButton)

    let sep = NSView()
    sep.wantsLayer = true
    sep.layer?.backgroundColor = Theme.surface3.cgColor
    sep.translatesAutoresizingMaskIntoConstraints = false
    addSubview(sep)

    cardStack.orientation = .vertical
    cardStack.spacing = 6
    cardStack.alignment = .leading
    cardStack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(cardStack)

    dropIndicator.wantsLayer = true
    dropIndicator.layer?.backgroundColor = Theme.accent.cgColor
    dropIndicator.layer?.cornerRadius = 1
    dropIndicator.isHidden = true
    addSubview(dropIndicator)

    NSLayoutConstraint.activate([
      title.topAnchor.constraint(equalTo: topAnchor, constant: 38),
      title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      addButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
      addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      addButton.widthAnchor.constraint(equalToConstant: 18),
      addButton.heightAnchor.constraint(equalToConstant: 18),
      sep.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
      sep.leadingAnchor.constraint(equalTo: leadingAnchor),
      sep.trailingAnchor.constraint(equalTo: trailingAnchor),
      sep.heightAnchor.constraint(equalToConstant: 1),
      cardStack.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 8),
      cardStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      cardStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
    ])
  }

  private static let rowWidth: CGFloat = 284

  private func refreshCards() {
    // Remove existing cards
    for view in cardStack.arrangedSubviews {
      cardStack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    entries = []
    highlightedHeader = nil

    let manager = SessionManager.shared
    let sessions = manager.sessions
    let activeIdx = manager.activeSessionIndex
    let groups = manager.groups

    if sessions.isEmpty && groups.isEmpty {
      let empty = NSTextField(labelWithString: "No sessions.\nCmd+T to create one.")
      empty.font = Theme.mono(10)
      empty.textColor = Theme.text3
      empty.maximumNumberOfLines = 2
      empty.translatesAutoresizingMaskIntoConstraints = false
      cardStack.addArrangedSubview(empty)
      return
    }

    func indexOf(_ session: Session) -> Int {
      sessions.firstIndex { $0 === session } ?? 0
    }

    func addCard(_ session: Session, in group: SessionGroup?) {
      let i = indexOf(session)
      let card = SessionCard(session: session, isActive: i == activeIdx, index: i, bar: self)
      card.translatesAutoresizingMaskIntoConstraints = false
      let container: NSView
      if let group = group {
        let row = GroupedCardRow(card: card, group: group)
        row.widthAnchor.constraint(equalToConstant: Self.rowWidth).isActive = true
        container = row
      } else {
        card.widthAnchor.constraint(equalToConstant: Self.rowWidth).isActive = true
        container = card
      }
      cardStack.addArrangedSubview(container)
      entries.append(.card(card, container: container, index: i, groupID: group?.id))
    }

    for group in groups {
      let members = manager.sessions(in: group)
      let containsActive = members.contains { indexOf($0) == activeIdx }
      let header = SessionGroupHeader(
        group: group, members: members, containsActive: containsActive, bar: self)
      header.widthAnchor.constraint(equalToConstant: Self.rowWidth).isActive = true
      cardStack.addArrangedSubview(header)
      // Breathing room above every group but the first.
      if let previous = entries.last?.view { cardStack.setCustomSpacing(12, after: previous) }
      entries.append(.header(group, header))
      cardStack.setCustomSpacing(4, after: header)
      if group.isCollapsed { continue }
      for session in members { addCard(session, in: group) }
    }

    let ungrouped = manager.ungroupedSessions
    if !groups.isEmpty {
      let divider = NSTextField(labelWithString: "UNGROUPED")
      divider.font = Theme.mono(9, weight: .medium)
      divider.textColor = Theme.text3
      divider.translatesAutoresizingMaskIntoConstraints = false
      let wrap = NSView()
      wrap.translatesAutoresizingMaskIntoConstraints = false
      wrap.addSubview(divider)
      NSLayoutConstraint.activate([
        wrap.widthAnchor.constraint(equalToConstant: Self.rowWidth),
        wrap.heightAnchor.constraint(equalToConstant: 16),
        divider.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 6),
        divider.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
      ])
      if let previous = entries.last?.view { cardStack.setCustomSpacing(12, after: previous) }
      cardStack.addArrangedSubview(wrap)
      entries.append(.ungroupedDivider(wrap))
      cardStack.setCustomSpacing(4, after: wrap)
    }
    for session in ungrouped { addCard(session, in: nil) }
  }

  // MARK: - Group actions

  @objc private func addGroupClicked() {
    presentNewGroupDialog()
  }

  /// Open the new-group sheet (the "+" button; also reachable from the QA
  /// bridge).
  func presentNewGroupDialog() {
    guard let win = window else { return }
    SessionGroupDialog.presentCreate(on: win) { result in
      Self.apply(result, editing: nil)
    }
  }

  private static func apply(_ result: SessionGroupDialog.Result, editing group: SessionGroup?) {
    let manager = SessionManager.shared
    switch result {
    case .group(let name, let color):
      if let group = group {
        manager.updateGroup(id: group.id, name: name, color: color)
      } else {
        manager.createGroup(name: name, color: color)
      }
    case .statusPreset:
      manager.applyStatusPreset()
    case .projectPreset:
      manager.applyProjectPreset()
    }
  }

  /// Toggle a group's collapsed state (header click).
  fileprivate func toggleCollapse(_ group: SessionGroup) {
    SessionManager.shared.setGroup(id: group.id, collapsed: !group.isCollapsed)
  }

  fileprivate func runEditDialog(for group: SessionGroup) {
    guard let win = window else { return }
    SessionGroupDialog.presentEdit(on: win, group: group) { result in
      Self.apply(result, editing: group)
    }
  }

  private func groupPayload(from sender: NSMenuItem) -> SessionGroup? {
    (sender.representedObject as? SessionGroupMenuPayload)?.group
  }

  @objc fileprivate func editGroupFromMenu(_ sender: NSMenuItem) {
    guard let group = groupPayload(from: sender) else { return }
    runEditDialog(for: group)
  }

  @objc fileprivate func toggleCollapseFromMenu(_ sender: NSMenuItem) {
    guard let group = groupPayload(from: sender) else { return }
    toggleCollapse(group)
  }

  @objc fileprivate func deleteGroupFromMenu(_ sender: NSMenuItem) {
    guard let group = groupPayload(from: sender) else { return }
    SessionManager.shared.deleteGroup(id: group.id)
  }

  /// "Move to Group" submenu item on a card: `representedObject` carries the
  /// session and the destination group (nil = ungrouped).
  @objc fileprivate func moveToGroupFromMenu(_ sender: NSMenuItem) {
    guard let payload = payload(from: sender) else { return }
    SessionManager.shared.move(sessionID: payload.session.id, toGroup: payload.targetGroupID)
  }

  // MARK: - Drag & Drop (reorder and regroup)

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    (sourceIndex(from: sender) == nil && sourceGroupID(from: sender) == nil) ? [] : .move
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    if let groupID = sourceGroupID(from: sender) {
      if let target = groupDropTarget(for: sender, dragging: groupID) {
        showDropLine(before: target.lineBefore)
      } else {
        hideDropIndicator()
      }
      return .move
    }
    guard sourceIndex(from: sender) != nil else { return [] }
    showDropIndicator(for: dropTarget(for: sender))
    return .move
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    hideDropIndicator()
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    if let groupID = sourceGroupID(from: sender) {
      let target = groupDropTarget(for: sender, dragging: groupID)
      hideDropIndicator()
      guard let target = target else { return false }
      SessionManager.shared.moveGroup(id: groupID, to: target.toIndex)
      return true
    }
    guard let from = sourceIndex(from: sender) else { return false }
    let sessions = SessionManager.shared.sessions
    guard from >= 0, from < sessions.count else { return false }
    let target = dropTarget(for: sender)
    hideDropIndicator()
    SessionManager.shared.move(
      sessionID: sessions[from].id, toGroup: target.groupID, at: target.index)
    return true
  }

  override func concludeDragOperation(_ sender: NSDraggingInfo?) {
    hideDropIndicator()
  }

  private func sourceIndex(from info: NSDraggingInfo) -> Int? {
    guard
      let items = info.draggingPasteboard.pasteboardItems,
      let str = items.first?.string(forType: .dfSessionDrag),
      let idx = Int(str)
    else { return nil }
    return idx
  }

  private func sourceGroupID(from info: NSDraggingInfo) -> UUID? {
    guard
      let items = info.draggingPasteboard.pasteboardItems,
      let str = items.first?.string(forType: .dfGroupDrag)
    else { return nil }
    return UUID(uuidString: str)
  }

  // MARK: Group drags

  /// Where a dragged group would land: the insertion index in
  /// `SessionManager.groups` and the entry to draw the line before.
  private struct GroupDropTarget {
    let toIndex: Int
    let lineBefore: Int
  }

  /// Entry ranges of each block in `entries`: one per group (header plus
  /// its visible cards) followed, when groups exist, by the ungrouped block
  /// (divider plus ungrouped cards). Group blocks are in `groups` order.
  private func blockRanges() -> (groups: [Range<Int>], ungrouped: Range<Int>?) {
    var starts: [Int] = []
    var ungroupedStart: Int?
    for (i, entry) in entries.enumerated() {
      switch entry {
      case .header: starts.append(i)
      case .ungroupedDivider: ungroupedStart = i
      case .card: break
      }
    }
    var groups: [Range<Int>] = []
    for (k, start) in starts.enumerated() {
      let end = k + 1 < starts.count ? starts[k + 1] : (ungroupedStart ?? entries.count)
      groups.append(start..<end)
    }
    return (groups, ungroupedStart.map { $0..<entries.count })
  }

  /// Map the pointer to a group insertion point. Groups never nest and
  /// ungrouped sessions always come last, so the pointer snaps to the
  /// nearest block boundary: above or below whichever group block it is
  /// over, or above the ungrouped block. Returns nil when the drag can't
  /// land anywhere (no group blocks laid out).
  private func groupDropTarget(for info: NSDraggingInfo, dragging groupID: UUID)
    -> GroupDropTarget?
  {
    let point = cardStack.convert(info.draggingLocation, from: nil)
    let (groupBlocks, ungroupedBlock) = blockRanges()
    guard !groupBlocks.isEmpty else { return nil }

    func frame(of block: Range<Int>) -> NSRect {
      block.map { entries[$0].view.frame }.reduce(NSRect.null) { $0.union($1) }
    }

    // Above every block: first position.
    if point.y >= frame(of: groupBlocks[0]).maxY {
      return GroupDropTarget(toIndex: 0, lineBefore: groupBlocks[0].lowerBound)
    }
    for (k, block) in groupBlocks.enumerated() {
      let f = frame(of: block)
      // Inside this block, or in the gap just below it (before the next
      // block starts): the block's midline decides above vs. below.
      let nextTop =
        k + 1 < groupBlocks.count
        ? frame(of: groupBlocks[k + 1]).maxY
        : (ungroupedBlock.map { frame(of: $0).maxY } ?? -.greatestFiniteMagnitude)
      guard point.y >= nextTop else { continue }
      if point.y > f.midY {
        return GroupDropTarget(toIndex: k, lineBefore: block.lowerBound)
      }
      return GroupDropTarget(toIndex: k + 1, lineBefore: block.upperBound)
    }
    // Over (or below) the ungrouped block: just above it.
    return GroupDropTarget(
      toIndex: groupBlocks.count, lineBefore: groupBlocks[groupBlocks.count - 1].upperBound)
  }

  /// Dim or restore every view that belongs to `groupID` (header and rows)
  /// while the group is being dragged.
  fileprivate func setGroupDimmed(_ groupID: UUID, _ dimmed: Bool) {
    for entry in entries {
      switch entry {
      case .header(let group, let header) where group.id == groupID:
        header.alphaValue = dimmed ? 0.3 : 1.0
      case .card(_, let container, _, let gid) where gid == groupID:
        container.alphaValue = dimmed ? 0.3 : 1.0
      default: break
      }
    }
  }

  /// First session index of `group`'s block in the display order, and the
  /// index just past it.
  private func block(of group: SessionGroup) -> (start: Int, end: Int) {
    let manager = SessionManager.shared
    var start = 0
    for g in manager.groups {
      let count = manager.sessions(in: g).count
      if g.id == group.id { return (start, start + count) }
      start += count
    }
    return (start, start)
  }

  /// Map the pointer to a drop target. Pointer over a collapsed group's
  /// header drops into that group; otherwise the entry just above the
  /// insertion gap decides the group, and the gap decides the index.
  private func dropTarget(for info: NSDraggingInfo) -> DropTarget {
    let manager = SessionManager.shared
    let point = cardStack.convert(info.draggingLocation, from: nil)
    let groupedCount = manager.groups.reduce(0) { $0 + manager.sessions(in: $1).count }

    guard !entries.isEmpty else {
      return DropTarget(groupID: nil, index: 0, lineBefore: 0, header: nil)
    }

    // Hovering a collapsed header: drop into that group.
    for (i, entry) in entries.enumerated() {
      if case .header(let group, let header) = entry, group.isCollapsed,
        header.frame.contains(point)
      {
        return DropTarget(
          groupID: group.id, index: block(of: group).end, lineBefore: i, header: header)
      }
    }

    // The insertion gap: before the first entry whose midline the pointer
    // is above; below everything otherwise.
    let gap = entries.firstIndex { point.y > $0.view.frame.midY } ?? entries.count

    guard gap > 0 else {
      // Above everything: top of the first group, or top of the list.
      if case .header(let group, _) = entries[0] {
        return DropTarget(
          groupID: group.id, index: block(of: group).start, lineBefore: 0, header: nil)
      }
      return DropTarget(groupID: nil, index: 0, lineBefore: 0, header: nil)
    }

    switch entries[gap - 1] {
    case .header(let group, _):
      let b = block(of: group)
      return DropTarget(
        groupID: group.id, index: group.isCollapsed ? b.end : b.start, lineBefore: gap,
        header: nil)
    case .ungroupedDivider:
      return DropTarget(groupID: nil, index: groupedCount, lineBefore: gap, header: nil)
    case .card(_, _, let index, let groupID):
      return DropTarget(groupID: groupID, index: index + 1, lineBefore: gap, header: nil)
    }
  }

  private func showDropIndicator(for target: DropTarget) {
    if let header = target.header {
      if highlightedHeader !== header {
        highlightedHeader?.isDropHighlighted = false
        header.isDropHighlighted = true
        highlightedHeader = header
      }
      dropIndicator.isHidden = true
      lastDropIndex = nil
      return
    }
    showDropLine(before: target.lineBefore)
  }

  /// Draw the insertion line before entry `index` (`entries.count` = below all).
  private func showDropLine(before index: Int) {
    highlightedHeader?.isDropHighlighted = false
    highlightedHeader = nil

    if !dropIndicator.isHidden, lastDropIndex == index { return }
    let views = entries.map(\.view)
    guard !views.isEmpty else {
      hideDropIndicator()
      return
    }

    let stackFrame = cardStack.frame
    let lineY: CGFloat
    if index <= 0 {
      lineY = views[0].frame.maxY + stackFrame.minY + 2
    } else if index >= views.count {
      lineY = views[views.count - 1].frame.minY + stackFrame.minY - 3
    } else {
      let above = views[index - 1]
      let below = views[index]
      let gapMid = (above.frame.minY + below.frame.maxY) / 2
      lineY = gapMid + stackFrame.minY
    }

    dropIndicator.frame = NSRect(
      x: stackFrame.minX, y: lineY - 1, width: stackFrame.width, height: 2)
    dropIndicator.isHidden = false
    lastDropIndex = index
  }

  private func hideDropIndicator() {
    dropIndicator.isHidden = true
    lastDropIndex = nil
    highlightedHeader?.isDropHighlighted = false
    highlightedHeader = nil
  }

  // MARK: - Card context-menu actions

  // Card menu items target the bar, not the card: cards are torn down and
  // rebuilt whenever the session list or PR status changes,
  // and NSMenuItem holds its target weakly — targeting the card meant any
  // rebuild while the menu or a confirmation sheet was open silently dropped
  // the action (issue #13). The bar lives as long as the window, and each
  // item retains its Session via `representedObject`.

  private func payload(from sender: NSMenuItem) -> SessionCardMenuPayload? {
    sender.representedObject as? SessionCardMenuPayload
  }

  @objc fileprivate func renameSessionFromMenu(_ sender: NSMenuItem) {
    guard let payload = payload(from: sender) else { return }
    runRenameDialog(for: payload.session)
  }

  @objc fileprivate func restartSessionFromMenu(_ sender: NSMenuItem) {
    guard let payload = payload(from: sender) else { return }
    SessionManager.shared.restartSession(id: payload.session.id)
  }

  @objc fileprivate func closeSessionFromMenu(_ sender: NSMenuItem) {
    guard let payload = payload(from: sender) else { return }
    SessionManager.shared.closeSession(id: payload.session.id)
  }

  @objc fileprivate func openPRFromMenu(_ sender: NSMenuItem) {
    guard let url = payload(from: sender)?.prURL else { return }
    NSWorkspace.shared.open(url)
  }

  @objc fileprivate func copyWorktreePathFromMenu(_ sender: NSMenuItem) {
    guard let path = payload(from: sender)?.session.worktreePath else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(path, forType: .string)
  }

  @objc fileprivate func removeSessionAndWorktreeFromMenu(_ sender: NSMenuItem) {
    guard let session = payload(from: sender)?.session else { return }
    guard let path = session.worktreePath else { return }
    guard let repoRoot = WorktreeManager.managedRepoRoot(forWorktreePath: path) else { return }

    let alert = NSAlert()
    alert.messageText = "Remove Session and Worktree?"
    alert.informativeText =
      "This will close the session and remove the worktree at:\n\(path)\n\n"
      + "Any uncommitted changes will be lost."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Remove")
    alert.addButton(withTitle: "Cancel")

    guard let win = window else { return }
    alert.beginSheetModal(for: win) { response in
      guard response == .alertFirstButtonReturn else { return }
      SessionManager.shared.closeSession(id: session.id)

      DispatchQueue.global(qos: .userInitiated).async {
        let result = Result {
          try WorktreeManager.shared.removeWorktree(repoRoot: repoRoot, path: path)
        }
        DispatchQueue.main.async {
          if case .failure(let error) = result {
            let errAlert = NSAlert()
            errAlert.messageText = "Remove Failed"
            errAlert.informativeText = error.localizedDescription
            errAlert.runModal()
          }
        }
      }
    }
  }

  /// Rename dialog for a session. Lives on the bar (not the card) so the
  /// sheet's completion survives card rebuilds; `session` is retained by
  /// the closure and updated in place.
  fileprivate func runRenameDialog(for session: Session) {
    let alert = NSAlert()
    alert.messageText = "Rename Session"
    alert.informativeText = "Enter a new name for \"\(session.name)\":"
    alert.addButton(withTitle: "Rename")
    alert.addButton(withTitle: "Cancel")

    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
    input.stringValue = session.name
    alert.accessoryView = input

    guard let win = window else { return }
    alert.beginSheetModal(for: win) { response in
      guard response == .alertFirstButtonReturn else { return }
      let newName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !newName.isEmpty else { return }
      session.name = newName
      SessionEvents.postListChanged()
    }
  }
}

/// Payload for a group header's menu items (see the card payload below for
/// why menu items target the bar and carry their subject).
private final class SessionGroupMenuPayload: NSObject {
  let group: SessionGroup
  init(group: SessionGroup) { self.group = group }
}

// MARK: - Group header

/// Collapsible header above a group's cards: chevron, color dot, name, and
/// member count. Collapsed headers also show one status dot per member so
/// a hidden session that needs attention still shows through. Click toggles
/// collapse; double-click edits; right-click for edit/delete.
final class SessionGroupHeader: NSView {
  private let group: SessionGroup
  private let members: [Session]
  private let containsActive: Bool
  private weak var bar: DFSessionBar?
  private var statusDots: [(NSView, Session)] = []

  /// Set by the bar while a card is dragged over a collapsed header.
  var isDropHighlighted = false {
    didSet { applyStyling() }
  }

  init(group: SessionGroup, members: [Session], containsActive: Bool, bar: DFSessionBar?) {
    self.group = group
    self.members = members
    self.containsActive = containsActive
    self.bar = bar
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.cornerRadius = 6
    layer?.borderWidth = 1
    build()
    applyStyling()

    let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
    addGestureRecognizer(click)
    let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(doubleClicked))
    doubleClick.numberOfClicksRequired = 2
    addGestureRecognizer(doubleClick)

    menu = makeContextMenu()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  private func build() {
    let chevronName = group.isCollapsed ? "chevron.right" : "chevron.down"
    let chevron = NSImageView(
      image: NSImage(systemSymbolName: chevronName, accessibilityDescription: nil) ?? NSImage())
    chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
    chevron.contentTintColor = Theme.text3
    chevron.translatesAutoresizingMaskIntoConstraints = false

    let dot = NSView()
    dot.wantsLayer = true
    dot.layer?.backgroundColor = group.color.cgColor
    dot.layer?.cornerRadius = 4
    dot.translatesAutoresizingMaskIntoConstraints = false

    let name = NSTextField(labelWithString: group.name)
    name.font = Theme.mono(11, weight: .semibold)
    name.textColor = Theme.text1
    name.lineBreakMode = .byTruncatingTail
    name.maximumNumberOfLines = 1
    name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    name.translatesAutoresizingMaskIntoConstraints = false

    let count = NSTextField(labelWithString: "\(members.count)")
    count.font = Theme.mono(9, weight: .medium)
    count.textColor = Theme.text3
    count.alignment = .center
    count.wantsLayer = true
    count.layer?.backgroundColor = Theme.surface3.cgColor
    count.layer?.cornerRadius = 3
    count.translatesAutoresizingMaskIntoConstraints = false

    for v in [chevron, dot, name, count] as [NSView] { addSubview(v) }

    var constraints: [NSLayoutConstraint] = [
      heightAnchor.constraint(equalToConstant: 26),
      chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
      chevron.widthAnchor.constraint(equalToConstant: 10),
      dot.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 6),
      dot.centerYAnchor.constraint(equalTo: centerYAnchor),
      dot.widthAnchor.constraint(equalToConstant: 8),
      dot.heightAnchor.constraint(equalToConstant: 8),
      name.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 7),
      name.centerYAnchor.constraint(equalTo: centerYAnchor),
      count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      count.centerYAnchor.constraint(equalTo: centerYAnchor),
      count.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
      count.heightAnchor.constraint(equalToConstant: 13),
    ]

    if group.isCollapsed, !members.isEmpty {
      // One status dot per hidden member, newest last, capped so a big group
      // can't push the name off the header.
      let dots = NSStackView()
      dots.orientation = .horizontal
      dots.spacing = 3
      dots.translatesAutoresizingMaskIntoConstraints = false
      for session in members.prefix(8) {
        let d = NSView()
        d.wantsLayer = true
        d.layer?.cornerRadius = 2.5
        d.layer?.backgroundColor = session.state.color.cgColor
        d.translatesAutoresizingMaskIntoConstraints = false
        d.widthAnchor.constraint(equalToConstant: 5).isActive = true
        d.heightAnchor.constraint(equalToConstant: 5).isActive = true
        dots.addArrangedSubview(d)
        statusDots.append((d, session))
      }
      addSubview(dots)
      constraints.append(contentsOf: [
        dots.trailingAnchor.constraint(equalTo: count.leadingAnchor, constant: -8),
        dots.centerYAnchor.constraint(equalTo: centerYAnchor),
        name.trailingAnchor.constraint(lessThanOrEqualTo: dots.leadingAnchor, constant: -8),
      ])
    } else {
      constraints.append(
        name.trailingAnchor.constraint(lessThanOrEqualTo: count.leadingAnchor, constant: -8))
    }
    NSLayoutConstraint.activate(constraints)
  }

  /// Update the collapsed status dots in place on a state tick.
  func refreshDynamic() {
    for (dot, session) in statusDots {
      dot.layer?.backgroundColor = session.state.color.cgColor
    }
  }

  private func applyStyling() {
    let tint = group.color
    if isDropHighlighted {
      layer?.backgroundColor =
        (Theme.surface3.blended(withFraction: 0.35, of: tint) ?? Theme.surface3).cgColor
      layer?.borderColor = tint.cgColor
    } else {
      layer?.backgroundColor =
        (Theme.surface2.blended(withFraction: 0.18, of: tint) ?? Theme.surface2).cgColor
      // A collapsed group hiding the active session keeps a colored ring so
      // the user can still find it.
      layer?.borderColor =
        (group.isCollapsed && containsActive)
        ? tint.withAlphaComponent(0.8).cgColor : NSColor.clear.cgColor
    }
  }

  private func makeContextMenu() -> NSMenu {
    let menu = NSMenu()
    let payload = SessionGroupMenuPayload(group: group)
    func add(_ title: String, _ action: Selector) {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
      item.target = bar
      item.representedObject = payload
      menu.addItem(item)
    }
    add(
      group.isCollapsed ? "Expand Group" : "Collapse Group",
      #selector(DFSessionBar.toggleCollapseFromMenu(_:)))
    add("Edit Group…", #selector(DFSessionBar.editGroupFromMenu(_:)))
    menu.addItem(NSMenuItem.separator())
    add("Delete Group", #selector(DFSessionBar.deleteGroupFromMenu(_:)))
    return menu
  }

  @objc private func clicked() {
    bar?.toggleCollapse(group)
  }

  @objc private func doubleClicked() {
    bar?.runEditDialog(for: group)
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }

  // MARK: - Drag source (reorder the whole group)

  private var mouseDownPoint: NSPoint?

  override func mouseDown(with event: NSEvent) {
    mouseDownPoint = event.locationInWindow
    super.mouseDown(with: event)
  }

  override func mouseDragged(with event: NSEvent) {
    guard let start = mouseDownPoint else {
      super.mouseDragged(with: event)
      return
    }
    let dx = event.locationInWindow.x - start.x
    let dy = event.locationInWindow.y - start.y
    // 4pt threshold so click (collapse) and double-click (edit) still register.
    if dx * dx + dy * dy < 16 { return }
    mouseDownPoint = nil
    beginDrag(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    mouseDownPoint = nil
    super.mouseUp(with: event)
  }

  private func beginDrag(with event: NSEvent) {
    let item = NSPasteboardItem()
    item.setString(group.id.uuidString, forType: .dfGroupDrag)
    let dragItem = NSDraggingItem(pasteboardWriter: item)
    let (frame, image) = dragSnapshot()
    dragItem.setDraggingFrame(frame, contents: image)
    let dragSession = beginDraggingSession(with: [dragItem], event: event, source: self)
    dragSession.animatesToStartingPositionsOnCancelOrFail = true
  }

  /// Snapshot of the header together with its visible member rows, so the
  /// drag image shows the whole block that is moving. Frame is in the
  /// header's coordinates.
  private func dragSnapshot() -> (NSRect, NSImage) {
    guard let stack = superview else { return (bounds, snapshot(of: self, in: bounds)) }
    var region = frame
    for view in stack.subviews where view !== self {
      if let row = view as? GroupedCardRow, row.groupID == group.id {
        region = region.union(view.frame)
      }
    }
    let image = snapshot(of: stack, in: region)
    return (convert(region, from: stack), image)
  }

  private func snapshot(of view: NSView, in rect: NSRect) -> NSImage {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return NSImage() }
    view.cacheDisplay(in: rect, to: rep)
    let img = NSImage(size: rect.size)
    img.addRepresentation(rep)
    return img
  }
}

extension SessionGroupHeader: NSDraggingSource {
  func draggingSession(
    _ session: NSDraggingSession,
    sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    context == .withinApplication ? .move : []
  }

  func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
    bar?.setGroupDimmed(group.id, true)
  }

  func draggingSession(
    _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
  ) {
    bar?.setGroupDimmed(group.id, false)
  }
}

/// A grouped card, indented under its header with a rail in the group color.
final class GroupedCardRow: NSView {
  /// The group this row belongs to, so a group drag can find its rows.
  let groupID: UUID

  init(card: SessionCard, group: SessionGroup) {
    self.groupID = group.id
    let color = group.color
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    let rail = NSView()
    rail.wantsLayer = true
    rail.layer?.backgroundColor = color.withAlphaComponent(0.7).cgColor
    rail.layer?.cornerRadius = 1
    rail.translatesAutoresizingMaskIntoConstraints = false
    addSubview(rail)
    addSubview(card)
    NSLayoutConstraint.activate([
      rail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
      rail.widthAnchor.constraint(equalToConstant: 2),
      rail.topAnchor.constraint(equalTo: topAnchor, constant: 2),
      rail.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
      card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      card.trailingAnchor.constraint(equalTo: trailingAnchor),
      card.topAnchor.constraint(equalTo: topAnchor),
      card.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }
}

/// Payload stored on a session card's menu items so the action handler on
/// DFSessionBar still knows which session (and PR) the user right-clicked
/// after the originating card has been rebuilt.
private final class SessionCardMenuPayload: NSObject {
  let session: Session
  let prURL: URL?
  /// Destination for a "Move to Group" item; nil = ungrouped.
  let targetGroupID: UUID?
  init(session: Session, prURL: URL?, targetGroupID: UUID? = nil) {
    self.session = session
    self.prURL = prURL
    self.targetGroupID = targetGroupID
  }
}

// MARK: - Session Card (Live Data)

final class SessionCard: NSView {

  private let session: Session
  private let index: Int
  private let isActive: Bool
  private weak var bar: DFSessionBar?
  private var glowLayer: CALayer?
  private var mouseDownPoint: NSPoint?
  private var prPill: NSTextField?
  private var prURL: URL?

  // Views `refreshDynamic()` updates in place. Everything else on the card
  // is fixed for its lifetime; structural changes rebuild the card instead.
  private var accentBar: CALayer?
  private var dot: NSView!
  private var statusLabel: NSTextField!
  private var modelLabel: NSTextField!
  private var costLabel: NSTextField!
  private var contextLabel: NSTextField?

  init(session: Session, isActive: Bool, index: Int, bar: DFSessionBar?) {
    self.session = session
    self.index = index
    self.isActive = isActive
    self.bar = bar
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.backgroundColor = Theme.surface2.cgColor
    layer?.cornerRadius = 8

    // Structural chrome fixed for the card's lifetime; all status-driven
    // styling (wash, border color, glow, dot) is applied by
    // `applyStateStyling()`, shared with the in-place refresh path.
    if isActive {
      // Status-coloured border and left bar so the active card visually
      // telegraphs what claude is currently doing.
      layer?.borderWidth = 1.5

      let accentBar = CALayer()
      accentBar.frame = CGRect(x: 0, y: 0, width: 4, height: bounds.height)
      accentBar.autoresizingMask = [.layerHeightSizable]
      accentBar.cornerRadius = 0
      layer?.masksToBounds = true
      layer?.addSublayer(accentBar)
      self.accentBar = accentBar
    } else {
      // Dimmed inactive card, still tinted by its status color
      layer?.borderWidth = 0
      alphaValue = 0.6
    }

    buildCard()
    applyStateStyling()

    // Click to switch
    let click = NSClickGestureRecognizer(target: self, action: #selector(clicked(_:)))
    addGestureRecognizer(click)

    // Double-click to rename
    let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(doubleClicked))
    doubleClick.numberOfClicksRequired = 2
    addGestureRecognizer(doubleClick)

    // On macOS, single-click fires alongside double-click; the session
    // switch is idempotent so this is acceptable behavior.

    // Right-click context menu. Built after buildCard so the PR pill's URL
    // is known.
    menu = makeContextMenu()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  @objc private func clicked(_ recognizer: NSClickGestureRecognizer) {
    // The card-level click gesture consumes the mouseUp before the pill's own
    // handlers can see it, so pill clicks have to be routed from here.
    if let pill = prPill, let url = prURL,
      pill.frame.contains(recognizer.location(in: self))
    {
      NSWorkspace.shared.open(url)
      return
    }
    SessionManager.shared.switchTo(index: index)
  }

  private func makeContextMenu() -> NSMenu {
    let menu = NSMenu()
    // Items target the bar with the session in `representedObject`, so the
    // action still fires after this card has been rebuilt (see the actions'
    // comment on DFSessionBar).
    let payload = SessionCardMenuPayload(session: session, prURL: prURL)
    func add(_ title: String, _ action: Selector) {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
      item.target = bar
      item.representedObject = payload
      menu.addItem(item)
    }
    add("Rename Session…", #selector(DFSessionBar.renameSessionFromMenu(_:)))
    add("Restart Session", #selector(DFSessionBar.restartSessionFromMenu(_:)))
    let groups = SessionManager.shared.groups
    if !groups.isEmpty {
      let submenu = NSMenu()
      func addTarget(_ title: String, groupID: UUID?) {
        let item = NSMenuItem(
          title: title, action: #selector(DFSessionBar.moveToGroupFromMenu(_:)),
          keyEquivalent: "")
        item.target = bar
        item.representedObject = SessionCardMenuPayload(
          session: session, prURL: prURL, targetGroupID: groupID)
        item.state = session.groupID == groupID ? .on : .off
        submenu.addItem(item)
      }
      for g in groups { addTarget(g.name, groupID: g.id) }
      submenu.addItem(NSMenuItem.separator())
      addTarget("No Group", groupID: nil)
      let parent = NSMenuItem(title: "Move to Group", action: nil, keyEquivalent: "")
      parent.submenu = submenu
      menu.addItem(parent)
    }
    if prURL != nil || session.worktreePath != nil {
      menu.addItem(NSMenuItem.separator())
      if prURL != nil {
        add("Open Pull Request", #selector(DFSessionBar.openPRFromMenu(_:)))
      }
      if session.worktreePath != nil {
        add("Copy Worktree Path", #selector(DFSessionBar.copyWorktreePathFromMenu(_:)))
      }
    }
    menu.addItem(NSMenuItem.separator())
    add("Close Session", #selector(DFSessionBar.closeSessionFromMenu(_:)))
    if session.worktreePath != nil {
      add(
        "Remove Session and Worktree…",
        #selector(DFSessionBar.removeSessionAndWorktreeFromMenu(_:)))
    }
    return menu
  }

  @objc private func doubleClicked() {
    bar?.runRenameDialog(for: session)
  }

  private func buildCard() {
    // Avatar
    let avatar = GenerativeAvatar(seed: session.avatarSeed)
    avatar.translatesAutoresizingMaskIntoConstraints = false

    // Positional Cmd+N badge in the card's corner. Only the first nine
    // sessions have a shortcut; renumbers automatically since cards are
    // rebuilt whenever the session list changes.
    let numberBadge: NSTextField? = {
      guard index < 9 else { return nil }
      let badge = NSTextField(labelWithString: "\(index + 1)")
      badge.font = Theme.mono(9, weight: .medium)
      badge.textColor = isActive ? Theme.accent : Theme.text3
      badge.alignment = .center
      badge.wantsLayer = true
      badge.layer?.backgroundColor = Theme.surface3.cgColor
      badge.layer?.cornerRadius = 3
      badge.toolTip = "Switch to session (\u{2318}\(index + 1))"
      badge.translatesAutoresizingMaskIntoConstraints = false
      return badge
    }()

    // Name
    let nameLabel = NSTextField(labelWithString: session.displayName)
    nameLabel.font = Theme.mono(12, weight: .medium)
    nameLabel.textColor = Theme.text1
    nameLabel.lineBreakMode = .byTruncatingTail
    nameLabel.maximumNumberOfLines = 1
    nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    nameLabel.translatesAutoresizingMaskIntoConstraints = false

    // Status dot + label. Color, pulse, and shadow come from
    // `applyStateStyling()`.
    dot = NSView()
    dot.wantsLayer = true
    dot.layer?.cornerRadius = 3.5
    dot.translatesAutoresizingMaskIntoConstraints = false

    statusLabel = NSTextField(labelWithString: session.state.label)
    statusLabel.font = Theme.mono(9, weight: .medium)
    statusLabel.translatesAutoresizingMaskIntoConstraints = false

    // Model
    modelLabel = NSTextField(labelWithString: session.model)
    modelLabel.font = Theme.mono(9)
    modelLabel.textColor = Theme.text3
    modelLabel.translatesAutoresizingMaskIntoConstraints = false

    // Cost. The label shows the current run (matches Claude Code's /usage);
    // the tooltip also reveals this tab's lifetime spend across all runs.
    costLabel = NSTextField(labelWithString: String(format: "$%.2f", session.cost))
    costLabel.font = Theme.mono(11)
    costLabel.textColor = Theme.text2
    costLabel.toolTip = String(
      format: "This run: $%.2f (matches /usage)\nThis tab, all runs: $%.2f",
      session.cost, session.lifetimeCost)
    costLabel.translatesAutoresizingMaskIntoConstraints = false

    // Context window usage (e.g. "42.1K / 200K"). Hidden until the JSONL
    // watcher has parsed at least one assistant turn.
    contextLabel = {
      guard session.contextTokens > 0 else { return nil }
      let label = NSTextField(
        labelWithString:
          "\(TokenFormat.short(session.contextTokens)) / \(TokenFormat.short(session.maxContextTokens))"
      )
      label.font = Theme.mono(9)
      label.textColor = Theme.text3
      label.translatesAutoresizingMaskIntoConstraints = false
      return label
    }()

    // Repo the session lives in, bottom right. Branch names alone are
    // ambiguous once several projects are open. Truncates from the head so
    // the distinctive tail of a long name survives a narrow sidebar.
    let repoLabel: NSTextField? = session.repoName.map { repoName in
      let label = NSTextField(labelWithString: repoName)
      label.font = Theme.mono(9)
      label.textColor = Theme.text3
      label.lineBreakMode = .byTruncatingHead
      label.maximumNumberOfLines = 1
      label.toolTip = session.repoRoot
      label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      label.translatesAutoresizingMaskIntoConstraints = false
      return label
    }

    for v in [avatar, nameLabel, dot, statusLabel, modelLabel, costLabel] as [NSView] {
      addSubview(v)
    }
    if let cl = contextLabel { addSubview(cl) }
    if let rl = repoLabel { addSubview(rl) }
    if let badge = numberBadge { addSubview(badge) }

    // PR status pill (only if gh reports a PR for this worktree).
    let prStatus = PRMonitor.shared.status(for: session.id)
    let prPill: NSTextField? = prStatus.map { status in
      let label = makePRPill(status: status)
      label.translatesAutoresizingMaskIntoConstraints = false
      addSubview(label)
      self.prPill = label
      self.prURL = URL(string: status.url)
      return label
    }

    // The compact card grows to 64pt when a repo label is present: at 56pt
    // the label would butt against the status/PR row.
    let cardHeight: CGFloat
    if contextLabel != nil {
      cardHeight = 72
    } else {
      cardHeight = repoLabel == nil ? 56 : 64
    }

    var constraints: [NSLayoutConstraint] = [
      heightAnchor.constraint(equalToConstant: cardHeight),

      avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      avatar.topAnchor.constraint(equalTo: topAnchor, constant: 10),
      avatar.widthAnchor.constraint(equalToConstant: 40),
      avatar.heightAnchor.constraint(equalToConstant: 40),

      nameLabel.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 8),
      nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
      nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: costLabel.leadingAnchor, constant: -8),

      costLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      costLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),

      dot.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 8),
      dot.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 5),
      dot.widthAnchor.constraint(equalToConstant: 7),
      dot.heightAnchor.constraint(equalToConstant: 7),

      statusLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 4),
      statusLabel.centerYAnchor.constraint(equalTo: dot.centerYAnchor),

      modelLabel.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 8),
      modelLabel.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
    ]
    if let cl = contextLabel {
      constraints.append(contentsOf: [
        cl.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 8),
        cl.topAnchor.constraint(equalTo: dot.bottomAnchor, constant: 5),
      ])
    }
    if let rl = repoLabel {
      constraints.append(rl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10))
      if let cl = contextLabel {
        // Share the bottom row with the context label; the repo label yields
        // width first (low compression resistance) so the context figure
        // never gets pushed around.
        constraints.append(contentsOf: [
          rl.centerYAnchor.constraint(equalTo: cl.centerYAnchor),
          cl.trailingAnchor.constraint(lessThanOrEqualTo: rl.leadingAnchor, constant: -8),
        ])
      } else {
        constraints.append(contentsOf: [
          rl.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
          rl.leadingAnchor.constraint(greaterThanOrEqualTo: avatar.trailingAnchor, constant: 8),
        ])
      }
    }
    if let pill = prPill {
      constraints.append(contentsOf: [
        pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        pill.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
      ])
    }
    if let badge = numberBadge {
      constraints.append(contentsOf: [
        badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
        badge.topAnchor.constraint(equalTo: topAnchor, constant: 5),
        badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 13),
        badge.heightAnchor.constraint(equalToConstant: 13),
      ])
    }
    NSLayoutConstraint.activate(constraints)
  }

  /// Re-apply everything the session's mutable state drives (colors, pulses,
  /// labels) to the existing views, without tearing the card down — that
  /// preserves hover, open menus, and in-flight drags across the once-a-second
  /// ticks of a working agent. Returns false when the change is structural
  /// (the context row appears once contextTokens > 0) and the bar must
  /// rebuild the card instead.
  func refreshDynamic() -> Bool {
    guard (session.contextTokens > 0) == (contextLabel != nil) else { return false }
    applyStateStyling()
    statusLabel.stringValue = session.state.label
    modelLabel.stringValue = session.model
    costLabel.stringValue = String(format: "$%.2f", session.cost)
    costLabel.toolTip = String(
      format: "This run: $%.2f (matches /usage)\nThis tab, all runs: $%.2f",
      session.cost, session.lifetimeCost)
    contextLabel?.stringValue =
      "\(TokenFormat.short(session.contextTokens)) / \(TokenFormat.short(session.maxContextTokens))"
    return true
  }

  /// Status-driven styling shared by init and `refreshDynamic()`: the card
  /// wash, border/accent color, pulsing glow, status dot, and status label
  /// color. The card background carries a dimmed wash of the status color so
  /// a glance at the session bar shows what every session is doing.
  private func applyStateStyling() {
    let stateColor = session.state.color

    if isActive {
      // Bright background + status-coloured border and left bar so the
      // active card visually telegraphs what claude is currently doing.
      layer?.backgroundColor =
        (Theme.surface3.blended(withFraction: 0.16, of: stateColor) ?? Theme.surface3).cgColor
      layer?.borderColor = stateColor.cgColor
      accentBar?.backgroundColor = stateColor.cgColor
    } else {
      // Dimmed inactive card, still tinted by its status color
      layer?.backgroundColor =
        (Theme.surface1.blended(withFraction: 0.12, of: stateColor) ?? Theme.surface1).cgColor
    }

    // Pulsing border glow for attention/input states
    glowLayer?.removeFromSuperlayer()
    glowLayer = nil
    let needsPulse = session.state == .needsAttention || session.state == .userInput
    if needsPulse {
      let glow = CALayer()
      glow.cornerRadius = 8
      glow.borderWidth = 1.5
      glow.borderColor = stateColor.cgColor
      glow.frame = bounds
      glow.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
      layer?.addSublayer(glow)
      glowLayer = glow

      let pulse = CABasicAnimation(keyPath: "opacity")
      pulse.fromValue = 0.3
      pulse.toValue = 1.0
      pulse.duration = 1.4
      pulse.autoreverses = true
      pulse.repeatCount = .infinity
      pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      glow.add(pulse, forKey: "borderPulse")
    }

    // Status dot color plus breathing pulse and glow shadow while attention
    // or input is wanted.
    dot.layer?.backgroundColor = stateColor.cgColor
    dot.layer?.removeAnimation(forKey: "dotPulse")
    if needsPulse {
      let dotPulse = CABasicAnimation(keyPath: "opacity")
      dotPulse.fromValue = 0.35
      dotPulse.toValue = 1.0
      dotPulse.duration = 1.4
      dotPulse.autoreverses = true
      dotPulse.repeatCount = .infinity
      dotPulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      dot.layer?.add(dotPulse, forKey: "dotPulse")

      // Soft glow shadow behind the dot
      dot.layer?.shadowColor = stateColor.cgColor
      dot.layer?.shadowOffset = .zero
      dot.layer?.shadowRadius = 6
      dot.layer?.shadowOpacity = 0.8
      dot.layer?.masksToBounds = false
    } else {
      dot.layer?.shadowOpacity = 0
    }

    statusLabel.textColor = stateColor
  }

  private func makePRPill(status: PRStatus) -> NSTextField {
    let field = PRLinkPill(labelWithString: status.displayText)
    field.font = Theme.mono(9, weight: .medium)
    field.textColor = status.displayColor
    field.toolTip = status.url
    return field
  }

  // MARK: - Drag source

  override func mouseDown(with event: NSEvent) {
    mouseDownPoint = event.locationInWindow
    super.mouseDown(with: event)
  }

  override func mouseDragged(with event: NSEvent) {
    guard let start = mouseDownPoint else {
      super.mouseDragged(with: event)
      return
    }
    let dx = event.locationInWindow.x - start.x
    let dy = event.locationInWindow.y - start.y
    // 4pt threshold so click and double-click still register.
    if dx * dx + dy * dy < 16 { return }
    mouseDownPoint = nil
    beginDrag(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    mouseDownPoint = nil
    super.mouseUp(with: event)
  }

  private func beginDrag(with event: NSEvent) {
    let item = NSPasteboardItem()
    item.setString(String(index), forType: .dfSessionDrag)
    let dragItem = NSDraggingItem(pasteboardWriter: item)
    dragItem.setDraggingFrame(bounds, contents: snapshotImage())
    let dragSession = beginDraggingSession(with: [dragItem], event: event, source: self)
    dragSession.animatesToStartingPositionsOnCancelOrFail = true
  }

  private func snapshotImage() -> NSImage {
    guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return NSImage() }
    cacheDisplay(in: bounds, to: rep)
    let img = NSImage(size: bounds.size)
    img.addRepresentation(rep)
    return img
  }
}

/// PR status pill that reads as a link. Click handling lives in the card's
/// gesture handler (the card's click recognizer consumes the mouseUp before
/// this view would see it); this subclass just supplies the link cursor and
/// keeps a pill click from doubling as a card drag start.
private final class PRLinkPill: NSTextField {
  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }

  override func mouseDown(with event: NSEvent) {}
}

extension SessionCard: NSDraggingSource {
  func draggingSession(
    _ session: NSDraggingSession,
    sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    context == .withinApplication ? .move : []
  }

  func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
    alphaValue = 0.3
  }

  func draggingSession(
    _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
  ) {
    alphaValue = isActive ? 1.0 : 0.6
  }
}

// MARK: - Generative Avatar

/// A unique pixel-art robot generated from the session seed. The same seed
/// always produces the same robot, so each session keeps a stable, friendly,
/// instantly recognizable identity. The seeded DJB2 -> LCG stream picks the
/// robot's palette, head shape, antenna, eyes, mouth and side details, so the
/// structure (not just the colour) varies between sessions and look-alikes are
/// rare.
final class GenerativeAvatar: NSView {
  let seed: String

  init(seed: String) {
    self.seed = seed
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 9
    layer?.masksToBounds = true
    layer?.borderWidth = 1
    layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  // Keep the corner radius proportional across the sizes the avatar is used at.
  override func layout() {
    super.layout()
    layer?.cornerRadius = bounds.width * 0.22
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    drawPixelRobot(seed: seed, into: ctx, bounds: bounds)
  }
}

/// Renders a deterministic pixel-art robot for `seed` into `ctx`, filling
/// `bounds`. Kept as a free function (not a method) so it can be reused outside
/// the view. Pure CoreGraphics, no asset files.
func drawPixelRobot(seed: String, into ctx: CGContext, bounds: CGRect) {
  // ---- Seeded RNG: a DJB2 hash of the seed feeds an LCG we pull every choice
  // from, so the same seed always grows the same robot. ----
  var hash: UInt64 = 5381
  for byte in seed.utf8 { hash = ((hash &<< 5) &+ hash) &+ UInt64(byte) }
  var rngState = hash | 1
  func bits() -> UInt64 {
    rngState = rngState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return rngState >> 17
  }
  func roll(_ n: Int) -> Int { Int(bits() % UInt64(n)) }
  func chance(_ p: Int, outOf q: Int) -> Bool { roll(q) < p }

  // ---- Palette: a single seeded hue drives a small, cohesive metal palette. ----
  func color(_ h: CGFloat, _ s: CGFloat, _ b: CGFloat) -> CGColor {
    let c = NSColor(hue: h, saturation: s, brightness: b, alpha: 1)
    let srgb = c.usingColorSpace(.sRGB) ?? c
    return CGColor(
      srgbRed: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent, alpha: 1)
  }
  func wrapHue(_ h: CGFloat) -> CGFloat {
    let m = h.truncatingRemainder(dividingBy: 1)
    return m < 0 ? m + 1 : m
  }
  let baseHue = CGFloat(hash % 360) / 360
  let bg = color(baseHue, 0.40, 0.13)  // dark tinted tile
  let body = color(baseHue, 0.16, 0.80)  // robot "metal"
  let bodyShade = color(baseHue, 0.24, 0.52)  // darker metal for depth
  let bodyLight = color(baseHue, 0.08, 0.95)  // highlight sheen
  // Eyes glow either warm amber (the app's energy) or a vivid complementary hue.
  let eye =
    chance(1, outOf: 2) ? color(34.0 / 360, 0.88, 1.0) : color(wrapHue(baseHue + 0.5), 0.80, 1.0)

  // ---- Pixel grid: chunky cells, left/right symmetric like a face. ----
  let grid = 11
  let center = grid / 2  // 5
  let side = min(bounds.width, bounds.height)
  let ox = bounds.minX + (bounds.width - side) / 2
  let oy = bounds.minY + (bounds.height - side) / 2
  // Pixel-snapped edges so neighbouring cells share crisp seams at any size.
  func edge(_ i: Int) -> CGFloat { (CGFloat(i) * side / CGFloat(grid)).rounded() }

  var cells = [[CGColor?]](repeating: [CGColor?](repeating: nil, count: grid), count: grid)
  func put(_ col: Int, _ row: Int, _ c: CGColor) {
    guard row >= 0, row < grid, col >= 0, col < grid else { return }
    cells[row][col] = c
  }
  // Mirror across the vertical centre line so the robot is symmetric.
  func sym(_ col: Int, _ row: Int, _ c: CGColor) {
    put(col, row, c)
    put(grid - 1 - col, row, c)
  }

  // Background tile.
  ctx.setFillColor(bg)
  ctx.fill(CGRect(x: ox, y: oy, width: side, height: side))

  // ---- Head: rows 0-1 hold the antenna, the head spans rows 2...9. ----
  let headTop = 2
  let headBot = 9
  let headW = chance(1, outOf: 2) ? 9 : 7
  let hl = (grid - headW) / 2
  let hr = grid - 1 - hl
  for r in headTop...headBot {
    for c in hl...hr { put(c, r, body) }
  }
  for c in hl...hr { put(c, headBot, bodyShade) }  // chin shadow
  put(hl, headTop, bodyLight)  // top-left sheen
  if chance(1, outOf: 2) {  // rounded head corners
    sym(hl, headTop, bg)
    sym(hl, headBot, bg)
  }

  // ---- Antenna ----
  switch roll(3) {
  case 0:
    break  // none
  case 1:  // single centre antenna
    put(center, 1, bodyShade)
    put(center, 0, eye)
  default:  // twin antennae
    sym(hl + 1, 1, bodyShade)
    sym(hl + 1, 0, eye)
  }

  // ---- Side bolts / ears ----
  if chance(1, outOf: 2), hl - 1 >= 0 {
    sym(hl - 1, 5, bodyShade)
  }

  // ---- Eyes (row 4) ----
  switch roll(4) {
  case 0:  // two dot eyes
    sym(center - 2, 4, eye)
  case 1:  // tall eyes
    sym(center - 2, 4, eye)
    sym(center - 2, 5, eye)
  case 2:  // visor bar
    for c in (center - 2)...(center + 2) { put(c, 4, eye) }
  default:  // single wide eye
    for c in (center - 1)...(center + 1) { put(c, 4, eye) }
  }

  // ---- Mouth (rows 6-7) ----
  switch roll(4) {
  case 0:  // grille teeth
    put(center - 2, 7, bodyShade)
    put(center, 7, bodyShade)
    put(center + 2, 7, bodyShade)
  case 1:  // straight bar
    for c in (center - 2)...(center + 2) { put(c, 7, bodyShade) }
  case 2:  // smile
    sym(center - 2, 6, bodyShade)
    for c in (center - 1)...(center + 1) { put(c, 7, bodyShade) }
  default:  // grid grille
    for r in 6...7 {
      for c in (center - 2)...(center + 2) where (r + c) % 2 == 0 { put(c, r, bodyShade) }
    }
  }

  // ---- Cheek lights ----
  if chance(1, outOf: 3) {
    sym(hl + 1, 5, eye)
  }

  // ---- Render: row 0 is the top row. ----
  for r in 0..<grid {
    for c in 0..<grid {
      guard let cellColor = cells[r][c] else { continue }
      let x0 = ox + edge(c)
      let x1 = ox + edge(c + 1)
      let yTop = oy + side - edge(r)
      let yBot = oy + side - edge(r + 1)
      ctx.setFillColor(cellColor)
      ctx.fill(CGRect(x: x0, y: yBot, width: x1 - x0, height: yTop - yBot))
    }
  }
}
