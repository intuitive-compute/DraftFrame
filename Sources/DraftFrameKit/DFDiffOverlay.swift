import AppKit

/// Full-window overlay showing a unified `git diff` for a single changed file
/// from the active session's worktree. Opened by clicking a file in the
/// sidebar's CHANGES list; dismissed with Esc.
final class DFDiffOverlay: NSView {

  /// One changed file the overlay can show and navigate to.
  struct DiffFileRef {
    let relativePath: String
    let worktreeDir: String
    let status: String
    let displayPath: String
  }

  private let headerLabel = NSTextField(labelWithString: "")
  private let statusPill = PillLabel()
  private let hintLabel = NSTextField(labelWithString: "")
  private let scrollView = NSScrollView()
  private let textView = NSTextView()

  /// The CHANGES list at the moment the overlay was opened, and which file
  /// within it is currently shown. Up/Down step through this list.
  private var files: [DiffFileRef] = []
  private var currentIndex = 0

  /// Local key monitor that catches Esc / Up / Down while the overlay is visible.
  private var keyMonitor: Any?

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = Theme.bg.cgColor
    isHidden = true
    setupUI()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  deinit { removeKeyMonitor() }

  private func setupUI() {
    headerLabel.font = Theme.mono(13, weight: .bold)
    headerLabel.textColor = Theme.text1
    headerLabel.lineBreakMode = .byTruncatingMiddle
    headerLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(headerLabel)

    statusPill.translatesAutoresizingMaskIntoConstraints = false
    addSubview(statusPill)

    hintLabel.font = Theme.mono(11)
    hintLabel.textColor = Theme.text3
    hintLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(hintLabel)

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = true
    scrollView.backgroundColor = Theme.surface1
    scrollView.borderType = .noBorder
    scrollView.wantsLayer = true
    scrollView.layer?.cornerRadius = 6
    addSubview(scrollView)

    // Non-wrapping, horizontally scrollable text view for diff output.
    textView.isEditable = false
    textView.isSelectable = true
    textView.drawsBackground = true
    textView.backgroundColor = Theme.surface1
    textView.textContainerInset = NSSize(width: 12, height: 12)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = true
    textView.autoresizingMask = []
    let unbounded = CGFloat.greatestFiniteMagnitude
    textView.maxSize = NSSize(width: unbounded, height: unbounded)
    textView.textContainer?.widthTracksTextView = false
    textView.textContainer?.containerSize = NSSize(width: unbounded, height: unbounded)
    scrollView.documentView = textView

    NSLayoutConstraint.activate([
      headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: 36),
      headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
      headerLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: statusPill.leadingAnchor, constant: -10),

      statusPill.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
      statusPill.heightAnchor.constraint(equalToConstant: 18),
      statusPill.trailingAnchor.constraint(equalTo: hintLabel.leadingAnchor, constant: -16),

      hintLabel.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
      hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),

      scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 16),
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -30),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -30),
    ])
  }

  // MARK: - Show / dismiss

  /// Reveal the overlay showing `files[index]`, with Up/Down navigating the
  /// rest of the list. The list is a snapshot of the CHANGES rows at click time.
  func show(files: [DiffFileRef], index: Int) {
    guard !files.isEmpty else { return }
    self.files = files
    currentIndex = min(max(0, index), files.count - 1)
    renderCurrent()
    isHidden = false
    installKeyMonitor()
  }

  func dismiss() {
    guard !isHidden else { return }
    isHidden = true
    removeKeyMonitor()
  }

  /// Render the file at `currentIndex` — header, status pill, and colored diff.
  private func renderCurrent() {
    guard files.indices.contains(currentIndex) else { return }
    let file = files[currentIndex]

    headerLabel.stringValue = file.displayPath
    headerLabel.toolTip = (file.worktreeDir as NSString).appendingPathComponent(file.relativePath)
    statusPill.configure(status: file.status)
    hintLabel.stringValue =
      files.count > 1
      ? "\(currentIndex + 1) / \(files.count)   ↑ ↓ navigate · esc close"
      : "esc close"

    let diff = Self.gitDiff(
      relativePath: file.relativePath, worktreeDir: file.worktreeDir, status: file.status)
    textView.textStorage?.setAttributedString(Self.attributedDiff(diff))
    textView.scroll(.zero)
  }

  /// Move `delta` files through the list, clamped to its bounds.
  private func step(_ delta: Int) {
    let target = min(max(0, currentIndex + delta), files.count - 1)
    guard target != currentIndex else { return }
    currentIndex = target
    renderCurrent()
  }

  private func installKeyMonitor() {
    guard keyMonitor == nil else { return }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self = self, !self.isHidden else { return event }
      switch event.keyCode {
      case 53:  // Esc — close
        self.dismiss()
        return nil
      case 126:  // Up arrow — previous file
        self.step(-1)
        return nil
      case 125:  // Down arrow — next file
        self.step(1)
        return nil
      default:
        return event
      }
    }
  }

  private func removeKeyMonitor() {
    if let m = keyMonitor {
      NSEvent.removeMonitor(m)
      keyMonitor = nil
    }
  }

  // MARK: - Git

  private static func gitDiff(relativePath: String, worktreeDir: String, status: String) -> String {
    let env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
    let args: [String]
    if status == "?" {
      // Untracked: diff against /dev/null so the whole file reads as added.
      // `--no-index` exits non-zero when the files differ; we still want stdout.
      args = [
        "-C", worktreeDir, "diff", "--no-color", "--no-index", "--", "/dev/null", relativePath,
      ]
    } else {
      // Tracked: working tree vs HEAD captures staged and unstaged changes,
      // matching what the CHANGES list reports from `git status`.
      args = ["-C", worktreeDir, "diff", "--no-color", "HEAD", "--", relativePath]
    }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    proc.arguments = args
    proc.environment = env
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do {
      try proc.run()
      // Read to EOF before waiting so a diff larger than the pipe buffer can't
      // deadlock the app.
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      proc.waitUntilExit()
      return String(data: data, encoding: .utf8) ?? ""
    } catch {
      return ""
    }
  }

  /// Color a unified diff line by line: additions green, deletions red, hunk
  /// headers cyan, file headers dimmed, context muted.
  static func attributedDiff(_ diff: String) -> NSAttributedString {
    let font = Theme.mono(12)
    if diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return NSAttributedString(
        string: "No textual diff to display.",
        attributes: [.font: font, .foregroundColor: Theme.text3])
    }

    let result = NSMutableAttributedString()
    let lines = diff.components(separatedBy: "\n")
    for (i, line) in lines.enumerated() {
      let color: NSColor
      if line.hasPrefix("@@") {
        color = Theme.cyan
      } else if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff --git")
        || line.hasPrefix("index ") || line.hasPrefix("new file") || line.hasPrefix("deleted file")
        || line.hasPrefix("rename ") || line.hasPrefix("similarity ") || line.hasPrefix("old mode")
        || line.hasPrefix("new mode") || line.hasPrefix("\\ No newline")
      {
        color = Theme.text3
      } else if line.hasPrefix("+") {
        color = Theme.green
      } else if line.hasPrefix("-") {
        color = Theme.red
      } else {
        color = Theme.text2
      }
      let text = (i == lines.count - 1) ? line : line + "\n"
      result.append(
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
    }
    return result
  }
}

/// Small rounded status pill (Modified / Added / Deleted / …) used in the diff
/// overlay header.
private final class PillLabel: NSTextField {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    // The fill is drawn by the layer (rounded), so the cell only draws the
    // vertically-centered text — otherwise NSTextField top-aligns it and the
    // label rides high in the pill.
    cell = CenteredTextFieldCell()
    isEditable = false
    isBordered = false
    isSelectable = false
    drawsBackground = false
    alignment = .center
    font = Theme.mono(10, weight: .medium)
    wantsLayer = true
    layer?.cornerRadius = 4
    layer?.masksToBounds = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override var intrinsicContentSize: NSSize {
    var size = super.intrinsicContentSize
    size.width += 16  // horizontal padding around the label text
    return size
  }

  func configure(status: String) {
    let name: String
    let color: NSColor
    switch status {
    case "M":
      name = "Modified"
      color = Theme.yellow
    case "A":
      name = "Added"
      color = Theme.green
    case "D":
      name = "Deleted"
      color = Theme.red
    case "?":
      name = "Untracked"
      color = Theme.text3
    case "R":
      name = "Renamed"
      color = Theme.cyan
    default:
      name = "Changed"
      color = Theme.text3
    }
    stringValue = name.uppercased()
    textColor = Theme.bg
    layer?.backgroundColor = color.cgColor
    invalidateIntrinsicContentSize()
  }
}

/// NSTextFieldCell that centers its text vertically. NSTextField otherwise
/// top-aligns the title within a fixed-height frame.
private final class CenteredTextFieldCell: NSTextFieldCell {
  override func titleRect(forBounds rect: NSRect) -> NSRect {
    let textHeight = cellSize.height
    var titleRect = super.titleRect(forBounds: rect)
    titleRect.origin.y = rect.origin.y + (rect.height - textHeight) / 2
    titleRect.size.height = textHeight
    return titleRect
  }

  override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
    super.drawInterior(withFrame: titleRect(forBounds: cellFrame), in: controlView)
  }
}

extension Notification.Name {
  /// Posted by the sidebar when a CHANGES file row is clicked. userInfo:
  /// `relativePath`, `worktreeDir`, `status`, `displayPath`.
  static let showFileDiff = Notification.Name("DFShowFileDiff")
}
