import AppKit

/// Left sidebar: worktrees, toolkit, and watchdogs (functional).
final class DFSidebar: NSView {

  private let worktreeStack = NSStackView()
  private let filesStack = NSStackView()
  private let toolkitStack = NSStackView()
  private let watchdogStack = NSStackView()
  private var outputPopover: NSPopover?

  /// Worktree paths currently being removed. The row is hidden from the
  /// sidebar while the background `git worktree remove` is running so the UI
  /// feels responsive even when the delete takes many seconds. Main-thread
  /// only.
  private var pendingRemovals: Set<String> = []

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = Theme.surface1.cgColor
    buildUI()

    NotificationCenter.default.addObserver(
      self, selector: #selector(refreshWorktrees),
      name: .sessionsDidChange, object: nil
    )
    NotificationCenter.default.addObserver(
      self, selector: #selector(refreshWatchdogs),
      name: .watchdogsDidChange, object: nil
    )
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  private func buildUI() {
    // Title
    // All-caps looks the same either way
    let title = label("DRAFTFRAME", size: 10, color: Theme.text3, weight: .medium)
    title.translatesAutoresizingMaskIntoConstraints = false
    addSubview(title)

    // Separator
    let sep = separator()
    addSubview(sep)

    // Project section — shows repo name with worktrees nested under it
    let projectHeader = label("PROJECT", size: 9, color: Theme.text3, weight: .medium)
    projectHeader.translatesAutoresizingMaskIntoConstraints = false
    addSubview(projectHeader)

    worktreeStack.orientation = .vertical
    worktreeStack.spacing = 2
    worktreeStack.alignment = .leading
    worktreeStack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(worktreeStack)

    // Add worktree button
    let addWorktreeBtn = makeClickableRow(
      icon: "plus.circle", text: "New Worktree", detail: nil,
      target: self, action: #selector(addWorktreeClicked))
    addSubview(addWorktreeBtn)

    // Open Project button
    let openProjectBtn = makeClickableRow(
      icon: "folder.badge.plus", text: "Open Project", detail: nil,
      target: self, action: #selector(openProjectClicked))
    addSubview(openProjectBtn)

    // Changes section — git diff changed files
    let changesSep = separator()
    addSubview(changesSep)
    let changesHeader = label("CHANGES", size: 9, color: Theme.text3, weight: .medium)
    changesHeader.translatesAutoresizingMaskIntoConstraints = false
    addSubview(changesHeader)

    filesStack.orientation = .vertical
    filesStack.spacing = 2
    filesStack.alignment = .leading
    filesStack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(filesStack)

    // Toolkit section
    let toolkitSep = separator()
    addSubview(toolkitSep)
    let toolkitHeader = label("TOOLKIT", size: 9, color: Theme.text3, weight: .medium)
    toolkitHeader.translatesAutoresizingMaskIntoConstraints = false
    addSubview(toolkitHeader)

    toolkitStack.orientation = .vertical
    toolkitStack.spacing = 2
    toolkitStack.alignment = .leading
    toolkitStack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(toolkitStack)

    // Watchdogs section
    let watchdogSep = separator()
    addSubview(watchdogSep)
    let watchdogHeader = label("WATCHDOGS", size: 9, color: Theme.text3, weight: .medium)
    watchdogHeader.translatesAutoresizingMaskIntoConstraints = false
    addSubview(watchdogHeader)

    watchdogStack.orientation = .vertical
    watchdogStack.spacing = 2
    watchdogStack.alignment = .leading
    watchdogStack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(watchdogStack)

    let addWatchdogBtn = makeClickableRow(
      icon: "plus.circle", text: "New Watchdog", detail: nil,
      target: self, action: #selector(addWatchdogClicked))
    addSubview(addWatchdogBtn)

    NSLayoutConstraint.activate([
      title.topAnchor.constraint(equalTo: topAnchor, constant: 38),
      title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),

      sep.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
      sep.leadingAnchor.constraint(equalTo: leadingAnchor),
      sep.trailingAnchor.constraint(equalTo: trailingAnchor),

      projectHeader.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 12),
      projectHeader.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),

      worktreeStack.topAnchor.constraint(equalTo: projectHeader.bottomAnchor, constant: 6),
      worktreeStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      worktreeStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

      addWorktreeBtn.topAnchor.constraint(equalTo: worktreeStack.bottomAnchor, constant: 4),
      addWorktreeBtn.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      addWorktreeBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      addWorktreeBtn.heightAnchor.constraint(equalToConstant: 28),

      openProjectBtn.topAnchor.constraint(equalTo: addWorktreeBtn.bottomAnchor, constant: 2),
      openProjectBtn.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      openProjectBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      openProjectBtn.heightAnchor.constraint(equalToConstant: 28),

      changesSep.topAnchor.constraint(equalTo: openProjectBtn.bottomAnchor, constant: 12),
      changesSep.leadingAnchor.constraint(equalTo: leadingAnchor),
      changesSep.trailingAnchor.constraint(equalTo: trailingAnchor),

      changesHeader.topAnchor.constraint(equalTo: changesSep.bottomAnchor, constant: 12),
      changesHeader.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),

      filesStack.topAnchor.constraint(equalTo: changesHeader.bottomAnchor, constant: 6),
      filesStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      filesStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

      toolkitSep.topAnchor.constraint(equalTo: filesStack.bottomAnchor, constant: 12),
      toolkitSep.leadingAnchor.constraint(equalTo: leadingAnchor),
      toolkitSep.trailingAnchor.constraint(equalTo: trailingAnchor),

      toolkitHeader.topAnchor.constraint(equalTo: toolkitSep.bottomAnchor, constant: 12),
      toolkitHeader.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),

      toolkitStack.topAnchor.constraint(equalTo: toolkitHeader.bottomAnchor, constant: 6),
      toolkitStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      toolkitStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

      watchdogSep.topAnchor.constraint(equalTo: toolkitStack.bottomAnchor, constant: 12),
      watchdogSep.leadingAnchor.constraint(equalTo: leadingAnchor),
      watchdogSep.trailingAnchor.constraint(equalTo: trailingAnchor),

      watchdogHeader.topAnchor.constraint(equalTo: watchdogSep.bottomAnchor, constant: 12),
      watchdogHeader.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),

      watchdogStack.topAnchor.constraint(equalTo: watchdogHeader.bottomAnchor, constant: 6),
      watchdogStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      watchdogStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

      addWatchdogBtn.topAnchor.constraint(equalTo: watchdogStack.bottomAnchor, constant: 4),
      addWatchdogBtn.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      addWatchdogBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      addWatchdogBtn.heightAnchor.constraint(equalToConstant: 28),
    ])

    refreshWorktrees()
    refreshFiles()
    refreshToolkit()
    refreshWatchdogs()

    // Refresh file list when project directory changes
    NotificationCenter.default.addObserver(
      self, selector: #selector(refreshFiles),
      name: .activeSessionDidChange, object: nil
    )

    // Auto-refresh toolkit when config file changes
    NotificationCenter.default.addObserver(
      self, selector: #selector(toolkitConfigDidChange),
      name: .toolkitDidChange, object: nil
    )
  }

  // MARK: - Worktrees

  @objc private func refreshWorktrees() {
    for v in worktreeStack.arrangedSubviews {
      worktreeStack.removeArrangedSubview(v)
      v.removeFromSuperview()
    }

    let projects = ProjectManager.shared.projects
    let activeDir = SessionManager.shared.projectDir

    for project in projects {
      let isActive = project.path == activeDir
      let chevron = project.isExpanded ? "chevron.down" : "chevron.right"

      // Project header row — clickable to expand/collapse
      let projectRow = makeClickableRow(
        icon: chevron, text: project.name,
        detail: isActive ? "active" : nil,
        target: self, action: #selector(projectRowClicked(_:)))
      projectRow.worktreePath = project.path
      projectRow.heightAnchor.constraint(equalToConstant: 28).isActive = true

      // Bold the active project name
      if isActive, let lbl = projectRow.subviews.compactMap({ $0 as? NSTextField }).first {
        lbl.font = Theme.mono(12, weight: .medium)
        lbl.textColor = Theme.text1
      }

      // Right-click context menu on project
      let menu = NSMenu()
      let switchItem = NSMenuItem(
        title: "Switch to Project", action: #selector(switchToProject(_:)), keyEquivalent: "")
      switchItem.target = self
      switchItem.representedObject = project.path
      menu.addItem(switchItem)

      let showItem = NSMenuItem(
        title: "Show in Finder", action: #selector(showWorktreeInFinder(_:)), keyEquivalent: "")
      showItem.target = self
      showItem.representedObject = project.path
      menu.addItem(showItem)

      menu.addItem(NSMenuItem.separator())
      let removeItem = NSMenuItem(
        title: "Remove from List", action: #selector(removeProjectFromList(_:)), keyEquivalent: "")
      removeItem.target = self
      removeItem.representedObject = project.path
      menu.addItem(removeItem)

      projectRow.menu = menu
      worktreeStack.addArrangedSubview(projectRow)

      // Show worktrees only if expanded
      guard project.isExpanded else { continue }

      // Get worktrees for this project; hide any currently being removed so
      // the row stays gone even if another notification refreshes the sidebar
      // mid-removal.
      let worktrees = getWorktrees(for: project.path)
        .filter { !pendingRemovals.contains($0.path) }
      if worktrees.isEmpty {
        let mainRow = makeRow(icon: "arrow.triangle.branch", text: "  main", detail: "base")
        mainRow.heightAnchor.constraint(equalToConstant: 26).isActive = true
        worktreeStack.addArrangedSubview(mainRow)
      } else {
        for wt in worktrees {
          let branchName = wt.branch.isEmpty ? "detached" : wt.branch
          let isBase = wt.isBare
          let row = makeClickableRow(
            icon: "arrow.triangle.branch", text: "  \(branchName)",
            detail: isBase ? "base" : nil,
            target: self, action: #selector(worktreeRowClicked(_:)))
          row.worktreeName = branchName
          row.worktreePath = wt.path
          row.isBaseWorktree = isBase

          // Context menu
          let wtMenu = NSMenu()
          let openItem = NSMenuItem(
            title: "Open Session Here", action: #selector(openSessionFromMenu(_:)),
            keyEquivalent: "")
          openItem.target = self
          openItem.representedObject = wt
          wtMenu.addItem(openItem)
          if !isBase {
            wtMenu.addItem(NSMenuItem.separator())
            let rmItem = NSMenuItem(
              title: "Remove Worktree", action: #selector(removeWorktreeFromMenu(_:)),
              keyEquivalent: "")
            rmItem.target = self
            // Carry the project's repo root alongside the worktree so the
            // remove action can invoke git against the right repo (not
            // DraftFrame's own repo via the singleton).
            rmItem.representedObject = WorktreeRemovalRequest(worktree: wt, repoRoot: project.path)
            wtMenu.addItem(rmItem)
          }
          wtMenu.addItem(NSMenuItem.separator())
          let copyItem = NSMenuItem(
            title: "Copy Path", action: #selector(copyWorktreePath(_:)), keyEquivalent: "")
          copyItem.target = self
          copyItem.representedObject = wt.path
          wtMenu.addItem(copyItem)
          row.menu = wtMenu

          row.heightAnchor.constraint(equalToConstant: 26).isActive = true
          worktreeStack.addArrangedSubview(row)
        }
      }
    }

    // If no projects at all, show placeholder
    if projects.isEmpty {
      let emptyRow = makeRow(icon: "folder.badge.plus", text: "Open Project", detail: nil)
      emptyRow.heightAnchor.constraint(equalToConstant: 28).isActive = true
      worktreeStack.addArrangedSubview(emptyRow)
    }
  }

  @objc private func worktreeRowClicked(_ sender: AnyObject) {
    guard let row = sender as? ClickableRow, let path = row.worktreePath else { return }
    let sessions = SessionManager.shared.sessions
    if let idx = sessions.firstIndex(where: { $0.worktreePath == path }) {
      // Session exists — switch to it
      SessionManager.shared.switchTo(index: idx)
    } else {
      // No session for this worktree — create one
      let name = row.worktreeName ?? (path as NSString).lastPathComponent
      SessionManager.shared.createSession(name: name, worktreePath: path)
    }
  }

  @objc private func openSessionFromMenu(_ sender: NSMenuItem) {
    guard let wt = sender.representedObject as? WorktreeManager.Worktree else { return }
    let name = wt.branch.isEmpty ? (wt.path as NSString).lastPathComponent : wt.branch
    // Check if a session already exists for this path
    let sessions = SessionManager.shared.sessions
    if let idx = sessions.firstIndex(where: { $0.worktreePath == wt.path }) {
      SessionManager.shared.switchTo(index: idx)
    } else {
      SessionManager.shared.createSession(name: name, worktreePath: wt.path)
    }
  }

  @objc private func removeWorktreeFromMenu(_ sender: NSMenuItem) {
    guard let req = sender.representedObject as? WorktreeRemovalRequest else { return }
    let wt = req.worktree
    let projectRoot = req.repoRoot

    let alert = NSAlert()
    alert.messageText = "Remove Worktree?"
    alert.informativeText =
      "This will remove the worktree at:\n\(wt.path)\n\nAny uncommitted changes will be lost."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Remove")
    alert.addButton(withTitle: "Cancel")

    guard let win = window else { return }
    alert.beginSheetModal(for: win) { response in
      guard response == .alertFirstButtonReturn else { return }

      // Close any session using this worktree
      let sessions = SessionManager.shared.sessions
      if let idx = sessions.firstIndex(where: { $0.worktreePath == wt.path }) {
        SessionManager.shared.closeSession(at: idx)
      }

      // Optimistically hide the row now so the UI feels instant — the actual
      // `git worktree remove` can take many seconds for large worktrees
      // (node_modules, etc.).
      self.pendingRemovals.insert(wt.path)
      self.refreshWorktrees()

      DispatchQueue.global(qos: .userInitiated).async {
        let result = Result {
          try WorktreeManager.shared.removeWorktree(repoRoot: projectRoot, path: wt.path)
        }
        DispatchQueue.main.async {
          self.pendingRemovals.remove(wt.path)
          if case .failure(let error) = result {
            let errAlert = NSAlert()
            errAlert.messageText = "Remove Failed"
            errAlert.informativeText = error.localizedDescription
            errAlert.runModal()
          }
          self.refreshWorktrees()
        }
      }
    }
  }

  @objc private func showWorktreeInFinder(_ sender: NSMenuItem) {
    guard let path = sender.representedObject as? String else { return }
    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
  }

  @objc private func copyWorktreePath(_ sender: NSMenuItem) {
    guard let path = sender.representedObject as? String else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(path, forType: .string)
  }

  /// Get worktrees for a specific project directory.
  private func getWorktrees(for projectPath: String) -> [WorktreeManager.Worktree] {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    proc.arguments = ["-C", projectPath, "worktree", "list", "--porcelain"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    do {
      try proc.run()
      proc.waitUntilExit()
    } catch { return [] }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else { return [] }

    var worktrees: [WorktreeManager.Worktree] = []
    var path = ""
    var branch = ""
    var head = ""
    var isBare = false

    for line in output.components(separatedBy: "\n") {
      if line.hasPrefix("worktree ") {
        if !path.isEmpty {
          worktrees.append(
            WorktreeManager.Worktree(path: path, branch: branch, head: head, isBare: isBare))
        }
        path = String(line.dropFirst("worktree ".count))
        branch = ""
        head = ""
        isBare = false
      } else if line.hasPrefix("HEAD ") {
        head = String(line.dropFirst("HEAD ".count))
      } else if line.hasPrefix("branch ") {
        let full = String(line.dropFirst("branch ".count))
        branch = full.hasPrefix("refs/heads/") ? String(full.dropFirst("refs/heads/".count)) : full
      } else if line == "bare" {
        isBare = true
      }
    }
    if !path.isEmpty {
      worktrees.append(
        WorktreeManager.Worktree(path: path, branch: branch, head: head, isBare: isBare))
    }
    return worktrees
  }

  @objc private func projectRowClicked(_ sender: AnyObject) {
    guard let row = sender as? ClickableRow, let path = row.worktreePath else { return }
    ProjectManager.shared.toggleExpanded(path: path)
    refreshWorktrees()
  }

  @objc private func switchToProject(_ sender: NSMenuItem) {
    guard let path = sender.representedObject as? String else { return }
    if let wc = window?.windowController as? DFWindowController {
      wc.openProject(at: path)
    }
  }

  @objc private func removeProjectFromList(_ sender: NSMenuItem) {
    guard let path = sender.representedObject as? String else { return }
    ProjectManager.shared.removeProject(path: path)
    refreshWorktrees()
  }

  @objc private func openProjectClicked() {
    // Find the window controller and trigger the open project dialog
    if let wc = window?.windowController as? DFWindowController {
      wc.promptOpenProject()
    }
  }

  @objc private func addWorktreeClicked() {
    let alert = NSAlert()
    alert.messageText = "New Worktree"
    alert.informativeText = "Enter a name for the new worktree branch:"
    alert.addButton(withTitle: "Create")
    alert.addButton(withTitle: "Cancel")

    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
    input.placeholderString = "feature-name"
    alert.accessoryView = input

    guard let win = window else { return }
    alert.beginSheetModal(for: win) { response in
      guard response == .alertFirstButtonReturn else { return }
      let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else { return }

      do {
        let path = try WorktreeManager.shared.createWorktree(name: name)
        // Create a session in the worktree
        SessionManager.shared.createSession(name: name, worktreePath: path)
        self.refreshWorktrees()
      } catch {
        let errAlert = NSAlert()
        errAlert.messageText = "Worktree Error"
        errAlert.informativeText = error.localizedDescription
        errAlert.runModal()
      }
    }
  }

  // MARK: - Files

  @objc private func refreshFiles() {
    for v in filesStack.arrangedSubviews {
      filesStack.removeArrangedSubview(v)
      v.removeFromSuperview()
    }

    guard let projectDir = SessionManager.shared.projectDir else { return }

    // Run git status to get changed files
    let changedFiles = gitChangedFiles(in: projectDir)

    if changedFiles.isEmpty {
      let emptyLabel = label("No changes", size: 11, color: Theme.text3)
      emptyLabel.translatesAutoresizingMaskIntoConstraints = false
      filesStack.addArrangedSubview(emptyLabel)
      return
    }

    for file in changedFiles.prefix(50) {
      let statusIcon: String
      let statusColor: NSColor
      switch file.status {
      case "M":
        statusIcon = "pencil.circle"
        statusColor = Theme.yellow
      case "A":
        statusIcon = "plus.circle"
        statusColor = Theme.green
      case "D":
        statusIcon = "minus.circle"
        statusColor = Theme.red
      case "?":
        statusIcon = "questionmark.circle"
        statusColor = Theme.text3
      case "R":
        statusIcon = "arrow.right.circle"
        statusColor = Theme.cyan
      default:
        statusIcon = "circle"
        statusColor = Theme.text3
      }

      let fullPath = (projectDir as NSString).appendingPathComponent(file.path)
      let row = makeClickableRow(
        icon: statusIcon, text: file.path, detail: nil,
        target: self, action: #selector(fileRowClicked(_:)))
      row.filePath = fullPath
      row.isDirectory = false
      row.heightAnchor.constraint(equalToConstant: 24).isActive = true

      // Tint the icon with the status color
      if let iconView = row.subviews.compactMap({ $0 as? NSImageView }).first {
        iconView.contentTintColor = statusColor
      }

      filesStack.addArrangedSubview(row)
    }
  }

  private struct ChangedFile {
    let status: String  // M, A, D, ?, R, etc.
    let path: String
  }

  private func gitChangedFiles(in dir: String) -> [ChangedFile] {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    proc.arguments = ["-C", dir, "status", "--porcelain"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    do {
      try proc.run()
      proc.waitUntilExit()
    } catch {
      return []
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else { return [] }

    var files: [ChangedFile] = []
    for line in output.components(separatedBy: "\n") where !line.isEmpty {
      // git status --porcelain format: "XY filename"
      guard line.count >= 4 else { continue }
      let index = line.index(line.startIndex, offsetBy: 0)
      let statusChar = line[index]
      let workTree = line[line.index(after: index)]

      // Use the more significant status
      let status: String
      if statusChar == "?" {
        status = "?"
      } else if statusChar != " " {
        status = String(statusChar)
      } else {
        status = String(workTree)
      }

      let pathStart = line.index(line.startIndex, offsetBy: 3)
      let path = String(line[pathStart...])
      files.append(ChangedFile(status: status, path: path))
    }

    return files
  }

  @objc private func fileRowClicked(_ sender: AnyObject) {
    guard let row = sender as? ClickableRow, let path = row.filePath else { return }

    if row.isDirectory {
      // Could expand directory in future; for now, no-op
      return
    }

    // Open file in editor (auto-show editor)
    NotificationCenter.default.post(
      name: .openFileInEditor,
      object: nil,
      userInfo: ["path": path]
    )
    // Also tell window controller to show editor
    NotificationCenter.default.post(
      name: .toggleEditorPane, object: nil,
      userInfo: ["show": true])
  }

  // MARK: - Toolkit

  private func refreshToolkit() {
    for v in toolkitStack.arrangedSubviews {
      toolkitStack.removeArrangedSubview(v)
      v.removeFromSuperview()
    }

    let commands = ToolkitManager.shared.commands
    for (i, cmd) in commands.enumerated() {
      let row = makeClickableRow(
        icon: cmd.icon, text: cmd.name, detail: nil,
        target: self, action: #selector(toolkitCommandClicked(_:)))
      row.toolkitIndex = i
      row.heightAnchor.constraint(equalToConstant: 28).isActive = true
      toolkitStack.addArrangedSubview(row)
    }

    // Edit Toolkit button
    let editRow = makeClickableRow(
      icon: "pencil.circle", text: "Edit Toolkit", detail: nil,
      target: self, action: #selector(editToolkitClicked))
    editRow.heightAnchor.constraint(equalToConstant: 28).isActive = true
    toolkitStack.addArrangedSubview(editRow)

    // Reload Toolkit button
    let reloadRow = makeClickableRow(
      icon: "arrow.clockwise", text: "Reload", detail: nil,
      target: self, action: #selector(reloadToolkitClicked))
    reloadRow.heightAnchor.constraint(equalToConstant: 28).isActive = true
    toolkitStack.addArrangedSubview(reloadRow)
  }

  @objc private func toolkitConfigDidChange() {
    refreshToolkit()
  }

  @objc private func editToolkitClicked() {
    ToolkitManager.shared.openConfigInEditor()
  }

  @objc private func reloadToolkitClicked() {
    ToolkitManager.shared.loadConfig()
    refreshToolkit()
  }

  @objc private func toolkitCommandClicked(_ sender: AnyObject) {
    let commands = ToolkitManager.shared.commands
    let idx = (sender as? ClickableRow)?.toolkitIndex ?? 0
    guard idx >= 0, idx < commands.count else { return }
    let cmd = commands[idx]

    // Run in active session's worktree directory
    let dir = SessionManager.shared.activeSession?.worktreePath

    // Close any existing popover
    outputPopover?.close()

    // Build the popover content
    let popover = NSPopover()
    popover.behavior = .transient
    let vc = NSViewController()
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    container.wantsLayer = true
    container.layer?.backgroundColor = Theme.surface2.cgColor

    // Status line at top
    let statusLabel = NSTextField(labelWithString: "Running...")
    statusLabel.font = Theme.mono(11, weight: .medium)
    statusLabel.textColor = Theme.yellow
    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(statusLabel)

    let cmdLabel = NSTextField(labelWithString: cmd.command)
    cmdLabel.font = Theme.mono(10)
    cmdLabel.textColor = Theme.text3
    cmdLabel.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(cmdLabel)

    // Separator
    let sep = NSView()
    sep.wantsLayer = true
    sep.layer?.backgroundColor = Theme.surface3.cgColor
    sep.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(sep)

    // Scrollable text view for output
    let scrollView = NSScrollView()
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.autohidesScrollers = true
    container.addSubview(scrollView)

    let textView = NSTextView()
    textView.isEditable = false
    textView.isSelectable = true
    textView.drawsBackground = true
    textView.backgroundColor = Theme.surface2
    textView.textColor = Theme.text1
    textView.font = Theme.mono(11)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(
      width: 0, height: CGFloat.greatestFiniteMagnitude)
    textView.autoresizingMask = [.width]
    scrollView.documentView = textView

    NSLayoutConstraint.activate([
      statusLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
      statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),

      cmdLabel.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
      cmdLabel.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 8),
      cmdLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: container.trailingAnchor, constant: -12),

      sep.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
      sep.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      sep.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      sep.heightAnchor.constraint(equalToConstant: 1),

      scrollView.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 4),
      scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
      scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
      scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
    ])

    vc.view = container
    popover.contentViewController = vc
    popover.contentSize = NSSize(width: 400, height: 300)
    let senderView = sender as? NSView ?? self
    popover.show(relativeTo: senderView.bounds, of: senderView, preferredEdge: .maxX)
    self.outputPopover = popover

    ToolkitManager.shared.runCommand(cmd, inDirectory: dir) { output, exitCode in
      // Update status line
      if exitCode == 0 {
        statusLabel.stringValue = "Done (exit 0)"
        statusLabel.textColor = Theme.green
      } else {
        statusLabel.stringValue = "Failed (exit \(exitCode))"
        statusLabel.textColor = Theme.red
      }

      // Set output text
      textView.string = output

      // Auto-scroll to bottom
      textView.scrollRangeToVisible(NSRange(location: textView.string.count, length: 0))
    }
  }

  // MARK: - Watchdogs

  @objc private func refreshWatchdogs() {
    for v in watchdogStack.arrangedSubviews {
      watchdogStack.removeArrangedSubview(v)
      v.removeFromSuperview()
    }

    let watchdogs = WatchdogManager.shared.watchdogs
    for (i, wd) in watchdogs.enumerated() {
      let statusIcon = wd.isEnabled ? "eye.fill" : "eye.slash"
      let detail = wd.isEnabled ? "on" : "off"
      let row = makeClickableRow(
        icon: statusIcon, text: wd.name, detail: detail,
        target: self, action: #selector(watchdogRowClicked(_:)))
      row.watchdogIndex = i

      // Right-click context menu
      let menu = NSMenu()

      let toggleItem = NSMenuItem(
        title: wd.isEnabled ? "Disable" : "Enable",
        action: #selector(toggleWatchdogFromMenu(_:)),
        keyEquivalent: ""
      )
      toggleItem.target = self
      toggleItem.representedObject = wd.id
      menu.addItem(toggleItem)

      let editItem = NSMenuItem(
        title: "Edit", action: #selector(editWatchdogFromMenu(_:)), keyEquivalent: "")
      editItem.target = self
      editItem.representedObject = wd.id
      menu.addItem(editItem)

      menu.addItem(NSMenuItem.separator())

      let removeItem = NSMenuItem(
        title: "Remove", action: #selector(removeWatchdogFromMenu(_:)), keyEquivalent: "")
      removeItem.target = self
      removeItem.representedObject = wd.id
      menu.addItem(removeItem)

      row.menu = menu

      row.heightAnchor.constraint(equalToConstant: 28).isActive = true
      watchdogStack.addArrangedSubview(row)
    }
  }

  @objc private func watchdogRowClicked(_ sender: AnyObject) {
    guard let row = sender as? ClickableRow else { return }
    let watchdogs = WatchdogManager.shared.watchdogs
    let idx = row.watchdogIndex
    guard idx >= 0, idx < watchdogs.count else { return }
    WatchdogManager.shared.toggleWatchdog(id: watchdogs[idx].id)
  }

  @objc private func toggleWatchdogFromMenu(_ sender: NSMenuItem) {
    guard let wdID = sender.representedObject as? UUID else { return }
    WatchdogManager.shared.toggleWatchdog(id: wdID)
  }

  @objc private func editWatchdogFromMenu(_ sender: NSMenuItem) {
    guard let wdID = sender.representedObject as? UUID else { return }
    guard let wd = WatchdogManager.shared.watchdogs.first(where: { $0.id == wdID }) else { return }
    showWatchdogEditor(existing: wd)
  }

  @objc private func removeWatchdogFromMenu(_ sender: NSMenuItem) {
    guard let wdID = sender.representedObject as? UUID else { return }
    WatchdogManager.shared.removeWatchdog(id: wdID)
  }

  @objc private func addWatchdogClicked() {
    showWatchdogEditor(existing: nil)
  }

  /// Show a creation/edit dialog for a watchdog.
  private func showWatchdogEditor(existing: Watchdog?) {
    let alert = NSAlert()
    alert.messageText = existing != nil ? "Edit Watchdog" : "New Watchdog"
    alert.addButton(withTitle: existing != nil ? "Save" : "Create")
    alert.addButton(withTitle: "Cancel")

    // Build accessory view
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 150))

    // Name field
    let nameLabel = NSTextField(labelWithString: "Name:")
    nameLabel.font = Theme.mono(11, weight: .medium)
    nameLabel.textColor = Theme.text2
    nameLabel.frame = NSRect(x: 0, y: 122, width: 60, height: 20)
    container.addSubview(nameLabel)

    let nameField = NSTextField(frame: NSRect(x: 65, y: 120, width: 230, height: 24))
    nameField.font = Theme.mono(12)
    nameField.placeholderString = "My Watchdog"
    if let wd = existing { nameField.stringValue = wd.name }
    container.addSubview(nameField)

    // Trigger picker
    let triggerLabel = NSTextField(labelWithString: "Trigger:")
    triggerLabel.font = Theme.mono(11, weight: .medium)
    triggerLabel.textColor = Theme.text2
    triggerLabel.frame = NSRect(x: 0, y: 88, width: 60, height: 20)
    container.addSubview(triggerLabel)

    let triggerPopup = NSPopUpButton(frame: NSRect(x: 65, y: 85, width: 230, height: 26))
    triggerPopup.addItems(withTitles: ["Needs Attention", "Idle After Work", "Periodic"])
    if let wd = existing {
      switch wd.trigger {
      case .needsAttention: triggerPopup.selectItem(at: 0)
      case .idleAfterWork: triggerPopup.selectItem(at: 1)
      case .periodic: triggerPopup.selectItem(at: 2)
      }
    }
    container.addSubview(triggerPopup)

    // Response picker
    let responseLabel = NSTextField(labelWithString: "Response:")
    responseLabel.font = Theme.mono(11, weight: .medium)
    responseLabel.textColor = Theme.text2
    responseLabel.frame = NSRect(x: 0, y: 54, width: 62, height: 20)
    container.addSubview(responseLabel)

    let responsePopup = NSPopUpButton(frame: NSRect(x: 65, y: 51, width: 230, height: 26))
    responsePopup.addItems(withTitles: ["Notify Only", "Auto-Accept", "Send Text", "Run Command"])
    if let wd = existing {
      switch wd.response {
      case .notify: responsePopup.selectItem(at: 0)
      case .autoAccept: responsePopup.selectItem(at: 1)
      case .sendText: responsePopup.selectItem(at: 2)
      case .runCommand: responsePopup.selectItem(at: 3)
      }
    }
    container.addSubview(responsePopup)

    // Text/command field (for Send Text / Run Command)
    let textLabel = NSTextField(labelWithString: "Text/Cmd:")
    textLabel.font = Theme.mono(11, weight: .medium)
    textLabel.textColor = Theme.text2
    textLabel.frame = NSRect(x: 0, y: 22, width: 62, height: 20)
    container.addSubview(textLabel)

    let textField = NSTextField(frame: NSRect(x: 65, y: 20, width: 230, height: 24))
    textField.font = Theme.mono(12)
    textField.placeholderString = "text to send or command to run"
    if let wd = existing {
      switch wd.response {
      case .sendText(let t): textField.stringValue = t
      case .runCommand(let c): textField.stringValue = c
      default: break
      }
    }
    container.addSubview(textField)

    alert.accessoryView = container

    guard let win = window else { return }
    alert.beginSheetModal(for: win) { response in
      guard response == .alertFirstButtonReturn else { return }
      let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else { return }

      // Build trigger
      let trigger: WatchdogTrigger
      switch triggerPopup.indexOfSelectedItem {
      case 1: trigger = .idleAfterWork
      case 2: trigger = .periodic(seconds: 60)
      default: trigger = .needsAttention
      }

      // Build response
      let wdResponse: WatchdogResponse
      let txt = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      switch responsePopup.indexOfSelectedItem {
      case 1: wdResponse = .autoAccept
      case 2: wdResponse = .sendText(txt.isEmpty ? "y" : txt)
      case 3: wdResponse = .runCommand(txt.isEmpty ? "echo hello" : txt)
      default: wdResponse = .notify
      }

      if var wd = existing {
        wd.name = name
        wd.trigger = trigger
        wd.response = wdResponse
        WatchdogManager.shared.updateWatchdog(wd)
      } else {
        let wd = Watchdog(
          id: UUID(),
          name: name,
          isEnabled: true,
          sessionID: nil,
          trigger: trigger,
          response: wdResponse
        )
        WatchdogManager.shared.addWatchdog(wd)
      }
    }
  }

  // MARK: - Helpers

  private func label(
    _ text: String, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular
  ) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = Theme.mono(size, weight: weight)
    l.textColor = color
    return l
  }

  private func separator() -> NSView {
    let v = NSView()
    v.wantsLayer = true
    v.layer?.backgroundColor = Theme.surface3.cgColor
    v.translatesAutoresizingMaskIntoConstraints = false
    v.heightAnchor.constraint(equalToConstant: 1).isActive = true
    return v
  }

  private func makeRow(icon: String, text: String, detail: String?) -> NSView {
    let row = NSView()
    row.translatesAutoresizingMaskIntoConstraints = false

    let img = NSImageView()
    if let sysImg = NSImage(systemSymbolName: icon, accessibilityDescription: nil) {
      img.image = sysImg
      img.contentTintColor = Theme.text2
    }
    img.translatesAutoresizingMaskIntoConstraints = false

    let lbl = label(text, size: 12, color: Theme.text1)
    lbl.translatesAutoresizingMaskIntoConstraints = false

    row.addSubview(img)
    row.addSubview(lbl)

    NSLayoutConstraint.activate([
      img.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 4),
      img.centerYAnchor.constraint(equalTo: row.centerYAnchor),
      img.widthAnchor.constraint(equalToConstant: 14),
      img.heightAnchor.constraint(equalToConstant: 14),
      lbl.leadingAnchor.constraint(equalTo: img.trailingAnchor, constant: 6),
      lbl.centerYAnchor.constraint(equalTo: row.centerYAnchor),
    ])

    if let detail = detail {
      let d = label(detail, size: 10, color: Theme.text3)
      d.translatesAutoresizingMaskIntoConstraints = false
      row.addSubview(d)
      d.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -4).isActive = true
      d.centerYAnchor.constraint(equalTo: row.centerYAnchor).isActive = true
    }

    return row
  }

  private func makeClickableRow(
    icon: String, text: String, detail: String?,
    target: AnyObject?, action: Selector
  ) -> ClickableRow {
    let row = ClickableRow(target: target, action: action)
    row.translatesAutoresizingMaskIntoConstraints = false

    let img = NSImageView()
    if let sysImg = NSImage(systemSymbolName: icon, accessibilityDescription: nil) {
      img.image = sysImg
      img.contentTintColor = Theme.text2
    }
    img.translatesAutoresizingMaskIntoConstraints = false

    let lbl = label(text, size: 12, color: Theme.text1)
    lbl.translatesAutoresizingMaskIntoConstraints = false

    row.addSubview(img)
    row.addSubview(lbl)

    NSLayoutConstraint.activate([
      img.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 4),
      img.centerYAnchor.constraint(equalTo: row.centerYAnchor),
      img.widthAnchor.constraint(equalToConstant: 14),
      img.heightAnchor.constraint(equalToConstant: 14),
      lbl.leadingAnchor.constraint(equalTo: img.trailingAnchor, constant: 6),
      lbl.centerYAnchor.constraint(equalTo: row.centerYAnchor),
    ])

    if let detail = detail {
      let d = label(detail, size: 10, color: Theme.text3)
      d.translatesAutoresizingMaskIntoConstraints = false
      row.addSubview(d)
      d.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -4).isActive = true
      d.centerYAnchor.constraint(equalTo: row.centerYAnchor).isActive = true
    }

    return row
  }
}

/// A view that acts like a button — sends action on click.
final class ClickableRow: NSView {
  weak var target: AnyObject?
  var action: Selector?
  var toolkitIndex: Int = 0
  var watchdogIndex: Int = 0
  var worktreeName: String?
  var worktreePath: String?
  var isBaseWorktree: Bool = false
  var filePath: String?
  var isDirectory: Bool = false

  init(target: AnyObject?, action: Selector?) {
    self.target = target
    self.action = action
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 4
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func mouseDown(with event: NSEvent) {
    layer?.backgroundColor = Theme.surface3.cgColor
  }

  override func mouseUp(with event: NSEvent) {
    layer?.backgroundColor = NSColor.clear.cgColor
    if let action = action {
      NSApp.sendAction(action, to: target, from: self)
    }
  }

  override func mouseEntered(with event: NSEvent) {
    layer?.backgroundColor = Theme.surface2.cgColor
  }

  override func mouseExited(with event: NSEvent) {
    layer?.backgroundColor = NSColor.clear.cgColor
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas { removeTrackingArea(area) }
    addTrackingArea(
      NSTrackingArea(
        rect: bounds,
        options: [.mouseEnteredAndExited, .activeInKeyWindow],
        owner: self
      ))
  }
}

/// Payload stored on a "Remove Worktree" menu item so the action handler knows
/// both the worktree to remove and which project's repo it belongs to.
private struct WorktreeRemovalRequest {
  let worktree: WorktreeManager.Worktree
  let repoRoot: String
}
