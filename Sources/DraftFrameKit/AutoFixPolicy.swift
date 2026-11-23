import Foundation

/// Whether a session can take a prompt right now.
enum PromptReadiness: Equatable {
  /// At the agent's input prompt with nothing typed.
  case ready
  /// At the input prompt, but the user has typed something that was not
  /// submitted. Sending would append to, and submit, their text.
  case draftInInput
  /// Generating, thinking, or waiting on a permission prompt or question.
  case busy
  /// Not known to be at an agent's input prompt: a bare shell, an agent
  /// still starting up, or a Codex session that has not run a turn yet.
  case notRunning
}

/// Everything the auto-fix decision depends on, as plain values.
struct AutoFixInput {
  /// Auto-fix CI is on for the session's worktree.
  var enabled: Bool
  var prOpen: Bool = true
  /// Rollup at the previous poll; nil on the first poll. Only consulted when
  /// `headCommit` is unknown.
  var previousRollup: PRRollup?
  var rollup: PRRollup
  /// The PR's head commit, when `gh` reported one.
  var headCommit: String?
  /// The head commit auto-fix last sent a prompt for.
  var lastFiredCommit: String?
  /// A prompt is already waiting for the session to become ready.
  var hasPending: Bool
  var readiness: PromptReadiness
}

enum AutoFixDecision: Equatable {
  /// Nothing to do, including "keep the prompt that is already waiting".
  case none
  /// Send the prompt now.
  case send
  /// Remember one prompt and send it when the session is next ready.
  case queue(PromptReadiness)
  /// Drop the waiting prompt: checks recovered, the PR closed, or the
  /// setting was turned off.
  case cancel
}

/// The auto-fix rules, free of `gh`, timers, and the PTY so they can be unit
/// tested: one prompt per failing commit, never into a busy session or on
/// top of the user's own text, and at most one prompt waiting.
enum AutoFixPolicy {
  static func decide(_ input: AutoFixInput) -> AutoFixDecision {
    guard isWanted(input) else { return input.hasPending ? .cancel : .none }
    switch input.readiness {
    case .ready:
      return .send
    case .draftInInput, .busy, .notRunning:
      return input.hasPending ? .none : .queue(input.readiness)
    }
  }

  /// True when the failing checks have not had their prompt yet.
  private static func isWanted(_ input: AutoFixInput) -> Bool {
    guard input.enabled, input.prOpen, input.rollup == .failing else { return false }
    if let head = input.headCommit {
      // A rerun that fails again leaves the commit unchanged; a push moves it.
      return head != input.lastFiredCommit
    }
    // No commit to key on: fall back to the transition into failing.
    return input.hasPending || input.previousRollup != .failing
  }
}
