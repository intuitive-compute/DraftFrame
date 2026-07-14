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
    "fable": ModelPricing(inputPerMillion: 10, outputPerMillion: 50),
    "opus": ModelPricing(inputPerMillion: 5, outputPerMillion: 25),
    "sonnet": ModelPricing(inputPerMillion: 3, outputPerMillion: 15),
    "haiku": ModelPricing(inputPerMillion: 1, outputPerMillion: 5),
  ]

  // MARK: - Public state

  typealias UpdateCallback = (
    _ cost: Double,
    _ tokensIn: Int,
    _ tokensOut: Int,
    _ model: String,
    _ contextTokens: Int,
    _ maxContextTokens: Int,
    _ lifetimeCost: Double,
    _ lifetimeTokensIn: Int,
    _ lifetimeTokensOut: Int
  ) -> Void

  /// Cost/tokens for the CURRENT claude run only (the session file we're
  /// watching now). Reset when we switch to a newer session file, so these
  /// mirror Claude Code's own `/usage` "Session" total. A DraftFrame tab can
  /// outlive many `claude` runs; without this reset the figures would balloon
  /// past `/usage`. See `lifetime*` for the cumulative figure across runs.
  private(set) var totalCost: Double = 0
  private(set) var totalTokensIn: Int = 0
  private(set) var totalTokensOut: Int = 0
  /// Cumulative cost/tokens across every run watched in this working
  /// directory. Never reset on a session switch.
  private(set) var lifetimeCost: Double = 0
  private(set) var lifetimeTokensIn: Int = 0
  private(set) var lifetimeTokensOut: Int = 0
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
  private let workingDirectory: String
  private var tailer: JSONLTailer?
  /// Usage-bearing messages already counted toward the totals. Claude Code
  /// writes one JSONL line per content block of a single API response, each
  /// repeating the same `message.id` and an identical `usage` block — so a
  /// text + tool_use turn appears two or three times. Keyed by
  /// "messageId|requestId" so usage is accumulated once per response.
  private var countedMessages: Set<String> = []

  // MARK: - Init

  /// Create a watcher for sessions launched from `workingDirectory`.
  /// The watcher locates the newest JSONL in the matching ~/.claude/projects/ subfolder
  /// and streams new assistant messages as they arrive.
  init(workingDirectory: String, onUpdate: @escaping UpdateCallback) {
    self.workingDirectory = workingDirectory
    self.onUpdate = onUpdate
    tailer = JSONLTailer(
      findLatest: { [weak self] in self?.findLatestJSONL() },
      onSwitch: { [weak self] in self?.resetRunTotals() },
      onLines: { [weak self] lines in self?.process(lines) }
    )
  }

  deinit {
    stop()
  }

  // MARK: - Public

  func stop() {
    tailer?.stop()
  }

  // MARK: - Resolution

  /// Encode a directory path the way Claude Code names its project folders:
  /// every character that isn't an ASCII letter or digit is replaced with `-`.
  /// So `/` and `.` both map to `-`, and `/.claude/` becomes `--claude-`.
  /// Matching this exactly is what lets us find the transcript for worktree
  /// sessions, which live under a dotted path like
  /// `.../.claude/worktrees/<name>`. A naive `/`-only replacement yields
  /// `-.claude-`, so `claudeProjectDir()` never resolves and cost/tokens stay
  /// at zero for every worktree session.
  static func encodePath(_ path: String) -> String {
    return String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
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

  // MARK: - Line processing

  /// A new session file is a new claude run: zero the current-run totals so
  /// the card mirrors `/usage`'s per-session figure. Lifetime totals persist.
  /// `countedMessages` is intentionally kept: the new file's message ids
  /// won't collide with the old file's, and keeping the set preserves correct
  /// lifetime dedup.
  private func resetRunTotals() {
    totalCost = 0
    totalTokensIn = 0
    totalTokensOut = 0
  }

  private func process(_ lines: [String]) {
    var didUpdate = false
    for line in lines where parseLine(line) {
      didUpdate = true
    }

    if didUpdate {
      let cost = totalCost
      let tIn = totalTokensIn
      let tOut = totalTokensOut
      let model = latestModel
      let ctx = currentContextTokens
      let maxCtx = parsedMaxContextTokens
      let lifeCost = lifetimeCost
      let lifeIn = lifetimeTokensIn
      let lifeOut = lifetimeTokensOut
      DispatchQueue.main.async { [weak self] in
        self?.onUpdate(cost, tIn, tOut, model, ctx, maxCtx, lifeCost, lifeIn, lifeOut)
      }
    }
  }

  /// Parse a single JSONL line, decoding the JSON exactly once and
  /// dispatching on the line's `type`. Returns true if any tracked state
  /// advanced. Internal for testing.
  func parseLine(_ line: String) -> Bool {
    guard let data = line.data(using: .utf8),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = obj["type"] as? String
    else { return false }
    switch type {
    case "assistant": return parseAssistant(obj)
    case "user": return parseUser(obj)
    default: return false
    }
  }

  /// Handle an assistant line. Returns true if it carried usable usage data.
  private func parseAssistant(_ obj: [String: Any]) -> Bool {
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
      // Derive the cap from the model id so it's correct from the very
      // first assistant turn. The JSONL never carries the `[1m]` suffix on
      // its own, but current 1M-window families (Fable 5, Opus 4.6+,
      // Sonnet 4.6) are matched by id. /context and /model captures may
      // upgrade this further.
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

    // Accumulate usage once per API response, not once per JSONL line —
    // multi-block responses repeat the same usage on every line (see
    // `countedMessages`). Lines without a message id can't be deduped, so
    // they are counted unconditionally.
    if let messageID = message["id"] as? String {
      let key = messageID + "|" + ((obj["requestId"] as? String) ?? "")
      if !countedMessages.insert(key).inserted {
        return true
      }
    }

    // Accumulate tokens (report total input = regular + cache tokens). The
    // current-run and lifetime totals advance together; only the run totals
    // get zeroed when we switch to a newer session file.
    let turnTokensIn = inputTokens + cacheCreationTokens + cacheReadTokens
    totalTokensIn += turnTokensIn
    totalTokensOut += outputTokens
    lifetimeTokensIn += turnTokensIn
    lifetimeTokensOut += outputTokens

    // Compute cost with cache-aware pricing
    let pricing = Self.pricing[latestModel] ?? Self.pricing["sonnet"]!
    let inputCost = Double(inputTokens) * pricing.inputPerToken
    let cacheCreateCost = Double(cacheCreationTokens) * pricing.cacheCreationPerToken
    let cacheReadCost = Double(cacheReadTokens) * pricing.cacheReadPerToken
    let outputCost = Double(outputTokens) * pricing.outputPerToken
    let turnCost = inputCost + cacheCreateCost + cacheReadCost + outputCost
    totalCost += turnCost
    lifetimeCost += turnCost

    return true
  }

  /// Parse `<local-command-stdout>` payloads from `/model` and `/context`
  /// slash-command captures. Returns true if the parse advanced any of
  /// `currentContextTokens` / `parsedMaxContextTokens`. These captures are
  /// the only place Claude Code records the active variant unambiguously
  /// (the JSONL `message.model` field never carries the `[1m]` suffix).
  private func parseUser(_ obj: [String: Any]) -> Bool {
    guard let message = obj["message"] as? [String: Any],
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

  /// Models whose context window is 1M tokens regardless of any `[1m]`
  /// suffix (Fable 5, Opus 4.6+, Sonnet 4.6). Haiku and older families
  /// stay at 200K.
  private static let oneMillionContextModels: Set<String> = [
    "claude-fable-5",
    "claude-opus-4-8",
    "claude-opus-4-7",
    "claude-opus-4-6",
    "claude-sonnet-4-6",
  ]

  /// Derive the context window cap from the model identifier alone. The
  /// JSONL never carries the `[1m]` suffix on its own (Claude Code strips
  /// it before writing), so current 1M-window families are matched by id.
  /// We also honour the suffix when present (e.g. via /context or /model
  /// output flowing through `latestBareModel`).
  static func contextWindowCap(forModelId model: String) -> Int {
    let lower = model.lowercased()
    if lower.contains("[1m]") { return 1_000_000 }
    // Strip date suffixes like "-20251101" before family comparison.
    let normalized = lower.replacingOccurrences(
      of: #"-\d{8}$"#, with: "", options: .regularExpression)
    if Self.oneMillionContextModels.contains(normalized) { return 1_000_000 }
    return 200_000
  }

  /// Convert full model identifier (e.g. "claude-opus-4-6") to short name for pricing lookup.
  static func shortModelName(_ model: String) -> String {
    let lower = model.lowercased()
    if lower.contains("fable") { return "fable" }
    if lower.contains("opus") { return "opus" }
    if lower.contains("haiku") { return "haiku" }
    if lower.contains("sonnet") { return "sonnet" }
    // Default to the raw string, but pricing lookup will fall back to sonnet
    return lower
  }
}
