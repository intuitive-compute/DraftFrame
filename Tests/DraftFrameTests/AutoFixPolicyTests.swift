import XCTest

@testable import DraftFrameKit

final class AutoFixPolicyTests: XCTestCase {

  /// A failing PR on commit "aaa" with auto-fix on and an idle, empty
  /// session; each test overrides what it is about.
  private func decide(
    enabled: Bool = true, prOpen: Bool = true,
    previous: PRRollup? = .pending, rollup: PRRollup = .failing,
    head: String? = "aaa", lastFired: String? = nil,
    pending: Bool = false, readiness: PromptReadiness = .ready
  ) -> AutoFixDecision {
    AutoFixPolicy.decide(
      AutoFixInput(
        enabled: enabled, prOpen: prOpen, previousRollup: previous, rollup: rollup,
        headCommit: head, lastFiredCommit: lastFired, hasPending: pending,
        readiness: readiness))
  }

  // MARK: When to fire

  func testFirstFailureFires() {
    XCTAssertEqual(decide(), .send)
    // Also on the first poll after launch, when there is no previous rollup.
    XCTAssertEqual(decide(previous: nil), .send)
  }

  func testSameCommitFailingAgainDoesNotFire() {
    // A rerun went pending and failed again on the commit already prompted.
    XCTAssertEqual(decide(previous: .pending, lastFired: "aaa"), .none)
    XCTAssertEqual(decide(previous: .failing, lastFired: "aaa"), .none)
  }

  func testNewCommitFailingFires() {
    XCTAssertEqual(decide(head: "bbb", lastFired: "aaa"), .send)
    // Even when the rollup never left failing between polls.
    XCTAssertEqual(decide(previous: .failing, head: "bbb", lastFired: "aaa"), .send)
  }

  func testNothingToDoUnlessFailing() {
    for rollup in [PRRollup.passing, .pending, .none] {
      XCTAssertEqual(decide(rollup: rollup), .none)
    }
    XCTAssertEqual(decide(enabled: false), .none)
    XCTAssertEqual(decide(prOpen: false), .none)
  }

  // MARK: Session not ready

  func testBusySessionDefers() {
    XCTAssertEqual(decide(readiness: .busy), .queue(.busy))
    XCTAssertEqual(decide(readiness: .notRunning), .queue(.notRunning))
  }

  func testUserDraftIsNeverAppendedTo() {
    XCTAssertEqual(decide(readiness: .draftInInput), .queue(.draftInInput))
    XCTAssertEqual(decide(pending: true, readiness: .draftInInput), .none)
  }

  func testOnlyOnePendingPrompt() {
    // Already waiting: later polls, and even a newer failing commit, do not
    // queue a second prompt.
    XCTAssertEqual(decide(pending: true, readiness: .busy), .none)
    XCTAssertEqual(decide(head: "bbb", lastFired: "aaa", pending: true, readiness: .busy), .none)
  }

  func testPendingPromptSendsOnceSessionIsReady() {
    XCTAssertEqual(decide(previous: .failing, pending: true, readiness: .ready), .send)
  }

  // MARK: Dropping a waiting prompt

  func testDeferredPromptDroppedWhenChecksRecover() {
    XCTAssertEqual(decide(rollup: .passing, pending: true), .cancel)
    // A rerun or new push in progress is not failing either.
    XCTAssertEqual(decide(rollup: .pending, pending: true, readiness: .busy), .cancel)
  }

  func testSettingOffCancels() {
    XCTAssertEqual(decide(enabled: false, pending: true, readiness: .busy), .cancel)
    XCTAssertEqual(decide(enabled: false, pending: true, readiness: .ready), .cancel)
  }

  func testClosedPRCancels() {
    XCTAssertEqual(decide(prOpen: false, pending: true), .cancel)
  }

  // MARK: No head commit reported

  func testWithoutCommitFallsBackToTransitionIntoFailing() {
    XCTAssertEqual(decide(previous: .pending, head: nil), .send)
    XCTAssertEqual(decide(previous: .failing, head: nil), .none)
    XCTAssertEqual(decide(previous: .failing, head: nil, readiness: .busy), .none)
    // A waiting prompt survives later polls that see failing -> failing.
    XCTAssertEqual(decide(previous: .failing, head: nil, pending: true, readiness: .busy), .none)
    XCTAssertEqual(decide(previous: .failing, head: nil, pending: true), .send)
  }

  // MARK: Prompt text

  func testPromptNamesFailingChecksAndHasNoTrailingReturn() {
    let status = PRStatus(
      number: 62, state: .open, url: "https://example.com/pull/62",
      checks: [
        PRCheck(name: "build", status: "COMPLETED", conclusion: .failure),
        PRCheck(name: "lint", status: "COMPLETED", conclusion: .success),
        PRCheck(name: "e2e", status: "COMPLETED", conclusion: .timedOut),
      ], rollup: .failing)
    let prompt = PRMonitor.autoFixPrompt(for: status)
    XCTAssertTrue(prompt.hasPrefix("CI is failing on PR #62 (build, e2e)."))
    XCTAssertFalse(prompt.contains("\r"))
    XCTAssertFalse(prompt.contains("\n"))
  }
}
