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
    _ contextTokens: Int
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

  /// Most recent assistant text response parsed from the JSONL stream.
  /// Used by the dashboard's cross-session summary view. Nil until the
  /// session has produced its first text-bearing assistant message.
  private(set) var latestAssistantText: String?

  /// Timestamp of the most recent assistant text.
  private(set) var latestAssistantAt: Date?

  // MARK: - Private

  private let onUpdate: UpdateCallback
  private var fileHandle: FileHandle?
  private var dispatchSource: DispatchSourceFileSystemObject?
  private var fileOffset: UInt64 = 0
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
    try? fileHandle?.close()
    fileHandle = nil
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

    guard let fh = FileHandle(forReadingAtPath: path) else { return }
    self.fileHandle = fh

    // Process existing content first.
    processNewData(fh)

    // Watch for writes using DispatchSource.
    let fd = fh.fileDescriptor
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd,
      eventMask: [.write, .extend],
      queue: watchQueue
    )
    source.setEventHandler { [weak self] in
      guard let self = self, let fh = self.fileHandle else { return }
      self.processNewData(fh)
    }
    source.setCancelHandler { [weak self] in
      try? self?.fileHandle?.close()
      self?.fileHandle = nil
    }
    source.resume()
    dispatchSource = source

    // Also poll periodically as a fallback — some FSes don't reliably
    // deliver vnode events for every append.
    let timer = DispatchSource.makeTimerSource(queue: watchQueue)
    timer.schedule(deadline: .now() + 5, repeating: 5.0)
    timer.setEventHandler { [weak self] in
      guard let self = self, let fh = self.fileHandle else { return }
      self.processNewData(fh)
    }
    timer.resume()
    pollTimer = timer
  }

  private func processNewData(_ fh: FileHandle) {
    fh.seek(toFileOffset: fileOffset)
    let data = fh.readDataToEndOfFile()
    guard !data.isEmpty else { return }
    fileOffset = fh.offsetInFile

    guard let text = String(data: data, encoding: .utf8) else { return }
    let lines = text.components(separatedBy: "\n")
    var didUpdate = false

    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      if parseAssistantLine(trimmed) {
        didUpdate = true
      }
    }

    if didUpdate {
      let cost = totalCost
      let tIn = totalTokensIn
      let tOut = totalTokensOut
      let model = latestModel
      let ctx = currentContextTokens
      DispatchQueue.main.async { [weak self] in
        self?.onUpdate(cost, tIn, tOut, model, ctx)
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

    let inputTokens = usage["input_tokens"] as? Int ?? 0
    let outputTokens = usage["output_tokens"] as? Int ?? 0
    let cacheCreationTokens = usage["cache_creation_input_tokens"] as? Int ?? 0
    let cacheReadTokens = usage["cache_read_input_tokens"] as? Int ?? 0

    // Claude Code emits placeholder assistant messages with model="<synthetic>"
    // for tool-result wrappers and similar. Ignore those so we don't clobber
    // the real model id captured from a prior turn.
    if let model = message["model"] as? String, model != "<synthetic>" {
      latestModel = Self.shortModelName(model)
      latestBareModel = model
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
