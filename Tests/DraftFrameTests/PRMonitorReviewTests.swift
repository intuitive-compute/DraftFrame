import XCTest

@testable import DraftFrameKit

final class PRMonitorReviewTests: XCTestCase {

  private func reviews(_ states: String...) -> [[String: Any]] {
    states.enumerated().map { i, state in
      ["state": state, "author": ["login": "reviewer\(i)"]]
    }
  }

  private func derive(
    _ decision: String?, _ latest: [[String: Any]] = [], state: PRState = .open
  ) -> PRReview? {
    PRMonitor.deriveReview(state: state, reviewDecision: decision, latestReviews: latest)
  }

  private func status(state: PRState = .open, review: PRReview?) -> PRStatus {
    PRStatus(
      number: 59, state: state, url: "https://example.com/pull/59",
      checks: [], rollup: .none, review: review)
  }

  // MARK: reviewDecision

  func testReviewDecisionValues() {
    XCTAssertEqual(derive("APPROVED"), .approved)
    XCTAssertEqual(derive("CHANGES_REQUESTED"), .changesRequested)
    XCTAssertNil(derive("REVIEW_REQUIRED"))
  }

  func testReviewDecisionWinsOverLatestReviews() {
    // A required review is still outstanding even though someone approved.
    XCTAssertNil(derive("REVIEW_REQUIRED", reviews("APPROVED")))
    XCTAssertEqual(derive("APPROVED", reviews("COMMENTED")), .approved)
    XCTAssertEqual(derive("CHANGES_REQUESTED", reviews("APPROVED")), .changesRequested)
  }

  func testUnknownReviewDecisionShowsNothing() {
    XCTAssertNil(derive("SOMETHING_NEW", reviews("APPROVED")))
  }

  // MARK: latestReviews fallback

  func testFallbackWhenReviewDecisionIsEmptyOrMissing() {
    XCTAssertEqual(derive("", reviews("APPROVED")), .approved)
    XCTAssertEqual(derive(nil, reviews("APPROVED")), .approved)
    XCTAssertEqual(derive("", reviews("CHANGES_REQUESTED")), .changesRequested)
  }

  func testFallbackChangeRequestOutranksApproval() {
    XCTAssertEqual(
      derive("", reviews("APPROVED", "CHANGES_REQUESTED", "APPROVED")), .changesRequested)
    XCTAssertEqual(derive("", reviews("CHANGES_REQUESTED", "APPROVED")), .changesRequested)
  }

  func testFallbackIgnoresCommentDismissedAndPending() {
    XCTAssertNil(derive("", reviews("COMMENTED")))
    XCTAssertNil(derive("", reviews("DISMISSED")))
    XCTAssertNil(derive("", reviews("PENDING")))
    XCTAssertNil(derive("", reviews("COMMENTED", "DISMISSED", "PENDING")))
    XCTAssertEqual(derive("", reviews("COMMENTED", "APPROVED", "DISMISSED")), .approved)
  }

  func testEmptyInputShowsNothing() {
    XCTAssertNil(derive(nil))
    XCTAssertNil(derive(""))
    XCTAssertNil(derive("", [[:]]))
  }

  // MARK: PR state

  func testMergedAndClosedShowNothing() {
    for state in [PRState.merged, .closed] {
      XCTAssertNil(derive("APPROVED", state: state))
      XCTAssertNil(derive("CHANGES_REQUESTED", state: state))
      XCTAssertNil(derive("", reviews("APPROVED"), state: state))
    }
  }

  // MARK: PRStatus

  func testContentEqualsDetectsReviewChange() {
    let none = status(review: nil)
    XCTAssertTrue(none.contentEquals(status(review: nil)))
    XCTAssertFalse(none.contentEquals(status(review: .approved)))
    XCTAssertFalse(status(review: .approved).contentEquals(status(review: .changesRequested)))
    XCTAssertTrue(status(review: .approved).contentEquals(status(review: .approved)))
  }

  func testReviewLeavesDisplayTextAlone() {
    XCTAssertEqual(status(review: .approved).displayText, status(review: nil).displayText)
  }

  func testStatesUseDistinctGlyphs() {
    XCTAssertNotEqual(PRReview.approved.glyph, PRReview.changesRequested.glyph)
    XCTAssertEqual(PRReview.approved.tooltip, "Approved by a reviewer")
    XCTAssertEqual(PRReview.changesRequested.tooltip, "A reviewer requested changes")
  }

  func testPollRequestsReviewFields() {
    let fields = PRMonitor.prViewFields.split(separator: ",")
    XCTAssertTrue(fields.contains("reviewDecision"))
    XCTAssertTrue(fields.contains("latestReviews"))
  }

  // MARK: Graph

  func testGraphPRNodeCarriesReview() {
    let id = UUID()
    func prNode(_ review: PRReview?) -> GraphNode? {
      let root = GraphSessionInput(
        id: id, displayName: "s", branch: "s", state: .idle, model: "m", cost: 0,
        pr: GraphPRInput(
          number: 59, text: "PR#59 failing", color: .red, isOpen: true, review: review))
      return GraphModelBuilder.build(root: root, agents: []).nodes
        .first { $0.kind == .pullRequest }
    }
    XCTAssertEqual(prNode(nil)?.detail, "")
    XCTAssertNil(prNode(nil)?.detailColor)
    XCTAssertEqual(prNode(.approved)?.detail, PRReview.approved.displayText)
    XCTAssertEqual(prNode(.approved)?.detailColor, PRReview.approved.color)
    XCTAssertEqual(prNode(.approved)?.subtitle, "PR#59 failing")
    XCTAssertEqual(prNode(.changesRequested)?.detail, PRReview.changesRequested.displayText)
  }
}
