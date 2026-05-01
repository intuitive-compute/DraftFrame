import Foundation

/// Watches a Claude Code JSONL session log and accumulates token usage/cost.
final class SessionJSONLWatcher {

  // MARK: - Model pricing per token (derived from per-1M-token rates)

  private struct ModelPricing {
    let inputPerToken: Double
    let outputPerToken: Double
    let cacheCreationPerToken: Double  // 1.25x input
    let cacheReadPerToken: Double  // 0.1x input

    init(inputPerMillion: Double, outputPerMillion: Double) {
      self.inputPerToken = inputPerMillion / 1_000_000
      self.outputPerToken = outputPerMillion / 1_000_000
      self.cacheCreationPerToken = (inputPerMillion * 1.25) / 1_000_000
      self.cacheReadPerToken = (inputPerMillion * 0.1) / 1_000_000
    }
  }

  private static let pricing: [String: ModelPricing] = [
    "opus": ModelPricing(inputPerMillion: 15, outputPerMillion: 75),
    "sonnet": ModelPricing(inputPerMillion: 3, outputPerMillion: 15),
    "haiku": ModelPricing(inputPerMillion: 0.25, outputPerMillion: 1.25),
  ]

  // MARK: - Public state

  typealias UpdateCallback = (
    _ cost: Double,
    _ tokensIn: Int,
    _ tokensOut: Int,
    _ model: String,
    _ contextTokens: Int,
    _ maxContextTokens: Int
  ) -> Void

  private(set) var totalCost: Double = 0
  private(set) var totalTokensIn: Int = 0
  private(set) var totalTokensOut: Int = 0
  private(set) var latestModel: String = "sonnet"
  /// Tokens fed to the model on the most recent assistant turn
  /// (input + cache_creation + cache_read). Snapshot, not a sum.
  private(set) var currentContextTokens: Int = 0
  /// Bare model id from the most recent assistant turn (e.g.
  /// "claude-opus-4-7"). Note: JSONL bodies never carry the "[1m]" suffix.
  private(set) var latestBareModel: String = ""
  /// Max context window parsed from `/context` or `/model` slash-command
  /// output captured in user messages. Zero means "no JSONL signal yet" —
  /// the Session should ignore this value and keep whatever the PTY banner
  /// detected.
  private(set) var parsedMaxContextTokens: Int = 0

  /// Most recent assistant text response parsed from the JSONL stream.
  /// Used by the dashboard's cross-session summary view. Nil until the
  /// session has produced its first text-bearing assistant message.
  private(set) var latestAssistantText: String?

  /// Timestamp of the most recent assistant text.
  private(set) var latestAssistantAt: Date?

  // MARK: - Private

  private let onUpdate: UpdateCallback
  private var watcherFD: Int32 = -1
  private var dispatchSource: DispatchSourceFileSystemObject?
  private var fileOffset: UInt64 = 0
  /// Holds the tail of the last read when it didn't end on a newline — JSONL
  /// writes can land mid-line and we'd otherwise drop the partial.
  private var lineBuffer: String = ""
  private var pollTimer: DispatchSourceTimer?
  private let watchQueue = DispatchQueue(label: "com.draftframe.jsonl-watcher", qos: .utility)
  private var watchedPath: String?
  private var directorySource: DispatchSourceFileSystemObject?
  private var directoryHandle: Int32 = -1
  private var resolved = false
  private let workingDirectory: String

  // MARK: - Init

  /// Create a watcher for sessions launched from `workingDirectory`.
  /// The watcher locates the newest JSONL in the matching ~/.claude/projects/ subfolder
  /// and streams new assistant messages as they arrive.
  init(workingDirectory: String, onUpdate: @escaping UpdateCallback) {
    self.workingDirectory = workingDirectory
    self.onUpdate = onUpdate
    resolveAndWatch()
  }

  deinit {
    stop()
  }

  // MARK: - Public

  func stop() {
    dispatchSource?.cancel()
    dispatchSource = nil
    directorySource?.cancel()
    directorySource = nil
    pollTimer?.cancel()
    pollTimer = nil
    if watcherFD >= 0 {
      close(watcherFD)
      watcherFD = -1
    }
    if directoryHandle >= 0 {
      close(directoryHandle)
      directoryHandle = -1
    }
  }

  // MARK: - Resolution

  private func resolveAndWatch() {
    guard let jsonlPath = findLatestJSONL() else {
      // The JSONL file may not exist yet (Claude hasn't started).
      // Watch the directory for new files.
      watchDirectoryForNewFiles()
      return
    }
    startWatching(path: jsonlPath)
  }

  /// Encode a directory path the way Claude Code does: replace `/` with `-`, prepend `-`.
  static func encodePath(_ path: String) -> String {
    return "-" + path.dropFirst().replacingOccurrences(of: "/", with: "-")
  }

  private func claudeProjectDir() -> String? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let encoded = Self.encodePath(workingDirectory)
    let dir = "\(home)/.claude/projects/\(encoded)"
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
      return nil
    }
    return dir
  }

  private func findLatestJSONL() -> String? {
    guard let dir = claudeProjectDir() else { return nil }
    let fm = FileManager.default
    guard let contents = try? fm.contentsOfDirectory(atPath: dir) else { return nil }

    var newest: String?
    var newestDate = Date.distantPast

    for name in contents where name.hasSuffix(".jsonl") {
      let full = "\(dir)/\(name)"
      if let attrs = try? fm.attributesOfItem(atPath: full),
        let mod = attrs[.modificationDate] as? Date,
        mod > newestDate
      {
        newestDate = mod
        newest = full
      }
    }
    return newest
  }

  // MARK: - Directory watching (for when JSONL doesn't exist yet)

  private func watchDirectoryForNewFiles() {
    // Build the expected directory path; create it if missing so we can watch it.
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let encoded = Self.encodePath(workingDirectory)
    let dir = "\(home)/.claude/projects/\(encoded)"

    // Poll periodically until the file appears.
    let timer = DispatchSource.makeTimerSource(queue: watchQueue)
    timer.schedule(deadline: .now() + 2, repeating: 3.0)
    timer.setEventHandler { [weak self] in
      guard let self = self, !self.resolved else {
        self?.pollTimer?.cancel()
        return
      }
      if let path = self.findLatestJSONL() {
        self.resolved = true
        self.pollTimer?.cancel()
        self.pollTimer = nil
        self.startWatching(path: path)
      }
    }
    timer.resume()
    pollTimer = timer
  }

  // MARK: - File watching

  private func startWatching(path: String) {
    resolved = true
    watchedPath = path

    // Process whatever's already in the file.
    processNewData()

    // Watch for writes via DispatchSource. We only use the FD for kqueue
    // event delivery — actual reads always go through a fresh file handle
    // because macOS Foundation's `FileHandle` caches stat info in ways
    // that miss appends made by another process.
    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else {
      // No event source — polling alone will keep us in sync.
      schedulePollTimer()
      return
    }
    watcherFD = fd
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd,
      eventMask: [.write, .extend],
      queue: watchQueue
    )
    source.setEventHandler { [weak self] in
      self?.processNewData()
    }
    source.setCancelHandler { [weak self] in
      if let self = self, self.watcherFD == fd { self.watcherFD = -1 }
      close(fd)
    }
    source.resume()
    dispatchSource = source

    schedulePollTimer()
  }

  /// Re-attach to a newly-appeared JSONL (e.g. user restarted `claude`).
  /// Resets the read offset and the partial-line buffer so we begin
  /// streaming the new file from byte 0.
  private func switchTo(path: String) {
    dispatchSource?.cancel()
    dispatchSource = nil
    if watcherFD >= 0 {
      close(watcherFD)
      watcherFD = -1
    }
    watchedPath = path
    fileOffset = 0
    lineBuffer = ""

    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else { return }
    watcherFD = fd
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd,
      eventMask: [.write, .extend],
      queue: watchQueue
    )
    source.setEventHandler { [weak self] in
      self?.processNewData()
    }
    source.setCancelHandler { [weak self] in
      if let self = self, self.watcherFD == fd { self.watcherFD = -1 }
      close(fd)
    }
    source.resume()
    dispatchSource = source
  }

  private func schedulePollTimer() {
    // Poll periodically as a belt-and-braces fallback — some FSes don't
    // reliably deliver vnode events for every append.
    let timer = DispatchSource.makeTimerSource(queue: watchQueue)
    timer.schedule(deadline: .now() + 1.5, repeating: 1.5)
    timer.setEventHandler { [weak self] in
      self?.processNewData()
    }
    timer.resume()
    pollTimer = timer
  }

  private func processNewData() {
    // Each new `claude` invocation in this project writes a different
    // JSONL (the filename is the sessionId). If a newer one has appeared
    // since we attached, switch to it — otherwise we'd track a stale file
    // forever and miss every assistant turn after the user restarted.
    if let newest = findLatestJSONL(), newest != watchedPath {
      switchTo(path: newest)
    }

    guard let path = watchedPath else { return }

    // Re-open on every read. A long-lived FileHandle on macOS misses
    // appends made by another process even after `seek(toFileOffset:)`,
    // because `readDataToEndOfFile()` consults a stale cached file size.
    guard let fh = FileHandle(forReadingAtPath: path) else { return }
    defer { try? fh.close() }

    do {
      try fh.seek(toOffset: fileOffset)
    } catch {
      return
    }
    let data = fh.readDataToEndOfFile()
    guard !data.isEmpty else { return }
    fileOffset += UInt64(data.count)

    guard let text = String(data: data, encoding: .utf8) else { return }
    // Prepend any partial line carried over from a previous read.
    let combined = lineBuffer + text
    let lastNewline = combined.lastIndex(of: "\n")
    let processable: Substring
    if let nl = lastNewline {
      processable = combined[..<nl]
      lineBuffer = String(combined[combined.index(after: nl)...])
    } else {
      // No newline yet — entire chunk is partial; buffer it for next read.
      lineBuffer = combined
      return
    }

    var didUpdate = false
    for line in processable.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      if parseAssistantLine(trimmed) || parseUserLine(trimmed) {
        didUpdate = true
      }
    }

    if didUpdate {
      let cost = totalCost
      let tIn = totalTokensIn
      let tOut = totalTokensOut
      let model = latestModel
      let ctx = currentContextTokens
      let maxCtx = parsedMaxContextTokens
      DispatchQueue.main.async { [weak self] in
        self?.onUpdate(cost, tIn, tOut, model, ctx, maxCtx)
      }
    }
  }

  /// Parse a single JSONL line. Returns true if it was an assistant message with usage.
  private func parseAssistantLine(_ line: String) -> Bool {
    guard let data = line.data(using: .utf8) else { return false }
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return false
    }
    guard let type = obj["type"] as? String, type == "assistant" else { return false }
    guard let message = obj["message"] as? [String: Any] else { return false }
    guard let usage = message["usage"] as? [String: Any] else { return false }

    // Claude Code emits placeholder assistant messages with model="<synthetic>"
    // for tool-result wrappers and similar. They carry an all-zero `usage`
    // block; if we don't bail early they overwrite `currentContextTokens`
    // with 0 right after each real turn. Skip the whole update.
    if let model = message["model"] as? String, model == "<synthetic>" {
      return false
    }

    let inputTokens = usage["input_tokens"] as? Int ?? 0
    let outputTokens = usage["output_tokens"] as? Int ?? 0
    let cacheCreationTokens = usage["cache_creation_input_tokens"] as? Int ?? 0
    let cacheReadTokens = usage["cache_read_input_tokens"] as? Int ?? 0

    if let model = message["model"] as? String {
      latestModel = Self.shortModelName(model)
      latestBareModel = model
      // Mirror Claude Code's own B2() context-window logic so the cap is
      // correct from the very first assistant turn. The JSONL never carries
      // the `[1m]` suffix on its own, but `claude-opus-4-7` is always 1M
      // regardless. /context and /model captures may upgrade this further.
      let modelCap = Self.contextWindowCap(forModelId: model)
      if modelCap > parsedMaxContextTokens || parsedMaxContextTokens == 0 {
        parsedMaxContextTokens = modelCap
      }
    }

    currentContextTokens = inputTokens + cacheCreationTokens + cacheReadTokens

    // Capture assistant text content for the cross-session summary view.
    // The `content` field may be an array of typed blocks or (rarely) a
    // plain string. Join all text blocks into a single string so the
    // dashboard can preview the latest response.
    if let text = Self.extractText(from: message["content"]),
      !text.isEmpty
    {
      latestAssistantText = text
      latestAssistantAt = Date()
    }

    // Accumulate tokens (report total input = regular + cache tokens)
    totalTokensIn += inputTokens + cacheCreationTokens + cacheReadTokens
    totalTokensOut += outputTokens

    // Compute cost with cache-aware pricing
    let pricing = Self.pricing[latestModel] ?? Self.pricing["sonnet"]!
    let inputCost = Double(inputTokens) * pricing.inputPerToken
    let cacheCreateCost = Double(cacheCreationTokens) * pricing.cacheCreationPerToken
    let cacheReadCost = Double(cacheReadTokens) * pricing.cacheReadPerToken
    let outputCost = Double(outputTokens) * pricing.outputPerToken
    totalCost += inputCost + cacheCreateCost + cacheReadCost + outputCost

    return true
  }

  /// Parse `<local-command-stdout>` payloads from `/model` and `/context`
  /// slash-command captures. Returns true if the parse advanced any of
  /// `currentContextTokens` / `parsedMaxContextTokens`. These captures are
  /// the only place Claude Code records the active variant unambiguously
  /// (the JSONL `message.model` field never carries the `[1m]` suffix).
  private func parseUserLine(_ line: String) -> Bool {
    guard let data = line.data(using: .utf8),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = obj["type"] as? String, type == "user",
      let message = obj["message"] as? [String: Any],
      let content = message["content"] as? String,
      content.contains("<local-command-stdout>")
    else { return false }

    let stripped = Self.stripANSI(content)
    var changed = false

    // /model confirmation: "Set model to Opus 4.7 (1M context) (default)"
    if stripped.contains("Set model to") {
      let cap = stripped.contains("(1M context)") ? 1_000_000 : 200_000
      if cap != parsedMaxContextTokens {
        parsedMaxContextTokens = cap
        changed = true
      }
    }

    // /context output: "21.8k/200k tokens" / "25.4k/1m tokens"
    let ns = stripped as NSString
    if let match = Self.contextRegex.firstMatch(
      in: stripped, range: NSRange(location: 0, length: ns.length))
    {
      let cur = Self.parseTokenAmount(
        numStr: ns.substring(with: match.range(at: 1)),
        unit: ns.substring(with: match.range(at: 2)))
      let max = Self.parseTokenAmount(
        numStr: ns.substring(with: match.range(at: 3)),
        unit: ns.substring(with: match.range(at: 4)))
      if cur != currentContextTokens {
        currentContextTokens = cur
        changed = true
      }
      if max != parsedMaxContextTokens {
        parsedMaxContextTokens = max
        changed = true
      }
    }

    return changed
  }

  private static let ansiRegex: NSRegularExpression = {
    // ESC followed by `[`, optional params, terminator letter — covers the
    // CSI sequences Claude Code emits inside its captured stdout.
    return try! NSRegularExpression(pattern: "\u{001B}\\[[0-9;?]*[a-zA-Z]")
  }()

  private static let contextRegex: NSRegularExpression = {
    return try! NSRegularExpression(
      pattern: #"(\d+(?:\.\d+)?)([km])/(\d+(?:\.\d+)?)([km])\s+tokens"#,
      options: [.caseInsensitive])
  }()

  private static func stripANSI(_ s: String) -> String {
    let ns = s as NSString
    return ansiRegex.stringByReplacingMatches(
      in: s, range: NSRange(location: 0, length: ns.length), withTemplate: "")
  }

  private static func parseTokenAmount(numStr: String, unit: String) -> Int {
    let val = Double(numStr) ?? 0
    switch unit.lowercased() {
    case "k": return Int(val * 1_000)
    case "m": return Int(val * 1_000_000)
    default: return Int(val)
    }
  }

  /// Extract concatenated text from a JSONL `content` field. The field can
  /// be either a plain string (rare) or an array of `{"type": "text", ...}`
  /// blocks interleaved with tool_use / tool_result blocks — we keep only
  /// the text blocks so the summary view shows what Claude actually said.
  static func extractText(from content: Any?) -> String? {
    if let str = content as? String {
      return str.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let arr = content as? [[String: Any]] else { return nil }
    let parts = arr.compactMap { block -> String? in
      guard block["type"] as? String == "text" else { return nil }
      return block["text"] as? String
    }
    let joined = parts.joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return joined.isEmpty ? nil : joined
  }

  /// Mirror of Claude Code's `B2(model)` from its bundle: derive the
  /// context window cap from the model identifier alone. The JSONL never
  /// carries the `[1m]` suffix on its own (Claude Code strips it before
  /// writing), but `claude-opus-4-7` is always 1M regardless. We also
  /// honour the suffix when present (e.g. via /context or /model output
  /// flowing through `latestBareModel`).
  static func contextWindowCap(forModelId model: String) -> Int {
    let lower = model.lowercased()
    if lower.contains("[1m]") { return 1_000_000 }
    // Strip date suffixes like "-20251101" before family comparison
    // (matches Claude Code's `fI_(H)` normalization).
    let normalized = lower.replacingOccurrences(
      of: #"-\d{8}$"#, with: "", options: .regularExpression)
    if normalized == "claude-opus-4-7" { return 1_000_000 }
    return 200_000
  }

  /// Convert full model identifier (e.g. "claude-opus-4-6") to short name for pricing lookup.
  static func shortModelName(_ model: String) -> String {
    let lower = model.lowercased()
    if lower.contains("opus") { return "opus" }
    if lower.contains("haiku") { return "haiku" }
    if lower.contains("sonnet") { return "sonnet" }
    // Default to the raw string, but pricing lookup will fall back to sonnet
    return lower
  }
}
