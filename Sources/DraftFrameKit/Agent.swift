import Foundation

/// A model choice offered in the "Model for New Sessions" menu. An empty
/// `id` means "launch without `--model` and let the CLI pick its default".
struct AgentModel {
  let id: String
  let displayName: String
}

/// The coding agent a session runs. DraftFrame launches the agent's CLI in
/// the session terminal and adapts status and usage tracking to it: Claude
/// Code exposes a per-pid status file and per-project JSONL transcripts,
/// Codex exposes rollout JSONLs under `~/.codex/sessions` and its state is
/// inferred from the PTY stream.
enum AgentKind: String, CaseIterable {
  case claude
  case codex

  var displayName: String {
    switch self {
    case .claude: return "Claude Code"
    case .codex: return "Codex"
    }
  }

  /// CLI binary name. Raw values intentionally match the binary names, and
  /// this doubles as the last-resort command when no absolute path resolves.
  var binaryName: String { rawValue }

  /// Install locations to try when the binary isn't on the composed PATH.
  var fallbackBinaryPaths: [String] {
    let home = NSHomeDirectory() as NSString
    switch self {
    case .claude:
      return [
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        home.appendingPathComponent(".claude/local/claude"),
        home.appendingPathComponent(".local/bin/claude"),
      ]
    case .codex:
      // ~/.local/bin is the official installer's default; Homebrew cask and
      // npm -g both land in the brew prefixes.
      return [
        home.appendingPathComponent(".local/bin/codex"),
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
      ]
    }
  }

  /// Models offered for new sessions. Raw ids are what `--model` receives.
  /// Both CLIs also accept family aliases that auto-track the newest release
  /// (e.g. `opus`); switch an entry's id to one of those to stop pinning.
  var models: [AgentModel] {
    switch self {
    case .claude:
      return [
        AgentModel(id: "", displayName: "Default"),
        AgentModel(id: "claude-opus-4-8", displayName: "Opus 4.8"),
        AgentModel(id: "claude-opus-4-7", displayName: "Opus 4.7"),
        AgentModel(id: "claude-opus-4-6", displayName: "Opus 4.6"),
        AgentModel(id: "claude-sonnet-4-6", displayName: "Sonnet 4.6"),
        AgentModel(id: "claude-haiku-4-5", displayName: "Haiku 4.5"),
      ]
    case .codex:
      return [
        AgentModel(id: "", displayName: "Default"),
        AgentModel(id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol"),
        AgentModel(id: "gpt-5.6-terra", displayName: "GPT-5.6 Terra"),
        AgentModel(id: "gpt-5.6-luna", displayName: "GPT-5.6 Luna"),
        AgentModel(id: "gpt-5.5", displayName: "GPT-5.5"),
        AgentModel(id: "gpt-5.4", displayName: "GPT-5.4"),
      ]
    }
  }

  /// What the session card shows before the agent's transcript names the
  /// model in use: the launch model when one is pinned, otherwise a
  /// placeholder. The codex placeholder is deliberately generic — its
  /// default model changes release to release, and showing a guessed id
  /// that disagrees with the TUI banner reads as a bug.
  func initialCardModel(forLaunchModelId id: String) -> String {
    switch self {
    case .claude:
      return id.isEmpty ? "sonnet" : SessionJSONLWatcher.shortModelName(id)
    case .codex:
      return id.isEmpty ? "codex" : id
    }
  }

  private var modelDefaultsKey: String {
    switch self {
    // Predates AgentKind — keep the key so existing preferences carry over.
    case .claude: return "DFClaudeModel"
    case .codex: return "DFCodexModel"
    }
  }

  /// Persisted model id new sessions of this agent launch with. Empty means
  /// the CLI's own default.
  var preferredModelId: String {
    get { UserDefaults.standard.string(forKey: modelDefaultsKey) ?? "" }
    nonmutating set { UserDefaults.standard.set(newValue, forKey: modelDefaultsKey) }
  }

  /// Full command line that launches this agent with the given model
  /// (empty = the CLI's own default) and, optionally, an initial prompt the
  /// agent starts working on immediately. Both CLIs take the prompt as a
  /// positional argument.
  func launchCommand(binPath: String, modelId: String, initialPrompt: String? = nil) -> String {
    var cmd = modelId.isEmpty ? binPath : "\(binPath) --model \(modelId)"
    if let prompt = initialPrompt, !prompt.isEmpty {
      cmd += " \(shellSingleQuote(prompt))"
    }
    return cmd
  }
}

/// Persisted preference for which agent new sessions launch.
enum AgentPreference {
  private static let key = "DFAgent"

  static var current: AgentKind {
    get {
      let raw = UserDefaults.standard.string(forKey: key) ?? ""
      return AgentKind(rawValue: raw) ?? .claude
    }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
  }
}

/// Common interface over the per-agent transcript watchers that feed a
/// session's cost/token figures and latest-response preview.
protocol UsageWatcher: AnyObject {
  var latestAssistantText: String? { get }
  var latestAssistantAt: Date? { get }
  func stop()
}

extension SessionJSONLWatcher: UsageWatcher {}
