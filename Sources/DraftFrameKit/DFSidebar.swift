import AppKit

/// Left sidebar: worktrees, toolkit, and watchdogs (functional).
final class DFSidebar: NSView {

  private let worktreeStack = NSStackView()
  private let filesStack = NSStackView()

  /// Ordered snapshot of the CHANGES rows, mirroring `filesStack`. Passed to
  /// the diff overlay so Up/Down can step through the same list.
  private var changedFileRefs: [DFDiffOverlay.DiffFileRef] = []
  private let toolkitStack = NSStackView()
  private let watchdogStack = NSStackView()
  private var outputPopover: NSPopover?

  /// Worktree paths currently being removed. The row is hidden from the
  /// sidebar while the background `git worktree remove` is running so the UI
  /// feels responsive even when the delete takes many seconds. Main-thread
  /// only.
  private var pendingRemovals: Set<String> = []

  /// Project paths whose default branch is currently being pulled. The
  /// project row shows a spinner and its "Pull <branch>" menu item is
  /// disabled while the background `git pull` runs. Main-thread only.
  private var pullsInFlight: Set<String> = []

  /// Project paths with a worktree setup (base-branch pull + worktree create)
  /// currently running in the background. The project header shows a spinner
  /// while its path is in here. Main-thread only.
  private var worktreeSetupsInFlight: Set<String> = []

  /// Project paths with a merged-worktree sweep running, mapped to the
  /// status shown in the row ("Scanning…", "Removing 3 of 12…"). The row's
  /// broom is replaced by a spinner plus that text while its path is in
  /// here. Part of the section snapshot so the row rebuilds as it changes.
  /// Main-thread only.
  private var sweepsInFlight: [String: String] = [:]
  /// True only while a sweep is actually removing worktrees. Worktree-list
  /// refreshes are deferred (see `refreshWorktrees`) so each closed session
  /// and removed directory doesn't re-render the sidebar mid-sweep.
  private var sweepRemovalPhase = false
  /// Set when a refresh arrived during the removal phase; replayed after.
  private var sweepDeferredRefresh = false

  /// Composed SF Symbol: leaf with a small "+" badge in the bottom-right.
  private static let leafPlusBadge: NSImage = {
    let size = NSSize(width: 16, height: 16)
    let img = NSImage(size: size, flipped: false) { rect in
      // Draw the leaf
      if let leaf = NSImage(systemSymbolName: "leaf", accessibilityDescription: nil) {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        let configured = leaf.withSymbolConfiguration(config) ?? leaf
        configured.draw(in: NSRect(x: 0, y: 2, width: 13, height: 13))
      }
      // Draw the + badge
      if let plus = NSImage(systemSymbolName: "plus", accessibilityDescription: nil) {
        let config = NSImage.SymbolConfiguration(pointSize: 7, weight: .bold)
        let configured = plus.withSymbolConfiguration(config) ?? plus
        configured.draw(in: NSRect(x: 9, y: 0, width: 7, height: 7))
      }
      return true
    }
    img.isTemplate = true
    return img
  }()

  /// Serial queue for `git worktree list` spawns. Enumeration used to run on
  /// the main thread, where `Process.waitUntilExit()` both hitched the UI on
  /// a cold/busy repo and pumped the run loop (which needed a reentrancy
  /// guard to stop queued notifications from splicing rows mid-rebuild).
  private let worktreeEnumQueue = DispatchQueue(
    label: "com.draftframe.sidebar.worktree-enum", qos: .userInitiated)

  /// True while an enumeration pass is on `worktreeEnumQueue`. Further
  /// `refreshWorktrees()` calls set `worktreeRefreshQueued` so at most one
  /// pass runs at a time and bursts of refresh requests collapse
  /// into a single trailing re-check (same pattern as `filesRefreshInFlight`).
  private var worktreeRefreshInFlight = false
  private var worktreeRefreshQueued = false

  /// Slow poll catching worktree changes made outside the app.
  /// `nonisolated(unsafe)` so the (never-raced) invalidate in deinit
  /// compiles; every other access is on the main actor.
  private nonisolated(unsafe) var externalWorktreeTimer: Timer?

  /// Everything that affects ONE project's rendered section (header row +
  /// worktree rows). Sections are compared individually so a change confined
  /// to one project (a spinner appearing, a worktree created) rebuilds only
  /// that project's rows — a full-stack rebuild visibly flashes the whole
  /// list. Excludes `isExpanded` so collapse/expand can animate without
  /// rebuilding rows.
  private struct ProjectSectionKey: Equatable {
    let path: String
    let name: String
    /// Whether the active session lives in this project (header highlight).
    let isActive: Bool
    /// Resolved path of the worktree the active session runs in, when it
    /// belongs to this project; drives the worktree-row highlight. Nil for
    /// inactive projects, so switching sessions re-renders only the
    /// previously and newly active sections.
    let activeWorktreePath: String?
    let isPulling: Bool
    let isSettingUp: Bool
    let sweepStatus: String?
    let worktrees: [WorktreeKey]
  }
  private struct WorktreeKey: Equatable {
    let path: String
    let branch: String
    let isBare: Bool
  }
  /// Section keys as last rendered, in stack order.
  private var lastSectionKeys: [ProjectSectionKey] = []

  /// Comparable snapshot of the rendered CHANGES rows. `refreshFiles()` is
  /// driven by FSEvents and session state changes, which repeat while an
  /// agent works; we use this to rebuild the rows only when the actual
  /// changed-file set differs, instead of tearing the stack down every time.
  private struct FilesContentSnapshot: Equatable {
    let worktreeDir: String?
    let files: [ChangedFile]
  }
  private var lastFilesSnapshot: FilesContentSnapshot?

  /// Runs `git status` off the main thread; a cold or busy repo can take >1s
  /// to answer, which beachballs the app if spawned from the main queue.
  private let gitStatusQueue = DispatchQueue(
    label: "com.draftframe.sidebar.git-status", qos: .userInitiated)

  /// True while a `git status` is in flight. Further `refreshFiles()` calls
  /// set `filesRefreshQueued` so at most one spawn runs at a time and bursts
  /// of watcher/notification pings collapse into a single trailing re-check.
  private var filesRefreshInFlight = false
  private var filesRefreshQueued = false

  /// Recursively watches the active session's scoped directory so the CHANGES
  /// list updates live on any file edit, including ones made outside the app.
  /// Recreated whenever the scoped directory changes; `watchedFilesDir` tracks
  /// the path it's currently rooted at so we don't tear it down needlessly.
  private var filesWatcher: DirectoryWatcher?
  private var watchedFilesDir: String?

  /// Per-project view references so collapse/expand can animate `isHidden`
  /// on existing rows instead of tearing the stack down and rebuilding, and
  /// so `rebuildSection` can splice one project's views in place.
  private var projectChevronViews: [String: NSImageView] = [:]
  private var projectHeaderRows: [String: NSView] = [:]
  private var projectWorktreeRows: [String: [NSView]] = [:]
  private var lastExpansionStates: [String: Bool] = [:]

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = Theme.surface1.cgColor
    buildUI()

    NotificationCenter.default.addObserver(
      self, selector: #selector(refreshWorktrees),
      name: .sessionListDidChange, object: nil
    )
    // Session switches refresh the project list via activeSessionChanged(),
    // which also re-roots the CHANGES watcher.
    // Worktrees created or removed outside the app (a plain `git worktree
    // add` in a terminal) have no in-app event; the old catch-all
    // notification used to pick those up incidentally. A slow poll covers
    // them: the enumeration runs off-main and the snapshot guard makes a
    // no-change pass free.
    externalWorktreeTimer = Timer.scheduledTimer(
      withTimeInterval: 10.0, repeats: true
    ) { [weak self] _ in
      // Scheduled on the main run loop, matching the view's isolation.
      MainActor.assumeIsolated {
        self?.refreshWorktrees()
      }
    }
    NotificationCenter.default.addObserver(
      self, selector: #selector(refreshWatchdogs),
      name: .watchdogsDidChange, object: nil
    )
    // Refresh PR action rows in the watchdogs list when the active session
    // changes (so rows reflect the new session's project config) or when
    // the user toggles a config via the dashboard card.
    NotificationCenter.default.addObserver(
      self, selector: #selector(refreshWatchdogs),
      name: .activeSessionDidChange, object: nil
    )
    NotificationCenter.default.addObserver(
      self, selector: #selector(refreshWatchdogs),
      name: .prStatusDidChange, object: nil
    )
    NotificationCenter.default.addObserver(
      self, selector: #selector(toolkitRunStateChanged),
      name: .toolkitRunStateDidChange, object: nil
    )
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  deinit {
    externalWorktreeTimer?.invalidate()
    NotificationCenter.default.removeObserver(self)
  }

  private func buildUI() {
    // Title — fixed at top, outside the scroll view
    let title = label("DRAFTFRAME", size: 10, color: Theme.text3, weight: .medium)
    title.translatesAutoresizingMaskIntoConstraints = false
    addSubview(title)

    let sep = separator()
    addSubview(sep)

    // Scrollable content area for everything below the title
    let scrollView = NSScrollView()
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.scrollerStyle = .overlay
    addSubview(scrollView)

    let contentView = FlippedView()
    contentView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.documentView = contentView

    // Project section
    let projectHeader = label("PROJECT", size: 9, color: Theme.text3, weight: .medium)
    projectHeader.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(projectHeader)

    let openProjectBtn = NSButton(
      title: "", target: self, action: #selector(openProjectClicked))
    openProjectBtn.image = NSImage(
      systemSymbolName: "folder.badge.plus", accessibilityDescription: "Open Project")
    openProjectBtn.isBordered = false
    openProjectBtn.imageScaling = .scaleProportionallyDown
    openProjectBtn.contentTintColor = Theme.text3
    openProjectBtn.toolTip = "Open Project"
    openProjectBtn.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(openProjectBtn)

    let sortBtn = NSButton(title: "", target: self, action: #selector(sortButtonClicked(_:)))
    sortBtn.image = NSImage(
      systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: "Sort Projects")
    sortBtn.isBordered = false
    sortBtn.imageScaling = .scaleProportionallyDown
    sortBtn.contentTintColor = Theme.text3
    sortBtn.toolTip = "Sort Projects"
    sortBtn.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(sortBtn)

    worktreeStack.orientation = .vertical
    worktreeStack.spacing = 2
    worktreeStack.alignment = .leading
    worktreeStack.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(worktreeStack)

    // Changes section
    let changesSep = separator()
    contentView.addSubview(changesSep)
    let changesHeader = label("CHANGES", size: 9, color: Theme.text3, weight: .medium)
    changesHeader.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(changesHeader)

    filesStack.orientation = .vertical
    filesStack.spacing = 2
    filesStack.alignment = .leading
    filesStack.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(filesStack)

    // Toolkit section
    let toolkitSep = separator()
    contentView.addSubview(toolkitSep)
    let toolkitHeader = label("TOOLKIT", size: 9, color: Theme.text3, weight: .medium)
    toolkitHeader.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(toolkitHeader)

    toolkitStack.orientation = .vertical
    toolkitStack.spacing = 2
    toolkitStack.alignment = .leading
    toolkitStack.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(toolkitStack)

    // Watchdogs section
    let watchdogSep = separator()
    contentView.addSubview(watchdogSep)
    let watchdogHeader = label("WATCHDOGS", size: 9, color: Theme.text3, weight: .medium)
    watchdogHeader.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(watchdogHeader)

    watchdogStack.orientation = .vertical
    watchdogStack.spacing = 2
    watchdogStack.alignment = .leading
    watchdogStack.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(watchdogStack)

    let addWatchdogBtn = makeClickableRow(
      icon: "plus.circle", text: "New Watchdog", detail: nil,
      target: self, action: #selector(addWatchdogClicked))
    contentView.addSubview(addWatchdogBtn)

    // Layout — title and separator are fixed; scroll view fills the rest
    NSLayoutConstraint.activate([
      title.topAnchor.constraint(equalTo: topAnchor, constant: 38),
      title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),

      sep.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
      sep.leadingAnchor.constraint(equalTo: leadingAnchor),
      sep.trailingAnchor.constraint(equalTo: trailingAnchor),

      scrollView.topAnchor.constraint(equalTo: sep.bottomAnchor),
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

      // Content view width tracks the scroll view (no horizontal scrolling)
      contentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
      contentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
      contentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),

      // Project section
      projectHeader.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
      projectHeader.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),

      openProjectBtn.centerYAnchor.constraint(equalTo: projectHeader.centerYAnchor),
      openProjectBtn.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
      openProjectBtn.widthAnchor.constraint(equalToConstant: 16),
      openProjectBtn.heightAnchor.constraint(equalToConstant: 16),

      sortBtn.centerYAnchor.constraint(equalTo: projectHeader.centerYAnchor),
      sortBtn.trailingAnchor.constraint(equalTo: openProjectBtn.leadingAnchor, constant: -8),
      sortBtn.widthAnchor.constraint(equalToConstant: 16),
      sortBtn.heightAnchor.constraint(equalToConstant: 16),

      worktreeStack.topAnchor.constraint(equalTo: projectHeader.bottomAnchor, constant: 6),
      worktreeStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
      worktreeStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),

      // Changes section
      changesSep.topAnchor.constraint(equalTo: worktreeStack.bottomAnchor, constant: 12),
      changesSep.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      changesSep.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

      changesHeader.topAnchor.constraint(equalTo: changesSep.bottomAnchor, constant: 12),
      changesHeader.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),

      filesStack.topAnchor.constraint(equalTo: changesHeader.bottomAnchor, constant: 6),
      filesStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
      filesStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),

      // Toolkit section
      toolkitSep.topAnchor.constraint(equalTo: filesStack.bottomAnchor, constant: 12),
      toolkitSep.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      toolkitSep.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

      toolkitHeader.topAnchor.constraint(equalTo: toolkitSep.bottomAnchor, constant: 12),
      toolkitHeader.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),

      toolkitStack.topAnchor.constraint(equalTo: toolkitHeader.bottomAnchor, constant: 6),
      toolkitStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
      toolkitStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),

      // Watchdogs section
      watchdogSep.topAnchor.constraint(equalTo: toolkitStack.bottomAnchor, constant: 12),
      watchdogSep.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      watchdogSep.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

      watchdogHeader.topAnchor.constraint(equalTo: watchdogSep.bottomAnchor, constant: 12),
      watchdogHeader.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),

      watchdogStack.topAnchor.constraint(equalTo: watchdogHeader.bottomAnchor, constant: 6),
      watchdogStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
      watchdogStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),

      addWatchdogBtn.topAnchor.constraint(equalTo: watchdogStack.bottomAnchor, constant: 4),
      addWatchdogBtn.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
      addWatchdogBtn.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
      addWatchdogBtn.heightAnchor.constraint(equalToConstant: 28),

      // Bottom of content — drives the scroll view's content size
      addWatchdogBtn.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
    ])

    refreshWorktrees()
    refreshFiles()
    refreshToolkit()
    refreshWatchdogs()
    updateFilesWatcher()

    // Rebuild the CHANGES list (and re-root the file watcher) when the user
    // switches sessions, since that changes the scoped directory.
    NotificationCenter.default.addObserver(
      self, selector: #selector(activeSessionChanged),
      name: .activeSessionDidChange, object: nil
    )
    // Belt-and-braces fallback: also refresh when an agent's state flips
    // (start/finish of a turn is when files change), in case FSEvents misses
    // a change or hasn't started yet. The snapshot guard keeps no-ops cheap.
    NotificationCenter.default.addObserver(
      self, selector: #selector(refreshFiles),
      name: .sessionStateDidChange, object: nil
    )

    // Auto-refresh toolkit when config file changes
    NotificationCenter.default.addObserver(
      self, selector: #selector(toolkitConfigDidChange),
      name: .toolkitDidChange, object: nil
    )
  }

  // MARK: - Worktrees

  /// Projects in the user's chosen sort order. "Active sessions" means the
  /// project has at least one open session rooted at the project itself or
  /// at a worktree beneath it (paths compared symlink-resolved, since git
  /// and session bookkeeping report realpaths).
  private func sortedProjects() -> [ProjectManager.Project] {
    let projects = ProjectManager.shared.projects
    var activePaths: Set<String> = []
    if ProjectManager.shared.sortOrder == .activeSessions {
      let sessionPaths = SessionManager.shared.sessions.compactMap { s in
        s.worktreePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
      }
      for project in projects {
        let root = URL(fileURLWithPath: project.path).resolvingSymlinksInPath().path
        if sessionPaths.contains(where: { $0 == root || $0.hasPrefix(root + "/") }) {
          activePaths.insert(project.path)
        }
      }
    }
    return ProjectManager.shared.sortedProjects(activeProjectPaths: activePaths)
  }

  @objc private func sortButtonClicked(_ sender: NSButton) {
    let menu = NSMenu()
    let current = ProjectManager.shared.sortOrder
    for order in ProjectManager.SortOrder.allCases {
      let item = NSMenuItem(
        title: order.displayName, action: #selector(sortOrderSelected(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = order.rawValue
      item.state = (order == current) ? .on : .off
      menu.addItem(item)
    }
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
  }

  @objc private func sortOrderSelected(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String,
      let order = ProjectManager.SortOrder(rawValue: raw)
    else { return }
    ProjectManager.shared.sortOrder = order
    refreshWorktrees()
  }

  /// Listings from the most recent completed enumeration. Lets UI-only
  /// changes (sort order, expand/collapse, active project) repaint in the
  /// same frame instead of waiting a git round-trip.
  private var lastEnumerated: [String: [WorktreeManager.Worktree]]?

  @objc func refreshWorktrees() {
    // Mid-sweep, each closed session and removed worktree would otherwise
    // trigger a rebuild; hold them until the sweep's summary lands.
    if sweepRemovalPhase {
      sweepDeferredRefresh = true
      return
    }
    // Repaint synchronously from cached listings first — sort, collapse, and
    // selection changes must land this frame to feel instant. The background
    // enumeration below then re-applies only if git reports something
    // different (the content snapshot guard makes it a no-op otherwise).
    if let cached = lastEnumerated {
      applyWorktreeResults(cached)
    }

    guard !worktreeRefreshInFlight else {
      worktreeRefreshQueued = true
      return
    }
    worktreeRefreshInFlight = true
    // A fresh enumeration reads the latest state, so any queued request is
    // satisfied by this run.
    worktreeRefreshQueued = false

    let projectPaths = ProjectManager.shared.projects.map { $0.path }
    worktreeEnumQueue.async { [weak self] in
      // Always fetch every project's worktrees, including collapsed ones, so
      // the rows exist in the stack and can be hidden/shown via animator()
      // without tearing the view down on every expand/collapse.
      var worktreesPerProject: [String: [WorktreeManager.Worktree]] = [:]
      for path in projectPaths {
        worktreesPerProject[path] = Self.enumerateWorktrees(for: path)
      }
      // Immutable bindings so the main-queue hop captures lets, not the
      // enclosing closure's vars (a Swift 6 sendability error).
      let enumerated = worktreesPerProject
      let sidebar = self
      DispatchQueue.main.async {
        guard let self = sidebar else { return }
        self.worktreeRefreshInFlight = false
        self.lastEnumerated = enumerated
        self.applyWorktreeResults(enumerated)
        if self.worktreeRefreshQueued {
          self.worktreeRefreshQueued = false
          self.refreshWorktrees()
        }
      }
    }
  }

  /// Render enumeration results against CURRENT main-thread state: project
  /// list/order, expansion, active dir, and the in-flight sets are all
  /// re-read here, so anything that changed while git ran can't paint stale
  /// rows. Only the worktree listings themselves come from the background
  /// pass.
  private func applyWorktreeResults(
    _ enumerated: [String: [WorktreeManager.Worktree]]
  ) {
    let projects = sortedProjects()
    let active = resolveActiveSelection(projects: projects)

    // A project added while the enumeration ran has no listing yet — render
    // it empty and queue a trailing pass so its rows appear right away
    // instead of waiting for the next status tick.
    if projects.contains(where: { enumerated[$0.path] == nil }) {
      worktreeRefreshQueued = true
    }

    var worktreesPerProject: [String: [WorktreeManager.Worktree]] = [:]
    for project in projects {
      worktreesPerProject[project.path] = (enumerated[project.path] ?? [])
        .filter { !pendingRemovals.contains($0.path) }
    }

    let sections = projects.map { project in
      ProjectSectionKey(
        path: project.path,
        name: project.name,
        isActive: project.path == active.projectPath,
        activeWorktreePath: project.path == active.projectPath ? active.worktreePath : nil,
        isPulling: pullsInFlight.contains(project.path),
        isSettingUp: worktreeSetupsInFlight.contains(project.path),
        sweepStatus: sweepsInFlight[project.path],
        worktrees: (worktreesPerProject[project.path] ?? []).map {
          WorktreeKey(path: $0.path, branch: $0.branch, isBare: $0.isBare)
        })
    }
    let expansionStates = projects.reduce(into: [String: Bool]()) {
      $0[$1.path] = $1.isExpanded
    }

    let contentChanged = (sections != lastSectionKeys)
    let expansionChanged = (expansionStates != lastExpansionStates)
    if !contentChanged && !expansionChanged {
      // The external-changes poll and no-op event bursts land here — nothing
      // visible has changed, so skip the rebuild and the resulting flash.
      return
    }

    if contentChanged {
      if sections.map(\.path) == lastSectionKeys.map(\.path), !sections.isEmpty {
        // Membership and order unchanged — replace only the sections whose
        // content differs, leaving every other project's rows untouched.
        // Worktree creation flows through here three times (spinner on,
        // spinner off + new row, session highlight); confining each pass to
        // the one affected project keeps the rest of the list from flashing.
        for (idx, section) in sections.enumerated() where section != lastSectionKeys[idx] {
          rebuildSection(
            project: projects[idx],
            active: active,
            worktrees: worktreesPerProject[section.path] ?? [])
        }
      } else {
        rebuildWorktreeRows(
          projects: projects,
          active: active,
          worktreesPerProject: worktreesPerProject)
      }
      lastSectionKeys = sections
      // Rows are freshly created; apply expansion state synchronously so
      // collapsed projects don't briefly flash their worktrees.
      applyExpansionStates(expansionStates, animated: false)
    } else {
      applyExpansionStates(expansionStates, animated: !lastExpansionStates.isEmpty)
    }
    lastExpansionStates = expansionStates
  }

  /// Which project (and worktree within it) the active session runs in.
  /// Paths are symlink-resolved so they compare equal to git's realpaths.
  private struct ActiveSelection: Equatable {
    /// Matches `ProjectManager.Project.path` (unresolved spelling).
    let projectPath: String?
    /// Resolved worktree path, or nil for a plain session in the project
    /// root (the primary worktree row is highlighted in that case).
    let worktreePath: String?
  }

  /// Derive the active project from the active session rather than
  /// `SessionManager.projectDir`, which is set once at open and never
  /// follows tab switches. Managed worktrees live under
  /// `<project>/.claude/worktrees/`, so a prefix match covers them; a
  /// hand-made worktree elsewhere falls back to asking git for its repo
  /// root; a session with no worktree path falls back to `projectDir`.
  private func resolveActiveSelection(projects: [ProjectManager.Project]) -> ActiveSelection {
    func resolve(_ p: String) -> String {
      URL(fileURLWithPath: p).resolvingSymlinksInPath().path
    }
    func project(owning resolved: String) -> ProjectManager.Project? {
      // Longest prefix wins so a nested project (a worktree added as its own
      // project) beats the outer repo that also contains it.
      projects
        .filter { proj in
          let root = resolve(proj.path)
          return resolved == root || resolved.hasPrefix(root + "/")
        }
        .max { resolve($0.path).count < resolve($1.path).count }
    }

    guard let sessionPath = SessionManager.shared.activeSession?.worktreePath else {
      guard let dir = SessionManager.shared.projectDir else {
        return ActiveSelection(projectPath: nil, worktreePath: nil)
      }
      let resolvedDir = resolve(dir)
      if let proj = project(owning: resolvedDir) {
        let isRoot = resolve(proj.path) == resolvedDir
        return ActiveSelection(
          projectPath: proj.path, worktreePath: isRoot ? nil : resolvedDir)
      }
      return ActiveSelection(projectPath: nil, worktreePath: nil)
    }

    let resolved = resolve(sessionPath)
    if let proj = project(owning: resolved) {
      return ActiveSelection(projectPath: proj.path, worktreePath: resolved)
    }
    // Hand-made worktree outside the project tree: its `.git` file points at
    // the owning repo, which git resolves for us.
    if let root = WorktreeManager.repoRoot(at: resolved),
      let proj = project(owning: resolve(root))
    {
      return ActiveSelection(projectPath: proj.path, worktreePath: resolved)
    }
    return ActiveSelection(projectPath: nil, worktreePath: nil)
  }

  /// Replace one project's header + worktree rows in place at their current
  /// stack position. Callers guarantee the project already has a section
  /// (same path set as the last render).
  private func rebuildSection(
    project: ProjectManager.Project,
    active: ActiveSelection,
    worktrees: [WorktreeManager.Worktree]
  ) {
    guard let oldHeader = projectHeaderRows[project.path],
      let insertAt = worktreeStack.arrangedSubviews.firstIndex(of: oldHeader)
    else { return }
    for view in [oldHeader] + (projectWorktreeRows[project.path] ?? []) {
      worktreeStack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    let views = buildProjectSection(
      project: project, active: active, worktrees: worktrees)
    for (offset, view) in views.enumerated() {
      worktreeStack.insertArrangedSubview(view, at: insertAt + offset)
    }
  }

  private func rebuildWorktreeRows(
    projects: [ProjectManager.Project],
    active: ActiveSelection,
    worktreesPerProject: [String: [WorktreeManager.Worktree]]
  ) {
    for v in worktreeStack.arrangedSubviews {
      worktreeStack.removeArrangedSubview(v)
      v.removeFromSuperview()
    }
    projectChevronViews.removeAll(keepingCapacity: true)
    projectHeaderRows.removeAll(keepingCapacity: true)
    projectWorktreeRows.removeAll(keepingCapacity: true)

    if projects.isEmpty {
      let emptyRow = makeRow(icon: "folder.badge.plus", text: "Open Project", detail: nil)
      emptyRow.heightAnchor.constraint(equalToConstant: 28).isActive = true
      worktreeStack.addArrangedSubview(emptyRow)
      return
    }

    for project in projects {
      let views = buildProjectSection(
        project: project,
        active: active,
        worktrees: worktreesPerProject[project.path] ?? [])
      for view in views {
        worktreeStack.addArrangedSubview(view)
      }
    }
  }

  /// Build one project's views — header row followed by its worktree rows —
  /// registering them in the per-project reference maps. The caller decides
  /// where the views land (appended on a full rebuild, spliced in place by
  /// `rebuildSection`).
  private func buildProjectSection(
    project: ProjectManager.Project,
    active: ActiveSelection,
    worktrees: [WorktreeManager.Worktree]
  ) -> [NSView] {
    var views: [NSView] = []
    let isActive = project.path == active.projectPath
    let resolvedProjectPath =
      URL(fileURLWithPath: project.path).resolvingSymlinksInPath().path

    // Project header row — clickable to expand/collapse. Chevron icon is
    // set by applyExpansionStates so we don't need to rebuild on toggle.
    let projectRow = makeClickableRow(
      icon: "chevron.right", text: project.name,
      detail: nil,
      target: self, action: #selector(projectRowClicked(_:)))
    projectRow.worktreePath = project.path
    projectRow.heightAnchor.constraint(equalToConstant: 28).isActive = true

    if isActive {
      projectRow.isSelected = true
      if let lbl = projectRow.subviews.compactMap({ $0 as? NSTextField }).first {
        lbl.font = Theme.mono(12, weight: .medium)
        lbl.textColor = Theme.text1
      }
    }

    if let chevron = projectRow.subviews.compactMap({ $0 as? NSImageView }).first {
      projectChevronViews[project.path] = chevron
    }

    let addBtn = NSButton(title: "", target: self, action: #selector(addWorktreeForProject(_:)))
    addBtn.image = Self.leafPlusBadge
    addBtn.isBordered = false
    addBtn.imageScaling = .scaleProportionallyDown
    addBtn.contentTintColor = Theme.text3
    addBtn.toolTip = "New worktree in \(project.name)"
    addBtn.translatesAutoresizingMaskIntoConstraints = false
    projectRow.addSubview(addBtn)
    NSLayoutConstraint.activate([
      addBtn.trailingAnchor.constraint(equalTo: projectRow.trailingAnchor),
      addBtn.centerYAnchor.constraint(equalTo: projectRow.centerYAnchor),
      addBtn.widthAnchor.constraint(equalToConstant: 16),
      addBtn.heightAnchor.constraint(equalToConstant: 16),
    ])

    // While a merged-PR sweep (context menu) runs for this project, show a
    // spinner and its progress text next to the add button.
    var trailingControl: NSView = addBtn
    if let status = sweepsInFlight[project.path] {
      let spinner = NSProgressIndicator()
      spinner.style = .spinning
      spinner.controlSize = .small
      spinner.isIndeterminate = true
      spinner.isDisplayedWhenStopped = false
      spinner.startAnimation(nil)
      spinner.translatesAutoresizingMaskIntoConstraints = false
      projectRow.addSubview(spinner)
      let statusLabel = label(status, size: 9, color: Theme.text3)
      statusLabel.translatesAutoresizingMaskIntoConstraints = false
      projectRow.addSubview(statusLabel)
      NSLayoutConstraint.activate([
        spinner.trailingAnchor.constraint(equalTo: addBtn.leadingAnchor, constant: -6),
        spinner.centerYAnchor.constraint(equalTo: projectRow.centerYAnchor),
        spinner.widthAnchor.constraint(equalToConstant: 16),
        spinner.heightAnchor.constraint(equalToConstant: 16),
        statusLabel.trailingAnchor.constraint(equalTo: spinner.leadingAnchor, constant: -4),
        statusLabel.centerYAnchor.constraint(equalTo: projectRow.centerYAnchor),
      ])
      trailingControl = statusLabel
    }

    // While a background default-branch pull or a worktree setup
    // (base-branch pull + create) runs for this project, show a spinner
    // next to the add button. Both sets are part of the snapshot, so the
    // row rebuilds when either changes.
    let isPulling = pullsInFlight.contains(project.path)
    if isPulling || worktreeSetupsInFlight.contains(project.path) {
      let anchorView = trailingControl
      let spinner = NSProgressIndicator()
      spinner.style = .spinning
      spinner.controlSize = .small
      spinner.isIndeterminate = true
      spinner.isDisplayedWhenStopped = false
      spinner.startAnimation(nil)
      spinner.translatesAutoresizingMaskIntoConstraints = false
      projectRow.addSubview(spinner)
      NSLayoutConstraint.activate([
        spinner.trailingAnchor.constraint(equalTo: anchorView.leadingAnchor, constant: -6),
        spinner.centerYAnchor.constraint(equalTo: projectRow.centerYAnchor),
        spinner.widthAnchor.constraint(equalToConstant: 16),
        spinner.heightAnchor.constraint(equalToConstant: 16),
      ])
      trailingControl = spinner
    }

    // The row label has no trailing constraint of its own; in a narrow
    // sidebar a long project name would run underneath the buttons. Pin it
    // clear of them and truncate the name instead.
    if let lbl = projectRow.subviews.compactMap({ $0 as? NSTextField }).first {
      lbl.lineBreakMode = .byTruncatingTail
      lbl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      lbl.trailingAnchor.constraint(
        lessThanOrEqualTo: trailingControl.leadingAnchor, constant: -6
      ).isActive = true
    }

    let menu = NSMenu()

    // Pull the default branch from its remote — keeps new worktrees (which
    // branch off the local default branch) from starting stale. Skipped
    // when no default branch is resolvable (e.g. not a git repo).
    if let defaultBranch = WorktreeManager.shared.defaultBranch(repoRoot: project.path) {
      // A nil action leaves the item disabled while a pull is in flight.
      let pullItem = NSMenuItem(
        title: isPulling ? "Pulling \(defaultBranch)…" : "Pull \(defaultBranch)",
        action: isPulling ? nil : #selector(pullDefaultBranch(_:)),
        keyEquivalent: "")
      pullItem.target = self
      pullItem.representedObject = DefaultBranchPullRequest(
        repoRoot: project.path, branch: defaultBranch)
      menu.addItem(pullItem)
    }

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

    let fromBranchItem = NSMenuItem(
      title: "New Worktree from Branch", action: #selector(addWorktreeFromBranch(_:)),
      keyEquivalent: "")
    fromBranchItem.target = self
    fromBranchItem.representedObject = project.path
    menu.addItem(fromBranchItem)

    menu.addItem(NSMenuItem.separator())
    let sweepItem = NSMenuItem(
      title: "Remove Merged Workspaces…",
      action: #selector(sweepProjectFromMenu(_:)), keyEquivalent: "")
    sweepItem.target = self
    sweepItem.representedObject = project.path
    menu.addItem(sweepItem)

    menu.addItem(NSMenuItem.separator())
    let removeItem = NSMenuItem(
      title: "Remove from List", action: #selector(removeProjectFromList(_:)), keyEquivalent: "")
    removeItem.target = self
    removeItem.representedObject = project.path
    menu.addItem(removeItem)

    projectRow.menu = menu
    views.append(projectRow)
    projectHeaderRows[project.path] = projectRow

    // Build worktree rows for every project regardless of expansion. They
    // start hidden; applyExpansionStates flips isHidden to reveal them.
    var wtRows: [NSView] = []
    if worktrees.isEmpty {
      let mainRow = makeRow(icon: "arrow.triangle.branch", text: "  main", detail: "base")
      mainRow.heightAnchor.constraint(equalToConstant: 26).isActive = true
      views.append(mainRow)
      wtRows.append(mainRow)
    } else {
      for wt in worktrees {
        let branchName = wt.branch.isEmpty ? "detached" : wt.branch
        let isBase = wt.isBare
        // The primary worktree is the project root itself (not a child
        // under .claude/worktrees/). Compare symlink-resolved paths: git
        // reports realpaths (e.g. /private/var) while the project may have
        // been added under an unresolved spelling.
        let resolvedWtPath = URL(fileURLWithPath: wt.path).resolvingSymlinksInPath().path
        let isPrimary = !isBase && resolvedWtPath == resolvedProjectPath
        // Highlight the row the active session runs in. A plain session
        // (no worktreePath) lives in the project root, i.e. the primary row.
        let isSelected =
          isActive
          && (active.worktreePath.map { $0 == resolvedWtPath } ?? isPrimary)
        let icon = isPrimary ? "circle.fill" : "arrow.triangle.branch"
        let detail = isBase ? "base" : nil
        let row = makeClickableRow(
          icon: icon, text: "  \(branchName)",
          detail: detail,
          target: self, action: #selector(worktreeRowClicked(_:)))
        if isPrimary {
          row.toolTip = "Currently checked-out branch in \(project.name)"
          if let img = row.subviews.compactMap({ $0 as? NSImageView }).first {
            let config = NSImage.SymbolConfiguration(pointSize: 6, weight: .regular)
            img.image = img.image?.withSymbolConfiguration(config)
          }
        }
        row.worktreeName = branchName
        row.worktreePath = wt.path
        row.isBaseWorktree = isBase
        row.isSelected = isSelected

        let wtMenu = NSMenu()
        let openItem = NSMenuItem(
          title: "Open Session Here", action: #selector(openSessionFromMenu(_:)),
          keyEquivalent: "")
        openItem.target = self
        openItem.representedObject = wt
        wtMenu.addItem(openItem)
        let branchItem = NSMenuItem(
          title: "New Worktree from Here", action: #selector(addWorktreeFromWorktree(_:)),
          keyEquivalent: "")
        branchItem.target = self
        // Carry the source worktree alongside the project's repo root so the
        // action can base the new worktree's branch off this worktree.
        branchItem.representedObject = WorktreeBranchRequest(source: wt, repoRoot: project.path)
        wtMenu.addItem(branchItem)
        if !isBase {
          wtMenu.addItem(NSMenuItem.separator())
          // Rename only applies to draftframe-managed worktrees — the
          // primary checkout is the project root itself and can't be moved
          // under .claude/worktrees/, and renaming a hand-made worktree
          // would relocate it there out from under the user.
          if !isPrimary && WorktreeManager.isManagedWorktree(wt.path) {
            let renameItem = NSMenuItem(
              title: "Rename Worktree", action: #selector(renameWorktreeFromMenu(_:)),
              keyEquivalent: "")
            renameItem.target = self
            renameItem.representedObject = WorktreeRenameRequest(
              worktree: wt, repoRoot: project.path)
            wtMenu.addItem(renameItem)
          }
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
        views.append(row)
        wtRows.append(row)
      }
    }
    projectWorktreeRows[project.path] = wtRows
    return views
  }

  private func applyExpansionStates(_ states: [String: Bool], animated: Bool) {
    // Symbol swap can't animate cleanly, do it synchronously regardless.
    for (path, isExpanded) in states {
      if let chevron = projectChevronViews[path] {
        chevron.image = NSImage(
          systemSymbolName: isExpanded ? "chevron.down" : "chevron.right",
          accessibilityDescription: nil)
      }
    }

    let apply: () -> Void = { [weak self] in
      guard let self = self else { return }
      for (path, isExpanded) in states {
        for row in self.projectWorktreeRows[path] ?? [] {
          if animated {
            row.animator().isHidden = !isExpanded
          } else {
            row.isHidden = !isExpanded
          }
        }
      }
    }

    if animated {
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.18
        ctx.allowsImplicitAnimation = true
        apply()
      }
    } else {
      apply()
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

  // MARK: - Sweep merged worktrees

  @objc private func sweepProjectFromMenu(_ sender: NSMenuItem) {
    guard let repoRoot = sender.representedObject as? String, !repoRoot.isEmpty,
      sweepsInFlight[repoRoot] == nil
    else { return }
    let projectName = (repoRoot as NSString).lastPathComponent
    setSweepStatus("Scanning…", for: repoRoot)

    WorktreeSweeper.shared.scan(repoRoot: repoRoot) { [weak self] candidates in
      guard let self = self else { return }
      if candidates.isEmpty {
        self.setSweepStatus(nil, for: repoRoot)
        self.showInfoSheet(
          title: "Nothing to Remove",
          body: "No workspaces in \(projectName) have a merged pull request.")
        return
      }
      // Keep the row busy behind the sheet so a second click can't start a
      // parallel sweep of the same repo.
      self.setSweepStatus("Confirm…", for: repoRoot)
      self.confirmSweep(projectName: projectName, candidates: candidates) { selected in
        guard !selected.isEmpty else {
          self.setSweepStatus(nil, for: repoRoot)
          return
        }
        self.runSweep(repoRoot: repoRoot, candidates: selected)
      }
    }
  }

  /// Confirmation sheet listing every candidate with a checkbox (all checked
  /// by default). Calls `completion` with the checked subset, or an empty
  /// array on cancel.
  private func confirmSweep(
    projectName: String, candidates: [SweepCandidate],
    completion: @escaping ([SweepCandidate]) -> Void
  ) {
    guard let win = window else {
      completion([])
      return
    }
    let alert = NSAlert()
    alert.messageText = "Remove Workspaces with Merged PRs in \(projectName)?"
    alert.informativeText =
      "These workspaces have merged pull requests. Checked workspaces will be removed, "
      + "along with any sessions open on them. Uncommitted changes in them will be lost."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Remove")
    alert.addButton(withTitle: "Cancel")

    let list = NSStackView()
    list.orientation = .vertical
    list.alignment = .leading
    list.spacing = 4
    list.translatesAutoresizingMaskIntoConstraints = false
    var checkboxes: [NSButton] = []
    for candidate in candidates {
      let branch =
        candidate.worktree.branch == candidate.name ? "" : "  (\(candidate.worktree.branch))"
      let box = NSButton(
        checkboxWithTitle: "\(candidate.name)\(branch)  PR #\(candidate.prNumber)",
        target: nil, action: nil)
      box.state = .on
      box.font = NSFont.systemFont(ofSize: 12)
      box.lineBreakMode = .byTruncatingMiddle
      list.addArrangedSubview(box)
      checkboxes.append(box)
    }

    // Scroll once the list would push the sheet past a sane height.
    let rowHeight: CGFloat = 22
    let visibleRows = min(candidates.count, 12)
    let scroll = NSScrollView(
      frame: NSRect(x: 0, y: 0, width: 420, height: CGFloat(visibleRows) * rowHeight + 4))
    scroll.hasVerticalScroller = candidates.count > visibleRows
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    let doc = FlippedView(
      frame: NSRect(x: 0, y: 0, width: 400, height: CGFloat(candidates.count) * rowHeight))
    doc.addSubview(list)
    NSLayoutConstraint.activate([
      list.topAnchor.constraint(equalTo: doc.topAnchor),
      list.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
      list.widthAnchor.constraint(equalTo: doc.widthAnchor),
    ])
    scroll.documentView = doc
    alert.accessoryView = scroll

    alert.beginSheetModal(for: win) { response in
      guard response == .alertFirstButtonReturn else {
        completion([])
        return
      }
      let selected = zip(candidates, checkboxes)
        .filter { $0.1.state == .on }
        .map { $0.0 }
      completion(selected)
    }
  }

  private func runSweep(repoRoot: String, candidates: [SweepCandidate]) {
    // Hide the doomed rows right away (painted from cache this frame), then
    // freeze the list for the duration of the removals.
    for c in candidates { pendingRemovals.insert(c.worktree.path) }
    setSweepStatus("Removing 1 of \(candidates.count)…", for: repoRoot)
    sweepRemovalPhase = true

    WorktreeSweeper.shared.sweep(
      repoRoot: repoRoot, candidates: candidates,
      progress: { [weak self] index, total in
        guard let self = self else { return }
        // Bypass the refresh guard: repaint just this row from cache.
        self.sweepsInFlight[repoRoot] = "Removing \(index) of \(total)…"
        if let cached = self.lastEnumerated { self.applyWorktreeResults(cached) }
      },
      completion: { [weak self] result in
        guard let self = self else { return }
        for c in candidates { self.pendingRemovals.remove(c.worktree.path) }
        self.sweepRemovalPhase = false
        self.setSweepStatus(nil, for: repoRoot)
        if self.sweepDeferredRefresh {
          self.sweepDeferredRefresh = false
          self.refreshWorktrees()
        }

        let removed = result.removed.count
        let noun = removed == 1 ? "workspace" : "workspaces"
        if result.failures.isEmpty {
          NotificationManager.shared.sendWatchdogNotification(
            title: "Removed \(removed) \(noun)",
            body: result.removed.map { "\($0.name) (PR #\($0.prNumber))" }
              .joined(separator: ", "))
        } else {
          let failed = result.failures.map { "\($0.candidate.name): \($0.message)" }
            .joined(separator: "\n")
          NotificationManager.shared.sendWatchdogNotification(
            title: "Removed \(removed) \(noun), \(result.failures.count) failed",
            body: failed)
          self.showInfoSheet(
            title: "Some Workspaces Couldn't Be Removed",
            body: failed)
        }
      })
  }

  /// Set (or clear, with nil) the sweep status shown in a project's row and
  /// repaint. Refreshes are guarded during the removal phase, so callers in
  /// that phase repaint from cache themselves.
  private func setSweepStatus(_ status: String?, for repoRoot: String) {
    if let status = status {
      sweepsInFlight[repoRoot] = status
    } else {
      sweepsInFlight.removeValue(forKey: repoRoot)
    }
    refreshWorktrees()
  }

  private func showInfoSheet(title: String, body: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = body
    alert.alertStyle = .informational
    alert.addButton(withTitle: "OK")
    if let win = window {
      alert.beginSheetModal(for: win)
    } else {
      alert.runModal()
    }
  }

  @objc private func renameWorktreeFromMenu(_ sender: NSMenuItem) {
    guard let req = sender.representedObject as? WorktreeRenameRequest else { return }
    let wt = req.worktree
    let projectRoot = req.repoRoot
    let oldName = wt.branch.isEmpty ? (wt.path as NSString).lastPathComponent : wt.branch

    let alert = NSAlert()
    alert.messageText = "Rename Worktree"
    alert.informativeText = "Renames the branch and moves the worktree directory to match."
    alert.addButton(withTitle: "Rename")
    alert.addButton(withTitle: "Cancel")
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    field.stringValue = oldName
    alert.accessoryView = field
    alert.window.initialFirstResponder = field

    guard let win = window else { return }
    alert.beginSheetModal(for: win) { response in
      guard response == .alertFirstButtonReturn else { return }
      let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !newName.isEmpty, newName != oldName else { return }

      DispatchQueue.global(qos: .userInitiated).async {
        let result = Result {
          try WorktreeManager.shared.renameWorktree(
            repoRoot: projectRoot, worktree: wt, newName: newName)
        }
        DispatchQueue.main.async {
          switch result {
          case .success(let newPath):
            SessionManager.shared.worktreeRenamed(from: wt.path, to: newPath, newName: newName)
          case .failure(let error):
            let errAlert = NSAlert()
            errAlert.messageText = "Rename Failed"
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

  /// Get worktrees for a specific project directory. Spawns git and blocks
  /// until it exits — call from `worktreeEnumQueue`, never the main thread.
  private nonisolated static func enumerateWorktrees(for projectPath: String)
    -> [WorktreeManager.Worktree]
  {
    let env = WorktreeManager.gitEnvironment()

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    proc.arguments = ["-C", projectPath, "worktree", "list", "--porcelain"]
    proc.environment = env
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    let data: Data
    do {
      try proc.run()
      // Read to EOF before waiting — output past the 64KB pipe buffer
      // would otherwise deadlock git against waitUntilExit().
      data = pipe.fileHandleForReading.readDataToEndOfFile()
      proc.waitUntilExit()
    } catch { return [] }
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

  @objc private func pullDefaultBranch(_ sender: NSMenuItem) {
    guard let req = sender.representedObject as? DefaultBranchPullRequest else { return }
    guard !pullsInFlight.contains(req.repoRoot) else { return }
    pullsInFlight.insert(req.repoRoot)
    refreshWorktrees()

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let error = WorktreeManager.shared.pullDefaultBranch(
        repoRoot: req.repoRoot, branch: req.branch)
      let sidebar = self
      DispatchQueue.main.async {
        guard let self = sidebar else { return }
        self.pullsInFlight.remove(req.repoRoot)
        self.refreshWorktrees()
        if let error = error {
          let alert = NSAlert()
          alert.messageText = "Pull \(req.branch) Failed"
          alert.informativeText = error.trimmingCharacters(in: .whitespacesAndNewlines)
          alert.alertStyle = .warning
          if let win = self.window {
            alert.beginSheetModal(for: win)
          } else {
            alert.runModal()
          }
        }
      }
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

  @objc private func addWorktreeForProject(_ sender: NSButton) {
    // The button lives inside the project's ClickableRow; read the path from
    // there rather than indexing into the (sort-order-dependent) project list.
    guard let row = sender.superview as? ClickableRow, let path = row.worktreePath else { return }
    let name = (path as NSString).lastPathComponent

    guard let win = window else { return }
    NewWorktreeDialog.present(
      on: win, title: "New Worktree",
      message: "Create a worktree in \(name)."
    ) { result in
      self.handleWorktreeDialogResult(result, repoRoot: path)
    }
  }

  @objc private func addWorktreeFromBranch(_ sender: NSMenuItem) {
    guard let projectPath = sender.representedObject as? String else { return }
    guard let win = window else { return }
    let projectName = (projectPath as NSString).lastPathComponent
    NewWorktreeDialog.present(
      on: win, title: "New Worktree from Branch",
      message: "Check out an existing branch in \(projectName) into a worktree.",
      initialMode: .existingBranch
    ) { result in
      self.handleWorktreeDialogResult(result, repoRoot: projectPath)
    }
  }

  /// Shared tail of the worktree-creation dialogs: create the worktree, open
  /// a session in it, then refresh the sidebar. Existing-branch checkouts get
  /// a session with no kickoff prompt — the worktree is set up but no work
  /// starts until the user says so.
  private func handleWorktreeDialogResult(
    _ result: NewWorktreeDialog.Result, repoRoot: String, baseBranch: String? = nil
  ) {
    switch result {
    case .newBranch(let name, let ticket):
      // Branching off the primary worktree's checked-out branch (no explicit
      // base): bring that branch up to date with its remote first so new
      // worktrees don't silently start from a stale base.
      if baseBranch == nil {
        createWorktreeAfterPull(repoRoot: repoRoot, name: name, ticket: ticket)
        return
      }
      guard
        let path = NewWorktreeDialog.createWorktreeReportingErrors(
          repoRoot: repoRoot, name: name, baseBranch: baseBranch)
      else { return }
      SessionManager.shared.createSession(
        name: name, worktreePath: path,
        initialPrompt: ticket.map(TicketLink.kickoffPrompt))
    case .existingBranch(let branch):
      guard
        let path = NewWorktreeDialog.checkoutWorktreeReportingErrors(
          repoRoot: repoRoot, branch: branch)
      else { return }
      SessionManager.shared.createSession(name: branch, worktreePath: path)
    }
    refreshWorktrees()
  }

  /// Pull the base branch, then create the worktree — both off the main
  /// thread, with a spinner on the project row meanwhile. The pull is
  /// best-effort: on failure (offline, diverged local branch) the worktree is
  /// still created from the local state and the error shows as a transient
  /// toast at the bottom of the window.
  private func createWorktreeAfterPull(repoRoot: String, name: String, ticket: String?) {
    worktreeSetupsInFlight.insert(repoRoot)
    refreshWorktrees()

    DispatchQueue.global(qos: .userInitiated).async {
      let pullResult = Result { try WorktreeManager.shared.pull(repoRoot: repoRoot) }
      let createResult = Result {
        try WorktreeManager.shared.createWorktree(repoRoot: repoRoot, name: name)
      }
      DispatchQueue.main.async {
        self.worktreeSetupsInFlight.remove(repoRoot)
        self.refreshWorktrees()

        if case .failure(let pullError) = pullResult, let win = self.window {
          let suffix =
            (try? createResult.get()) != nil
            ? " The worktree was created from the local branch." : ""
          DFToast.show("\(pullError.localizedDescription)\(suffix)", in: win)
        }

        switch createResult {
        case .success(let path):
          SessionManager.shared.createSession(
            name: name, worktreePath: path,
            initialPrompt: ticket.map(TicketLink.kickoffPrompt))
        case .failure(let error):
          NewWorktreeDialog.reportError(error)
        }
      }
    }
  }

  @objc private func addWorktreeFromWorktree(_ sender: NSMenuItem) {
    guard let req = sender.representedObject as? WorktreeBranchRequest else { return }
    let source = req.source
    // Base the new branch off the source worktree's branch, or its HEAD commit
    // when the worktree is in a detached state.
    let base = source.branch.isEmpty ? source.head : source.branch
    guard !base.isEmpty else { return }
    let sourceName =
      source.branch.isEmpty ? (source.path as NSString).lastPathComponent : source.branch

    guard let win = window else { return }
    NewWorktreeDialog.present(
      on: win, title: "New Worktree from \(sourceName)",
      message: "Create a worktree with a new branch based on \(sourceName)."
    ) { result in
      self.handleWorktreeDialogResult(result, repoRoot: req.repoRoot, baseBranch: base)
    }
  }

  // MARK: - Files

  @objc private func activeSessionChanged() {
    // Move the project/worktree highlight to the new active session. The
    // cached-listing repaint inside refreshWorktrees makes this land in the
    // same frame; the section-key diff confines the rebuild to the two
    // affected projects.
    refreshWorktrees()
    updateFilesWatcher()
    refreshFiles()
  }

  /// (Re)root the recursive file watcher at the active session's scoped
  /// directory. No-op when the directory is unchanged so we don't tear down a
  /// healthy FSEvents stream on every session-state notification.
  private func updateFilesWatcher() {
    let dir =
      SessionManager.shared.activeSession?.worktreePath
      ?? SessionManager.shared.projectDir
    guard dir != watchedFilesDir else { return }
    watchedFilesDir = dir

    // Drop the old stream before starting a new one.
    filesWatcher = nil
    guard let dir = dir else { return }
    filesWatcher = DirectoryWatcher(path: dir) { [weak self] in
      self?.refreshFiles()
    }
  }

  @objc private func refreshFiles() {
    // Scope the changes list to the directory of the session the user is
    // viewing: its worktree when it has one, otherwise the project root.
    let worktreeDir =
      SessionManager.shared.activeSession?.worktreePath
      ?? SessionManager.shared.projectDir

    if filesRefreshInFlight {
      filesRefreshQueued = true
      return
    }
    filesRefreshInFlight = true

    gitStatusQueue.async { [weak self] in
      let changedFiles = worktreeDir.map { Self.gitChangedFiles(in: $0) } ?? []
      let sidebar = self
      DispatchQueue.main.async {
        guard let self = sidebar else { return }
        self.filesRefreshInFlight = false

        // The active scope can change while git runs (session switch); the
        // result belongs to the old scope, so drop it and re-check.
        let currentDir =
          SessionManager.shared.activeSession?.worktreePath
          ?? SessionManager.shared.projectDir
        guard currentDir == worktreeDir else {
          self.filesRefreshQueued = false
          self.refreshFiles()
          return
        }

        if self.filesRefreshQueued {
          self.filesRefreshQueued = false
          self.refreshFiles()
        }
        self.applyChangedFiles(changedFiles, worktreeDir: worktreeDir)
      }
    }
  }

  private func applyChangedFiles(_ changedFiles: [ChangedFile], worktreeDir: String?) {
    // FSEvents and state changes land here repeatedly while an agent works;
    // skip the teardown/rebuild (and the hover/click disruption it causes)
    // unless the changed-file set actually differs from what's rendered.
    let snapshot = FilesContentSnapshot(worktreeDir: worktreeDir, files: changedFiles)
    guard snapshot != lastFilesSnapshot else { return }
    lastFilesSnapshot = snapshot

    for v in filesStack.arrangedSubviews {
      filesStack.removeArrangedSubview(v)
      v.removeFromSuperview()
    }
    changedFileRefs = []

    guard let worktreeDir = worktreeDir else { return }

    if changedFiles.isEmpty {
      let emptyLabel = label("No changes", size: 11, color: Theme.text3)
      emptyLabel.translatesAutoresizingMaskIntoConstraints = false
      filesStack.addArrangedSubview(emptyLabel)
      return
    }

    for file in changedFiles.prefix(50) {
      let statusIcon: String
      let statusColor: NSColor
      let statusName: String
      switch file.status {
      case "M":
        statusIcon = "pencil.circle"
        statusColor = Theme.yellow
        statusName = "Modified"
      case "A":
        statusIcon = "plus.circle"
        statusColor = Theme.green
        statusName = "Added"
      case "D":
        statusIcon = "minus.circle"
        statusColor = Theme.red
        statusName = "Deleted"
      case "?":
        statusIcon = "questionmark.circle"
        statusColor = Theme.text3
        statusName = "Untracked"
      case "R":
        statusIcon = "arrow.right.circle"
        statusColor = Theme.cyan
        statusName = "Renamed"
      default:
        statusIcon = "circle"
        statusColor = Theme.text3
        statusName = "Changed"
      }

      // Renames arrive as "old -> new"; the new path is what we diff and open.
      let relativePath = file.path.components(separatedBy: " -> ").last ?? file.path
      let fullPath = (worktreeDir as NSString).appendingPathComponent(relativePath)
      let row = makeClickableRow(
        icon: statusIcon, text: file.path, detail: nil,
        target: self, action: #selector(fileRowClicked(_:)))
      row.filePath = fullPath
      row.isDirectory = false
      row.diffIndex = changedFileRefs.count
      changedFileRefs.append(
        DFDiffOverlay.DiffFileRef(
          relativePath: relativePath, worktreeDir: worktreeDir, status: file.status,
          displayPath: relativePath))
      row.toolTip = statusName
      row.heightAnchor.constraint(equalToConstant: 24).isActive = true

      // Tint the icon with the status color
      if let iconView = row.subviews.compactMap({ $0 as? NSImageView }).first {
        iconView.contentTintColor = statusColor
      }

      filesStack.addArrangedSubview(row)
    }
  }

  private struct ChangedFile: Equatable {
    let status: String  // M, A, D, ?, R, etc.
    let path: String
  }

  private nonisolated static func gitChangedFiles(in dir: String) -> [ChangedFile] {
    let env = WorktreeManager.gitEnvironment()

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    proc.arguments = ["-C", dir, "status", "--porcelain"]
    proc.environment = env
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    let data: Data
    do {
      try proc.run()
      // Read to EOF before waiting — a repo with enough changed files to
      // overflow the 64KB pipe buffer would otherwise hang the app here.
      data = pipe.fileHandleForReading.readDataToEndOfFile()
      proc.waitUntilExit()
    } catch {
      return []
    }
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
    guard let row = sender as? ClickableRow else { return }

    if row.isDirectory {
      // Could expand directory in future; for now, no-op
      return
    }

    // Open the diff for this file in the session overlay (dismissible with Esc,
    // navigable with Up/Down across the whole CHANGES list).
    let index = row.diffIndex
    guard changedFileRefs.indices.contains(index) else { return }
    NotificationCenter.default.post(
      name: .showFileDiff, object: nil,
      userInfo: ["files": changedFileRefs, "index": index])
  }

  // MARK: - Toolkit

  private func refreshToolkit() {
    for v in toolkitStack.arrangedSubviews {
      toolkitStack.removeArrangedSubview(v)
      v.removeFromSuperview()
    }

    let commands = ToolkitManager.shared.commands
    for (i, cmd) in commands.enumerated() {
      let isRunning = ToolkitRunManager.shared.isRunning(key: ToolkitRun.key(for: cmd))
      let row = makeClickableRow(
        icon: cmd.icon, text: cmd.name, detail: isRunning ? "running" : nil,
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
    DFToolkitEditor.shared.show()
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

    outputPopover?.close()

    // Reattach to an in-flight run (or a finished one whose result hasn't
    // been seen yet) instead of starting a duplicate. Runs live in
    // ToolkitRunManager, so dismissing the transient popover loses nothing.
    let run: ToolkitRun
    if let existing = ToolkitRunManager.shared.latestRun(forKey: ToolkitRun.key(for: cmd)),
      existing.isRunning || !existing.resultSeen
    {
      run = existing
    } else {
      let dir = SessionManager.shared.activeSession?.worktreePath
      run = ToolkitRunManager.shared.start(cmd, inDirectory: dir)
    }

    let popover = NSPopover()
    popover.behavior = .transient
    popover.contentViewController = ToolkitRunViewController(run: run)
    popover.contentSize = NSSize(width: 400, height: 300)
    let senderView = sender as? NSView ?? self
    popover.show(relativeTo: senderView.bounds, of: senderView, preferredEdge: .maxX)
    self.outputPopover = popover
  }

  /// Update toolkit rows' "running" indicators on run start/finish.
  @objc private func toolkitRunStateChanged() {
    refreshToolkit()
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
      row.toolTip = wd.summary

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

    appendPRActionRows()
  }

  // MARK: - PR action watchdog rows

  /// PR-state-driven automations (auto-fix CI, auto-merge, auto-archive)
  /// are persisted per-project, not per-session, so they only render when
  /// there's an active session with a resolvable directory. Toggling writes
  /// through `PRMonitor`, which already handles persistence and reschedules
  /// the poller.
  private func appendPRActionRows() {
    guard let path = activePRConfigPath() else { return }
    let config = PRMonitor.shared.config(for: path)

    let specs: [(key: PRActionKey, title: String, icon: String, on: Bool, tooltip: String)] = [
      (
        .autoFix, "Auto-fix CI", "wand.and.stars", config.autoFix,
        "Asks Claude to investigate and fix failing CI checks when this project's PR starts failing."
      ),
      (
        .autoMerge, "Auto-merge PR", "arrow.triangle.merge", config.autoMerge,
        "Queues a squash merge (`gh pr merge --squash --auto`) when the PR's checks pass."
      ),
      (
        .autoArchive, "Auto-archive PR", "archivebox", config.autoArchive,
        "Closes the session and removes its worktree after the PR is merged or closed."
      ),
    ]

    for spec in specs {
      let row = makeClickableRow(
        icon: spec.on ? spec.icon : "\(spec.icon)",
        text: spec.title, detail: spec.on ? "on" : "off",
        target: self, action: #selector(togglePRActionFromRow(_:)))
      row.prActionKey = spec.key
      row.toolTip = spec.tooltip
      row.heightAnchor.constraint(equalToConstant: 28).isActive = true
      watchdogStack.addArrangedSubview(row)
    }
  }

  private func activePRConfigPath() -> String? {
    guard let session = SessionManager.shared.activeSession else { return nil }
    return PRMonitor.effectivePath(for: session)
  }

  @objc private func togglePRActionFromRow(_ sender: AnyObject) {
    guard let row = sender as? ClickableRow,
      let key = row.prActionKey,
      let path = activePRConfigPath()
    else { return }
    var config = PRMonitor.shared.config(for: path)
    switch key {
    case .autoFix: config.autoFix.toggle()
    case .autoMerge: config.autoMerge.toggle()
    case .autoArchive: config.autoArchive.toggle()
    }
    PRMonitor.shared.setConfig(config, for: path)
    if let sessionID = SessionManager.shared.activeSession?.id {
      PRMonitor.shared.refreshNow(sessionID: sessionID)
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

/// Identifies a PR-state-driven automation for rows in the watchdogs list.
enum PRActionKey { case autoFix, autoMerge, autoArchive }

/// A view that acts like a button — sends action on click.
/// Flipped NSView so auto-layout content starts at the top in a scroll view.
private final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}

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
  var prActionKey: PRActionKey?

  /// Index of this CHANGES row within the sidebar's `changedFileRefs`, used to
  /// open the diff overlay at the right file.
  var diffIndex: Int = 0

  /// Persistent selected state (e.g. the project/worktree the active session
  /// runs in). Owns the row's resting background; hover and mouse-down paint
  /// over it and restore to it rather than clearing.
  var isSelected: Bool = false {
    didSet { layer?.backgroundColor = restingColor.cgColor }
  }

  private var restingColor: NSColor { isSelected ? Theme.surface2 : .clear }

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
    layer?.backgroundColor = restingColor.cgColor
    if let action = action {
      NSApp.sendAction(action, to: target, from: self)
    }
  }

  override func mouseEntered(with event: NSEvent) {
    // Selected rows already sit at surface2; step up so hover stays visible.
    layer?.backgroundColor = (isSelected ? Theme.surface3 : Theme.surface2).cgColor
  }

  override func mouseExited(with event: NSEvent) {
    layer?.backgroundColor = restingColor.cgColor
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    // Only remove our own tracking areas — AppKit installs its own on this
    // view to drive `toolTip` hover detection, and removing those kills
    // tooltips for the row.
    for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
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

/// Payload stored on a "Rename Worktree" menu item so the action handler knows
/// both the worktree to rename and which project's repo it belongs to.
private struct WorktreeRenameRequest {
  let worktree: WorktreeManager.Worktree
  let repoRoot: String
}

/// Payload stored on a "New Worktree from Here" menu item so the action handler
/// knows which worktree to branch from and which project's repo it belongs to.
private struct WorktreeBranchRequest {
  let source: WorktreeManager.Worktree
  let repoRoot: String
}

/// Payload stored on a "Pull <branch>" menu item so the action handler knows
/// the repo and the default branch it resolved to when the menu was built.
private struct DefaultBranchPullRequest {
  let repoRoot: String
  let branch: String
}
