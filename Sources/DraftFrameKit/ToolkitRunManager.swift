import AppKit

/// A single execution of a toolkit command, owning the process and its
/// streamed output. Runs outlive the popover that displays them, so closing
/// the (transient) popover mid-run doesn't lose the process or its log.
final class ToolkitRun {
  let id = UUID()
  let commandKey: String
  let commandName: String
  let commandLine: String
  let startedAt = Date()

  fileprivate(set) var output = ""
  fileprivate(set) var exitCode: Int32?
  fileprivate(set) var process: Process?

  /// True once a finished run's result has been displayed — clicking the
  /// command again then starts a fresh run instead of reattaching.
  var resultSeen = false

  var isRunning: Bool { exitCode == nil }

  fileprivate init(command: ToolkitManager.ToolkitCommand) {
    commandKey = Self.key(for: command)
    commandName = command.name
    commandLine = command.command
  }

  /// Identity of a command across config reloads (index is not stable).
  static func key(for command: ToolkitManager.ToolkitCommand) -> String {
    command.name + "\u{1F}" + command.command
  }

  func terminate() {
    process?.terminate()
  }
}

/// Owns all toolkit runs and their processes, decoupled from the popover UI.
/// Output is streamed in as it's produced and broadcast via notifications;
/// any view can attach to a run at any point in its lifecycle.
final class ToolkitRunManager {
  static let shared = ToolkitRunManager()

  /// Newest first. Finished runs are pruned past `maxRuns`; running ones
  /// are never dropped.
  private(set) var runs: [ToolkitRun] = []

  private static let maxRuns = 20

  /// Cap per-run log size so a chatty process doesn't grow unbounded.
  private static let maxOutputBytes = 2_000_000

  private init() {}

  func latestRun(forKey key: String) -> ToolkitRun? {
    runs.first { $0.commandKey == key }
  }

  func isRunning(key: String) -> Bool {
    latestRun(forKey: key)?.isRunning == true
  }

  @discardableResult
  func start(_ command: ToolkitManager.ToolkitCommand, inDirectory dir: String?) -> ToolkitRun {
    let run = ToolkitRun(command: command)
    runs.insert(run, at: 0)
    if runs.count > Self.maxRuns,
      let idx = runs.lastIndex(where: { !$0.isRunning })
    {
      runs.remove(at: idx)
    }

    let proc = Process()
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    proc.executableURL = URL(fileURLWithPath: shell)
    proc.arguments = ["-l", "-c", command.command]
    if let dir = dir {
      proc.currentDirectoryURL = URL(fileURLWithPath: dir)
    }

    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe

    pipe.fileHandleForReading.readabilityHandler = { [weak self, weak run] fh in
      let data = fh.availableData
      if data.isEmpty {  // EOF
        fh.readabilityHandler = nil
        return
      }
      guard let chunk = String(data: data, encoding: .utf8) else { return }
      DispatchQueue.main.async {
        guard let self = self, let run = run else { return }
        self.append(chunk, to: run)
      }
    }

    proc.terminationHandler = { [weak run] p in
      DispatchQueue.main.async {
        guard let run = run else { return }
        run.exitCode = p.terminationStatus
        run.process = nil
        NotificationCenter.default.post(
          name: .toolkitRunStateDidChange, object: nil, userInfo: ["runID": run.id])
      }
    }

    run.process = proc
    do {
      try proc.run()
    } catch {
      run.output = "Failed to run: \(error.localizedDescription)"
      run.exitCode = 1
      run.process = nil
    }

    NotificationCenter.default.post(
      name: .toolkitRunStateDidChange, object: nil, userInfo: ["runID": run.id])
    return run
  }

  private func append(_ chunk: String, to run: ToolkitRun) {
    run.output += chunk
    if run.output.utf8.count > Self.maxOutputBytes {
      run.output = String(run.output.suffix(Self.maxOutputBytes / 2))
    }
    NotificationCenter.default.post(
      name: .toolkitRunOutputDidChange, object: nil, userInfo: ["runID": run.id])
  }
}

extension Notification.Name {
  /// A run produced output. userInfo: ["runID": UUID]
  static let toolkitRunOutputDidChange = Notification.Name("DFToolkitRunOutputDidChange")
  /// A run started or finished. userInfo: ["runID": UUID]
  static let toolkitRunStateDidChange = Notification.Name("DFToolkitRunStateDidChange")
}

// MARK: - Run Popover

/// Popover content bound to a ToolkitRun. All state is pulled from the run
/// and refreshed via run notifications, so the popover can be closed and a
/// new one attached at any point during or after execution.
final class ToolkitRunViewController: NSViewController {
  private let run: ToolkitRun

  private let statusLabel = NSTextField(labelWithString: "")
  private let textView = NSTextView()
  private var stopButton: NSButton!

  init(run: ToolkitRun) {
    self.run = run
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  override func loadView() {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    container.wantsLayer = true
    container.layer?.backgroundColor = Theme.surface2.cgColor

    statusLabel.font = Theme.mono(11, weight: .medium)
    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(statusLabel)

    let cmdLabel = NSTextField(labelWithString: run.commandLine)
    cmdLabel.font = Theme.mono(10)
    cmdLabel.textColor = Theme.text3
    cmdLabel.lineBreakMode = .byTruncatingTail
    cmdLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    cmdLabel.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(cmdLabel)

    stopButton = NSButton(title: "Stop", target: self, action: #selector(stopClicked))
    stopButton.isBordered = false
    stopButton.wantsLayer = true
    stopButton.layer?.backgroundColor = Theme.red.withAlphaComponent(0.15).cgColor
    stopButton.layer?.cornerRadius = 4
    stopButton.font = Theme.mono(10, weight: .medium)
    stopButton.contentTintColor = Theme.red
    stopButton.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(stopButton)

    let sep = NSView()
    sep.wantsLayer = true
    sep.layer?.backgroundColor = Theme.surface3.cgColor
    sep.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(sep)

    let scrollView = NSScrollView()
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.autohidesScrollers = true
    container.addSubview(scrollView)

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
        lessThanOrEqualTo: stopButton.leadingAnchor, constant: -8),

      stopButton.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
      stopButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
      stopButton.widthAnchor.constraint(equalToConstant: 44),
      stopButton.heightAnchor.constraint(equalToConstant: 18),

      sep.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
      sep.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      sep.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      sep.heightAnchor.constraint(equalToConstant: 1),

      scrollView.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 4),
      scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
      scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
      scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
    ])

    view = container
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    render()
    NotificationCenter.default.addObserver(
      self, selector: #selector(runDidUpdate(_:)),
      name: .toolkitRunOutputDidChange, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(runDidUpdate(_:)),
      name: .toolkitRunStateDidChange, object: nil)
  }

  @objc private func runDidUpdate(_ note: Notification) {
    guard (note.userInfo?["runID"] as? UUID) == run.id else { return }
    render()
  }

  @objc private func stopClicked() {
    run.terminate()
  }

  private func render() {
    if run.isRunning {
      statusLabel.stringValue = "Running..."
      statusLabel.textColor = Theme.yellow
    } else if run.exitCode == 0 {
      statusLabel.stringValue = "Done (exit 0)"
      statusLabel.textColor = Theme.green
    } else {
      statusLabel.stringValue = "Failed (exit \(run.exitCode ?? 1))"
      statusLabel.textColor = Theme.red
    }
    stopButton.isHidden = !run.isRunning
    if !run.isRunning {
      run.resultSeen = true
    }

    if textView.string != run.output {
      textView.string = run.output
      textView.scrollRangeToVisible(NSRange(location: (run.output as NSString).length, length: 0))
    }
  }
}
