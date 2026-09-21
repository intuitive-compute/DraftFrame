import Foundation

// MARK: - Sub-agent records

/// One sub-agent dispatched by a Claude Code session, reconstructed from its
/// transcript at `<claude project dir>/<sessionId>/subagents/agent-<id>.jsonl`.
/// This is the ground truth for "child sessions run by the flow": the parent
/// transcript does not reliably record dispatches (skills and workflows
/// spawn agents without a tool_use block), but every agent writes its own
/// transcript. See docs/graph-engineering.md.
struct SubagentRecord: Equatable {
  enum Status: Equatable {
    /// Transcript was written in the last minute and has not ended.
    case running
    /// Last record is a text-only assistant turn: the agent returned.
    case completed
    /// Ended mid-turn and has gone quiet: interrupted or killed.
    case stopped
  }

  let agentID: String
  let transcriptPath: String
  /// Agent type as Claude Code attributes it (general-purpose, Explore, …).
  let agentType: String?
  /// Skill that dispatched the agent (code-review, hardened-fix-pipeline, …).
  let skill: String?
  let model: String
  /// First line of the dispatch prompt, truncated.
  let promptSummary: String
  let startedAt: Date
  let lastActivityAt: Date
  let status: Status
  let cost: Double
  let tokensIn: Int
  let tokensOut: Int
  let turns: Int

  var displayTitle: String {
    if let type = agentType, !type.isEmpty { return type }
    return "agent"
  }
}

// MARK: - Scanner

/// Parses sub-agent transcripts. Pure functions; no main-actor state.
enum SubagentScanner {
  /// Agents quiet for longer than this are no longer considered running.
  static let runningWindow: TimeInterval = 60

  /// Directory holding a session's sub-agent transcripts, or nil if none.
  static func subagentsDir(projectDir: String, sessionID: String) -> String? {
    let dir = projectDir + "/" + sessionID + "/subagents"
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue
    else { return nil }
    return dir
  }

  /// Session id of the newest transcript in a Claude project directory,
  /// mirroring the rule `SessionJSONLWatcher` uses to pick the live run.
  static func newestSessionID(projectDir: String) -> String? {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: projectDir) else { return nil }
    var newest: (String, Date)?
    for name in names where name.hasSuffix(".jsonl") {
      let path = projectDir + "/" + name
      guard let attrs = try? fm.attributesOfItem(atPath: path),
        let mod = attrs[.modificationDate] as? Date
      else { continue }
      if newest == nil || mod > newest!.1 {
        newest = (String(name.dropLast(".jsonl".count)), mod)
      }
    }
    return newest?.0
  }

  /// Every agent transcript in `dir`, parsed, oldest first.
  static func scan(dir: String, now: Date = Date()) -> [SubagentRecord] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
    return
      names
      .filter { $0.hasPrefix("agent-") && $0.hasSuffix(".jsonl") }
      .compactMap { parse(path: dir + "/" + $0, now: now) }
      .sorted { $0.startedAt < $1.startedAt }
  }

  /// Parse one transcript. Returns nil when the file is unreadable or has no
  /// records. Internal for tests.
  static func parse(path: String, now: Date = Date()) -> SubagentRecord? {
    guard let data = FileManager.default.contents(atPath: path),
      let text = String(data: data, encoding: .utf8)
    else { return nil }
    return parse(transcript: text, path: path, now: now)
  }

  static func parse(transcript: String, path: String, now: Date = Date()) -> SubagentRecord? {
    var agentID = (path as NSString).lastPathComponent
    agentID = String(agentID.dropFirst("agent-".count).dropLast(".jsonl".count))

    var agentType: String?
    var skill: String?
    var model = ""
    var promptSummary = ""
    /// Some dispatchers (forks) mark the whole prompt as meta; used when no
    /// ordinary user message ever appears.
    var metaPromptSummary = ""
    var startedAt: Date?
    var lastActivityAt: Date?
    var cost: Double = 0
    var tokensIn = 0
    var tokensOut = 0
    var turns = 0
    var countedMessages = Set<String>()
    var lastAssistantEndedTurn = false
    var sawAnyRecord = false

    for rawLine in transcript.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let lineData = rawLine.data(using: .utf8),
        let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
      else { continue }
      sawAnyRecord = true

      if let ts = (obj["timestamp"] as? String).flatMap(parseTimestamp) {
        if startedAt == nil { startedAt = ts }
        lastActivityAt = ts
      }
      if agentType == nil, let t = obj["attributionAgent"] as? String, !t.isEmpty {
        agentType = t
      }
      if skill == nil, let s = obj["attributionSkill"] as? String, !s.isEmpty {
        skill = s
      }

      guard let type = obj["type"] as? String,
        let message = obj["message"] as? [String: Any]
      else { continue }

      switch type {
      case "user":
        if promptSummary.isEmpty,
          let text = SessionJSONLWatcher.extractText(from: message["content"])
        {
          let isMeta = obj["isMeta"] as? Bool == true
          let summary = summarize(prompt: text)
          if !isMeta, !summary.isEmpty {
            promptSummary = summary
          } else if isMeta, metaPromptSummary.isEmpty, !summary.hasPrefix("<") {
            metaPromptSummary = summary
          }
        }
        lastAssistantEndedTurn = false

      case "assistant":
        if let m = message["model"] as? String, m != "<synthetic>" {
          model = SessionJSONLWatcher.shortModelName(m)
        }
        let hasToolUse = Self.containsToolUse(message["content"])
        lastAssistantEndedTurn = !hasToolUse
        guard let usage = message["usage"] as? [String: Any] else { continue }
        let key =
          ((message["id"] as? String) ?? UUID().uuidString) + "|"
          + ((obj["requestId"] as? String) ?? "")
        guard countedMessages.insert(key).inserted else { continue }
        turns += 1
        let input = usage["input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        let cacheCreate = usage["cache_creation_input_tokens"] as? Int ?? 0
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        tokensIn += input + cacheCreate + cacheRead
        tokensOut += output
        let pricing =
          SessionJSONLWatcher.pricing[model] ?? SessionJSONLWatcher.pricing["sonnet"]!
        cost +=
          Double(input) * pricing.inputPerToken + Double(output) * pricing.outputPerToken
          + Double(cacheCreate) * pricing.cacheCreationPerToken
          + Double(cacheRead) * pricing.cacheReadPerToken

      default:
        continue
      }
    }

    guard sawAnyRecord, let started = startedAt else { return nil }
    let last = lastActivityAt ?? started

    let status: SubagentRecord.Status
    if lastAssistantEndedTurn {
      status = .completed
    } else if now.timeIntervalSince(last) <= runningWindow {
      status = .running
    } else {
      status = .stopped
    }

    return SubagentRecord(
      agentID: agentID, transcriptPath: path, agentType: agentType, skill: skill,
      model: model.isEmpty ? "unknown" : model,
      promptSummary: promptSummary.isEmpty ? metaPromptSummary : promptSummary,
      startedAt: started, lastActivityAt: last, status: status,
      cost: cost, tokensIn: tokensIn, tokensOut: tokensOut, turns: turns)
  }

  // MARK: Helpers

  private static func containsToolUse(_ content: Any?) -> Bool {
    guard let blocks = content as? [[String: Any]] else { return false }
    return blocks.contains { $0["type"] as? String == "tool_use" }
  }

  /// First non-empty line of the prompt, without leading role boilerplate,
  /// capped for a node subtitle.
  static func summarize(prompt: String, limit: Int = 90) -> String {
    let firstLine =
      prompt.split(separator: "\n", omittingEmptySubsequences: true)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .first { !$0.isEmpty } ?? ""
    if firstLine.count <= limit { return firstLine }
    return String(firstLine.prefix(limit - 1)) + "…"
  }

  // ISO8601DateFormatter is documented thread-safe; the annotation only
  // silences the strict-concurrency inventory warning.
  private nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()
  private nonisolated(unsafe) static let isoFormatterNoFraction: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
  }()

  static func parseTimestamp(_ s: String) -> Date? {
    isoFormatter.date(from: s) ?? isoFormatterNoFraction.date(from: s)
  }
}

// MARK: - Live source

extension Notification.Name {
  /// A session's sub-agent set changed. userInfo carries `SessionEvents.sessionIDKey`.
  static let sessionGraphDidChange = Notification.Name("DFSessionGraphDidChange")
}

/// Caches sub-agent scans per DraftFrame session and refreshes them off the
/// main thread. Transcripts run to a few MB each and a coordinator can spawn
/// dozens, so nothing here parses on the main actor.
@MainActor
final class SessionGraphSource {
  static let shared = SessionGraphSource()

  private struct Cached {
    var records: [SubagentRecord]
    /// Per-file (size, mtime) fingerprints from the last scan.
    var fingerprints: [String: (UInt64, Date)]
    var sessionID: String?
  }

  private var cache: [UUID: Cached] = [:]
  private var inFlight: Set<UUID> = []
  private let queue = DispatchQueue(label: "draftframe.session-graph", qos: .utility)

  private init() {}

  /// Last known sub-agents for a session; empty until the first scan lands.
  func records(for sessionID: UUID) -> [SubagentRecord] {
    cache[sessionID]?.records ?? []
  }

  /// Claude Code session id the graph is currently showing for this tab.
  func agentSessionID(for sessionID: UUID) -> String? {
    cache[sessionID]?.sessionID
  }

  /// Rescan in the background if anything on disk changed. Posts
  /// `.sessionGraphDidChange` when the record set differs.
  func refresh(session: Session) {
    guard session.agent == .claude, !inFlight.contains(session.id) else { return }
    let workingDirectory = session.worktreePath ?? FileManager.default.currentDirectoryPath
    let sessionID = session.id
    let previous = cache[sessionID]
    inFlight.insert(sessionID)

    queue.async { [weak self] in
      let result = Self.scanOnDisk(workingDirectory: workingDirectory, previous: previous)
      DispatchQueue.main.async {
        guard let strong = self else { return }
        MainActor.assumeIsolated {
          strong.apply(result, previous: previous, sessionID: sessionID)
        }
      }
    }
  }

  private func apply(_ result: Cached?, previous: Cached?, sessionID: UUID) {
    inFlight.remove(sessionID)
    guard let result else { return }
    let changed = previous?.records != result.records || previous?.sessionID != result.sessionID
    cache[sessionID] = result
    if changed {
      NotificationCenter.default.post(
        name: .sessionGraphDidChange, object: nil,
        userInfo: [SessionEvents.sessionIDKey: sessionID])
    }
  }

  func forget(sessionID: UUID) {
    cache.removeValue(forKey: sessionID)
  }

  /// Returns nil when nothing changed since `previous`, so the caller can
  /// skip the notification. Runs on the scan queue.
  private nonisolated static func scanOnDisk(workingDirectory: String, previous: Cached?) -> Cached?
  {
    guard
      let projectDir = SessionJSONLWatcher.claudeProjectDir(forWorkingDirectory: workingDirectory),
      let agentSession = SubagentScanner.newestSessionID(projectDir: projectDir)
    else {
      return previous == nil ? Cached(records: [], fingerprints: [:], sessionID: nil) : nil
    }
    guard let dir = SubagentScanner.subagentsDir(projectDir: projectDir, sessionID: agentSession)
    else {
      if previous?.sessionID == agentSession, previous?.records.isEmpty == true { return nil }
      return Cached(records: [], fingerprints: [:], sessionID: agentSession)
    }

    let fm = FileManager.default
    var fingerprints: [String: (UInt64, Date)] = [:]
    for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? []
    where name.hasPrefix("agent-") && name.hasSuffix(".jsonl") {
      let path = dir + "/" + name
      guard let attrs = try? fm.attributesOfItem(atPath: path) else { continue }
      let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
      let mod = attrs[.modificationDate] as? Date ?? .distantPast
      fingerprints[path] = (size, mod)
    }

    // Unchanged files reuse their parsed record, except running ones whose
    // status can flip to stopped purely by time passing.
    let now = Date()
    var records: [SubagentRecord] = []
    let previousByPath = Dictionary(
      uniqueKeysWithValues: (previous?.records ?? []).map { ($0.transcriptPath, $0) })
    for (path, print) in fingerprints {
      if previous?.sessionID == agentSession,
        let old = previous?.fingerprints[path], old == print,
        let record = previousByPath[path], record.status != .running
      {
        records.append(record)
      } else if let record = SubagentScanner.parse(path: path, now: now) {
        records.append(record)
      }
    }
    records.sort { $0.startedAt < $1.startedAt }
    return Cached(records: records, fingerprints: fingerprints, sessionID: agentSession)
  }
}
