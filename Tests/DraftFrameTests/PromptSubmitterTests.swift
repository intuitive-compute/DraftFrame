import XCTest

@testable import DraftFrameKit

@MainActor
final class PromptSubmitterTests: XCTestCase {

  /// Collects scheduled blocks so a test steps time by hand.
  private final class ManualClock {
    private(set) var delays: [TimeInterval] = []
    private var blocks: [@MainActor () -> Void] = []

    @MainActor func schedule(_ delay: TimeInterval, _ block: @escaping @MainActor () -> Void) {
      delays.append(delay)
      blocks.append(block)
    }

    /// Run the oldest scheduled block. Returns false when none is waiting.
    @MainActor @discardableResult func fireNext() -> Bool {
      guard !blocks.isEmpty else { return false }
      blocks.removeFirst()()
      return true
    }
  }

  private let timing = PromptSubmitter.Timing(enterDelay: 0.3, confirmTimeout: 5)
  private let sessionID = UUID()
  private var writes: [String] = []
  private var outcomes: [PromptSubmitter.Outcome] = []
  private var clock = ManualClock()

  override func setUp() async throws {
    writes = []
    outcomes = []
    clock = ManualClock()
  }

  private func submit(_ text: String = "fix the build") {
    let clock = self.clock
    PromptSubmitter.submit(
      text, sessionID: sessionID,
      write: { [weak self] in self?.writes.append($0) },
      timing: timing,
      schedule: { clock.schedule($0, $1) },
      completion: { [weak self] in self?.outcomes.append($0) })
  }

  private func post(_ new: SessionState, old: SessionState = .userInput, id: UUID? = nil) {
    SessionEvents.postStateChanged(id: id ?? sessionID, old: old, new: new)
  }

  func testTextAndEnterAreSeparateWrites() {
    submit()
    XCTAssertEqual(writes, ["fix the build"], "Enter must not ride along with the text")
    XCTAssertEqual(clock.delays, [0.3])

    clock.fireNext()
    XCTAssertEqual(writes, ["fix the build", "\r"])
    XCTAssertEqual(outcomes, [])
  }

  func testReportsStartedWhenSessionLeavesInputPrompt() {
    submit()
    clock.fireNext()  // Enter
    post(.generating)
    XCTAssertEqual(outcomes, [.started])

    // The confirmation timeout still fires later; it must not retry Enter
    // or report a second outcome.
    while clock.fireNext() {}
    XCTAssertEqual(writes, ["fix the build", "\r"])
    XCTAssertEqual(outcomes, [.started])
  }

  func testRetriesEnterOnceThenReportsFailure() {
    submit()
    clock.fireNext()  // Enter
    clock.fireNext()  // first timeout: retry Enter
    XCTAssertEqual(writes, ["fix the build", "\r", "\r"])
    XCTAssertEqual(outcomes, [])

    clock.fireNext()  // second timeout: give up
    XCTAssertEqual(writes, ["fix the build", "\r", "\r"])
    XCTAssertEqual(outcomes, [.notStarted])
    XCTAssertFalse(clock.fireNext())
  }

  func testRetriedEnterCanStillStartTheTurn() {
    submit()
    clock.fireNext()
    clock.fireNext()  // retry Enter
    post(.thinking)
    XCTAssertEqual(outcomes, [.started])
  }

  func testIgnoresOtherSessionsAndNonWorkingStates() {
    submit()
    post(.generating)  // before our Enter: not our turn
    clock.fireNext()
    post(.generating, id: UUID())
    post(.idle)
    post(.userInput, old: .idle)
    XCTAssertEqual(outcomes, [])
  }

  func testTypeThenEnterDoesNotWaitForATurn() {
    let clock = self.clock
    PromptSubmitter.typeThenEnter(
      "ls", write: { [weak self] in self?.writes.append($0) }, timing: timing,
      schedule: { clock.schedule($0, $1) })
    XCTAssertEqual(writes, ["ls"])
    clock.fireNext()
    XCTAssertEqual(writes, ["ls", "\r"])
    XCTAssertFalse(clock.fireNext())
  }
}
