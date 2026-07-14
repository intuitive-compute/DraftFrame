import Foundation

/// Watches a Codex CLI rollout JSONL and accumulates token usage/cost.
///
/// Codex records every session under
/// `~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl` (local
/// date directories). Unlike Claude Code there is no per-project folder, so
/// the session for a working directory is found by reading each candidate
/// file's first line — a `session_meta` payload that carries the `cwd`.
///
/// Rollout lines are `{"timestamp": ..., "type": ..., "payload": {...}}`.
/// The lines we consume:
///   - `event_msg` / `token_count`: `info.total_token_usage` is CUMULATIVE
///     for the session, so totals are set from the latest event, not summed.
///   - `event_msg` / `agent_message`: the assistant's final message text.
///   - `event_msg` / `turn_started` etc.: turn lifecycle, driving the
///     session's working/idle state.
///   - `turn_context`: the model in effect for the turn (users can switch
///     mid-session with /model).
final class CodexUsageWatcher: UsageWatcher {

  // MARK: - Model pricing per token (derived from per-1M-token rates)

  private struct ModelPricing {
    let inputPerToken: Double
    let cachedInputPerToken: Double
    let outputPerToken: Double

    init(inputPerMillion: Double, cachedInputPerMillion: Double, outputPerMillion: Double) {
      self.inputPerToken = inputPerMillion / 1_000_000
      self.cachedInputPerToken = cachedInputPerMillion / 1_000_000
      self.outputPerToken = outputPerMillion / 1_000_000
    }
  }

  /// Longest-prefix-match table so dated/suffixed ids (`gpt-5.3-codex`,
  /// `gpt-5.4-mini-2026-05-01`) resolve to their family's rates. Cached
  /// input is uniformly 10% of input across the family.
  private static let pricingTable: [(prefix: String, rates: ModelPricing)] = [
    (
      "gpt-5.6-sol",
      ModelPricing(inputPerMillion: 5, cachedInputPerMillion: 0.5, outputPerMillion: 30)
    ),
    (
      "gpt-5.6-terra",
      ModelPricing(inputPerMillion: 2.5, cachedInputPerMillion: 0.25, outputPerMillion: 15)
    ),
    (
      "gpt-5.6-luna",
      ModelPricing(inputPerMillion: 1, cachedInputPerMillion: 0.1, outputPerMillion: 6)
    ),
    ("gpt-5.5", ModelPricing(inputPerMillion: 5, cachedInputPerMillion: 0.5, outputPerMillion: 30)),
    (
      "gpt-5.4-mini",
      ModelPricing(inputPerMillion: 0.75, cachedInputPerMillion: 0.075, outputPerMillion: 4.5)
    ),
    (
      "gpt-5.4-nano",
      ModelPricing(inputPerMillion: 0.2, cachedInputPerMillion: 0.02, outputPerMillion: 1.25)
    ),
    (
      "gpt-5.4", ModelPricing(inputPerMillion: 2.5, cachedInputPerMillion: 0.25, outputPerMillion: 15)
    ),
    (
      "gpt-5.3",
      ModelPricing(inputPerMillion: 1.75, cachedInputPerMillion: 0.175, outputPerMillion: 14)
    ),
    (
      "gpt-5.2",
      ModelPricing(inputPerMillion: 1.75, cachedInputPerMillion: 0.175, outputPerMillion: 14)
    ),
    (
      "gpt-5.1-codex-mini",
      ModelPricing(inputPerMillion: 0.25, cachedInputPerMillion: 0.025, outputPerMillion: 2)
    ),
    (
      "gpt-5.1",
      ModelPricing(inputPerMillion: 1.25, cachedInputPerMillion: 0.125, outputPerMillion: 10)
    ),
    (
      "gpt-5-mini",
      ModelPricing(inputPerMillion: 0.25, cachedInputPerMillion: 0.025, outputPerMillion: 2)
    ),
    (
      "gpt-5-nano",
      ModelPricing(inputPerMillion: 0.05, cachedInputPerMillion: 0.005, outputPerMillion: 0.4)
    ),
    (
      "gpt-5", ModelPricing(inputPerMillion: 1.25, cachedInputPerMillion: 0.125, outputPerMillion: 10)
    ),
  ]

  private static func pricing(for model: String) -> ModelPricing {
    let lower = model.lowercased()
    for entry in pricingTable where lower.hasPrefix(entry.prefix) {
      return entry.rates
    }
    // Unknown ids are most likely newer flagships — bill at the current
    // top-tier rate rather than silently undercounting.
    return pricingTable[0].rates
  }

  // MARK: - Public state

  /// Totals for the CURRENT codex run (the rollout file we're watching now).
  /// These mirror the cumulative `total_token_usage` of that file, so they
  /// reset naturally when we switch to a newer rollout. `input_tokens`
  /// already includes `cached_input_tokens`, matching how the Claude watcher
  /// reports input.
  private(set) var totalCost: Double = 0
  private(set) var totalTokensIn: Int = 0
  private(set) var totalTokensOut: Int = 0
  /// Figures carried over from earlier rollout files watched in this
  /// working directory. Lifetime totals = base + current run.
  private var lifetimeBaseCost: Double = 0
  private var lifetimeBaseTokensIn: Int = 0
  private var lifetimeBaseTokensOut: Int = 0
  /// Model id from the latest `turn_context`. Empty until the rollout's
  /// first turn — reported as-is so the session can keep a better source
  /// (launch preference, startup banner) in the meantime.
  private(set) var latestModel: String = ""
  /// Tokens fed to the model on the most recent API request
  /// (`last_token_usage.input_tokens`, cached included). Snapshot, not a sum.
  private(set) var currentContextTokens: Int = 0
  /// `model_context_window` from the latest token event. Zero means "no
  /// signal yet" — the Session keeps its default cap.
  private(set) var parsedMaxContextTokens: Int = 0

  /// Most recent assistant message, for the dashboard's summary view.
  private(set) var latestAssistantText: String?
  private(set) var latestAssistantAt: Date?

  /// Session state derived from the rollout's persisted turn lifecycle
  /// events (`turn_started` → generating, `turn_complete`/`turn_aborted` →
  /// waiting for input). Codex has no per-pid status file, and its TUI's
  /// idle footer varies across versions, so these events are the most
  /// reliable working/idle signal. Nil until the first turn event.
  private(set) var latestTurnState: SessionState?
  private var lastReportedTurnState: SessionState?

  // MARK: - Private

  private let onUpdate: SessionJSONLWatcher.UpdateCallback
  private let onTurnState: ((SessionState) -> Void)?
  private let workingDirectory: String
  /// Root of codex's session store (`~/.codex/sessions` in production).
  private let sessionsRoot: String
  private var tailer: JSONLTailer?
  /// First-line `cwd` per rollout path. A rollout's cwd never changes, so
  /// known misses are cached too (as a stored nil) to avoid re-reading
  /// every candidate on each rescan. Touched only on the tailer's queue.
  private var cwdCache: [String: String?] = [:]

  /// How many day directories (newest first) to scan for a matching rollout.
  /// A live session older than this window would be missed, but codex
  /// re-materializes resumed sessions with fresh writes, so recent days are
  /// where any active rollout lives.
  private static let maxDayDirs = 14

  // MARK: - Init

  /// `sessionsRoot` overrides the codex session store location for tests.
  /// `onTurnState` fires on the main queue when the rollout's turn events
  /// move the session between working and waiting-for-input; it's an init
  /// parameter (not a settable property) so the initial file replay can't
  /// race a later assignment.
  init(
    workingDirectory: String,
    sessionsRoot: String = NSHomeDirectory() + "/.codex/sessions",
    onTurnState: ((SessionState) -> Void)? = nil,
    onUpdate: @escaping SessionJSONLWatcher.UpdateCallback
  ) {
    self.workingDirectory = workingDirectory
    self.sessionsRoot = sessionsRoot
    self.onTurnState = onTurnState
    self.onUpdate = onUpdate
    tailer = JSONLTailer(
      findLatest: { [weak self] in self?.findLatestRollout() },
      onSwitch: { [weak self] in self?.rollRunIntoLifetimeBase() },
      onLines: { [weak self] lines in self?.process(lines) }
    )
  }

  deinit {
    stop()
  }

  func stop() {
    tailer?.stop()
  }

  // MARK: - Rollout discovery

  /// Day directories under the sessions root, newest first. The zero-padded
  /// `YYYY/MM/DD` names sort lexicographically in date order.
  private func recentDayDirs() -> [String] {
    let fm = FileManager.default
    func numericChildren(of dir: String) -> [String] {
      ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
        .filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        .sorted(by: >)
    }
    var dirs: [String] = []
    for year in numericChildren(of: sessionsRoot) {
      for month in numericChildren(of: "\(sessionsRoot)/\(year)") {
        for day in numericChildren(of: "\(sessionsRoot)/\(year)/\(month)") {
          dirs.append("\(sessionsRoot)/\(year)/\(month)/\(day)")
          if dirs.count >= Self.maxDayDirs { return dirs }
        }
      }
    }
    return dirs
  }

  /// Newest rollout file whose `session_meta.cwd` matches our directory.
  /// Modification dates come from one batched directory read per day dir
  /// rather than a stat per file — this runs on every rescan.
  private func findLatestRollout() -> String? {
    let fm = FileManager.default
    var newest: String?
    var newestDate = Date.distantPast

    for dir in recentDayDirs() {
      guard
        let entries = try? fm.contentsOfDirectory(
          at: URL(fileURLWithPath: dir),
          includingPropertiesForKeys: [.contentModificationDateKey],
          options: [.skipsHiddenFiles])
      else { continue }
      for url in entries {
        let name = url.lastPathComponent
        guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl"),
          let mod = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate,
          mod > newestDate,
          rolloutCwd(of: url.path) == workingDirectory
        else { continue }
        newestDate = mod
        newest = url.path
      }
    }
    return newest
  }

  /// Read the rollout's first line and return its `cwd`. Cached per path —
  /// including misses, since a written first line never changes.
  private func rolloutCwd(of path: String) -> String? {
    if let cached = cwdCache[path] {
      return cached
    }
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    // Read only until the first newline. session_meta can be large (it
    // embeds base instructions) but stays far below the cap in practice.
    var data = Data()
    while data.count < 512 * 1024 {
      let chunk = fh.readData(ofLength: 32 * 1024)
      if chunk.isEmpty { break }
      data.append(chunk)
      if chunk.contains(0x0A) { break }
    }
    guard let newline = data.firstIndex(of: 0x0A) else {
      // No complete first line yet (or ever) — don't cache, retry later.
      return nil
    }
    var cwd: String?
    if let obj = try? JSONSerialization.jsonObject(with: data[..<newline]) as? [String: Any] {
      if let payload = obj["payload"] as? [String: Any], obj["type"] as? String == "session_meta" {
        cwd = payload["cwd"] as? String
      } else {
        // Pre-envelope rollouts had the bare meta object as the first line.
        cwd = obj["cwd"] as? String
      }
    }
    cwdCache[path] = cwd
    return cwd
  }

  // MARK: - Line processing

  /// A newer rollout replaces the tracked one (a fresh codex run): the old
  /// file's cumulative totals roll into the lifetime base and the run
  /// totals restart from the new file's token events.
  private func rollRunIntoLifetimeBase() {
    lifetimeBaseCost += totalCost
    lifetimeBaseTokensIn += totalTokensIn
    lifetimeBaseTokensOut += totalTokensOut
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
      dispatchUpdate()
    }
    // Turn state is reported once per batch, not per line — an initial file
    // replay walks every historical turn and only the final state matters.
    reportTurnStateIfChanged()
  }

  private func dispatchUpdate() {
    let cost = totalCost
    let tIn = totalTokensIn
    let tOut = totalTokensOut
    let model = latestModel
    let ctx = currentContextTokens
    let maxCtx = parsedMaxContextTokens
    let lifeCost = lifetimeBaseCost + totalCost
    let lifeIn = lifetimeBaseTokensIn + totalTokensIn
    let lifeOut = lifetimeBaseTokensOut + totalTokensOut
    DispatchQueue.main.async { [weak self] in
      self?.onUpdate(cost, tIn, tOut, model, ctx, maxCtx, lifeCost, lifeIn, lifeOut)
    }
  }

  private func reportTurnStateIfChanged() {
    guard let state = latestTurnState, state != lastReportedTurnState else { return }
    lastReportedTurnState = state
    DispatchQueue.main.async { [weak self] in
      self?.onTurnState?(state)
    }
  }

  // MARK: - Parsing

  /// Parse a single rollout line. Returns true if any tracked state
  /// advanced. Internal for testing.
  func parseLine(_ line: String) -> Bool {
    // Fast-path reject: rollouts are dominated by multi-KB response_item
    // lines that carry nothing we track. A false positive here just falls
    // through to the real parse.
    guard line.contains("event_msg") || line.contains("turn_context") else { return false }

    guard let data = line.data(using: .utf8),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = obj["type"] as? String,
      let payload = obj["payload"] as? [String: Any]
    else { return false }

    switch type {
    case "turn_context":
      guard let model = payload["model"] as? String, !model.isEmpty, model != latestModel
      else { return false }
      latestModel = model
      return true
    case "event_msg":
      switch payload["type"] as? String {
      case "token_count": return parseTokenCount(payload)
      case "agent_message": return parseAgentMessage(payload)
      // Older codex versions named the turn events task_*.
      case "turn_started", "task_started":
        latestTurnState = .generating
        return false
      case "turn_complete", "turn_aborted", "task_complete", "task_aborted":
        latestTurnState = .userInput
        return false
      default: return false
      }
    default:
      return false
    }
  }

  private func parseTokenCount(_ payload: [String: Any]) -> Bool {
    // `info` is nullable on rate-limit-only events.
    guard let info = payload["info"] as? [String: Any],
      let total = info["total_token_usage"] as? [String: Any]
    else { return false }

    let input = total["input_tokens"] as? Int ?? 0
    let cached = total["cached_input_tokens"] as? Int ?? 0
    let output = total["output_tokens"] as? Int ?? 0

    // Codex writes synthetic events with zeroed usage (only `total_tokens`
    // set) when it marks the context window full, and totals are cumulative
    // — so an all-zero or regressing event is noise, not a reset.
    guard input + output > 0, input >= totalTokensIn, output >= totalTokensOut else {
      return false
    }

    totalTokensIn = input
    totalTokensOut = output

    // Cumulative totals allow computing cost directly. Priced at the
    // current model's rates; mid-session model switches skew this a little,
    // which matches the precision of the Claude watcher.
    let rates = Self.pricing(for: latestModel)
    totalCost =
      Double(input - cached) * rates.inputPerToken
      + Double(cached) * rates.cachedInputPerToken
      + Double(output) * rates.outputPerToken

    if let last = info["last_token_usage"] as? [String: Any],
      let lastInput = last["input_tokens"] as? Int, lastInput > 0
    {
      currentContextTokens = lastInput
    }

    if let window = info["model_context_window"] as? Int, window > 0 {
      parsedMaxContextTokens = window
    }

    return true
  }

  private func parseAgentMessage(_ payload: [String: Any]) -> Bool {
    guard let message = payload["message"] as? String,
      !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return false }
    latestAssistantText = message
    latestAssistantAt = Date()
    return true
  }
}
