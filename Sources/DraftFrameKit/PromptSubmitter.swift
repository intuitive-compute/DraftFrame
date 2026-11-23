import Foundation

/// Submits a prompt to an agent session the way a typed submission arrives:
/// the text in one write, then Enter in a write of its own.
///
/// Both agent TUIs treat a burst of input as a paste, and a carriage return
/// inside the burst lands in the input box as a line break instead of
/// submitting. Sending Enter separately, after the text has been taken, is
/// what makes it a submission.
@MainActor
final class PromptSubmitter {
  enum Outcome: Equatable {
    /// The session left its input prompt: a turn started.
    case started
    /// Text and Enter were written, Enter was retried once, and the session
    /// still never started a turn. The text may be sitting in the input box.
    case notStarted
  }

  struct Timing {
    /// Gap between the text and Enter, long enough for the TUI to stop
    /// reading the text as part of a paste burst.
    var enterDelay: TimeInterval = 0.3
    /// How long to wait for a turn to start after each Enter.
    var confirmTimeout: TimeInterval = 5
  }

  /// Runs `block` after `delay` seconds on the main actor. Injected so tests
  /// can step time by hand.
  typealias Scheduler = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void

  static let mainQueueScheduler: Scheduler = { delay, block in
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      MainActor.assumeIsolated { block() }
    }
  }

  /// Write `text`, then Enter as a separate write. Does not check that a
  /// turn started; use `submit` when the caller needs to know.
  static func typeThenEnter(
    _ text: String,
    write: @escaping @MainActor (String) -> Void,
    timing: Timing = Timing(),
    schedule: Scheduler = mainQueueScheduler,
    then: (@MainActor () -> Void)? = nil
  ) {
    write(text)
    schedule(timing.enterDelay) {
      write("\r")
      then?()
    }
  }

  /// Submit `text` to the session and report whether a turn started, judged
  /// by the session leaving its input prompt (`.sessionStateDidChange` to a
  /// working or needs-attention state). If nothing happens within
  /// `confirmTimeout`, Enter is sent once more before giving up.
  static func submit(
    _ text: String,
    sessionID: UUID,
    write: @escaping @MainActor (String) -> Void,
    timing: Timing = Timing(),
    schedule: @escaping Scheduler = mainQueueScheduler,
    completion: @escaping @MainActor (Outcome) -> Void
  ) {
    let submission = PromptSubmitter(
      sessionID: sessionID, write: write, timing: timing, schedule: schedule,
      completion: completion)
    submission.run(text)
  }

  private let sessionID: UUID
  private let write: @MainActor (String) -> Void
  private let timing: Timing
  private let schedule: Scheduler
  private var completion: (@MainActor (Outcome) -> Void)?
  private var observer: NSObjectProtocol?
  private var enterSent = false

  private init(
    sessionID: UUID,
    write: @escaping @MainActor (String) -> Void,
    timing: Timing,
    schedule: @escaping Scheduler,
    completion: @escaping @MainActor (Outcome) -> Void
  ) {
    self.sessionID = sessionID
    self.write = write
    self.timing = timing
    self.schedule = schedule
    self.completion = completion
  }

  private func run(_ text: String) {
    // The observer block holds `self` until `finish`, which keeps the
    // submission alive without a registry.
    observer = NotificationCenter.default.addObserver(
      forName: .sessionStateDidChange, object: nil, queue: nil
    ) { note in
      let change = SessionEvents.stateChange(note)
      MainActor.assumeIsolated { self.stateChanged(change) }
    }
    Self.typeThenEnter(text, write: write, timing: timing, schedule: schedule) {
      self.enterSent = true
      self.awaitTurn(retriesLeft: 1)
    }
  }

  private func stateChanged(_ change: (id: UUID, old: SessionState, new: SessionState)?) {
    // A change before our Enter is someone else's turn, not ours.
    guard enterSent, let change, change.id == sessionID else { return }
    switch change.new {
    case .generating, .thinking, .needsAttention: finish(.started)
    case .userInput, .idle: break
    }
  }

  private func awaitTurn(retriesLeft: Int) {
    schedule(timing.confirmTimeout) {
      guard self.completion != nil else { return }
      guard retriesLeft > 0 else {
        self.finish(.notStarted)
        return
      }
      self.write("\r")
      self.awaitTurn(retriesLeft: retriesLeft - 1)
    }
  }

  private func finish(_ outcome: Outcome) {
    guard let completion else { return }
    self.completion = nil
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
    completion(outcome)
  }
}
