import XCTest

@testable import DraftFrameKit

final class PRMonitorRollupTests: XCTestCase {

  private func run(
    _ name: String, _ conclusion: String?, startedAt: String, workflow: String = "PR Hygiene",
    status: String = "COMPLETED"
  ) -> [String: Any] {
    var entry: [String: Any] = [
      "__typename": "CheckRun",
      "name": name,
      "status": status,
      "startedAt": startedAt,
      "workflowName": workflow,
    ]
    if let conclusion { entry["conclusion"] = conclusion }
    return entry
  }

  // Reproduction from issue #52: the concurrency group cancelled run
  // 41115661146 and run 41115672614 passed, but both are still in
  // statusCheckRollup for the head commit.
  private let supersededRollup: [[String: Any]] = [
    [
      "__typename": "CheckRun", "name": "PR title format", "status": "COMPLETED",
      "conclusion": "CANCELLED", "startedAt": "2026-10-30T18:00:01Z",
      "workflowName": "PR Hygiene",
    ],
    [
      "__typename": "CheckRun", "name": "PR body", "status": "COMPLETED",
      "conclusion": "CANCELLED", "startedAt": "2026-10-30T18:00:02Z",
      "workflowName": "PR Hygiene",
    ],
    [
      "__typename": "CheckRun", "name": "PR title format", "status": "COMPLETED",
      "conclusion": "SUCCESS", "startedAt": "2026-10-30T18:00:09Z",
      "workflowName": "PR Hygiene",
    ],
    [
      "__typename": "CheckRun", "name": "PR body", "status": "COMPLETED",
      "conclusion": "SUCCESS", "startedAt": "2026-10-30T18:00:10Z",
      "workflowName": "PR Hygiene",
    ],
  ]

  func testSupersededCancelledRunsAreDropped() {
    let checks = PRMonitor.parseChecks(supersededRollup)
    XCTAssertEqual(checks.map(\.name), ["PR title format", "PR body"])
    XCTAssertEqual(checks.map(\.conclusion), [.success, .success])
    XCTAssertEqual(PRMonitor.computeRollup(checks: checks), .passing)
  }

  func testLatestRunWinsRegardlessOfArrayOrder() {
    let checks = PRMonitor.parseChecks(supersededRollup.reversed())
    XCTAssertEqual(checks.map(\.conclusion), [.success, .success])
    XCTAssertEqual(PRMonitor.computeRollup(checks: checks), .passing)
  }

  func testLatestFailingRunStillFails() {
    let checks = PRMonitor.parseChecks([
      run("lint", "SUCCESS", startedAt: "2026-10-30T18:00:00Z"),
      run("lint", "FAILURE", startedAt: "2026-10-30T18:05:00Z"),
    ])
    XCTAssertEqual(checks.map(\.conclusion), [.failure])
    XCTAssertEqual(PRMonitor.computeRollup(checks: checks), .failing)
  }

  func testSameJobNameInDifferentWorkflowsStaysSeparate() {
    let checks = PRMonitor.parseChecks([
      run("test", "SUCCESS", startedAt: "2026-10-30T18:00:00Z", workflow: "iOS"),
      run("test", "FAILURE", startedAt: "2026-10-30T17:00:00Z", workflow: "macOS"),
    ])
    XCTAssertEqual(checks.count, 2)
    XCTAssertEqual(PRMonitor.computeRollup(checks: checks), .failing)
  }

  func testMissingTimestampsFavourLaterEntry() {
    let checks = PRMonitor.parseChecks([
      ["name": "build", "status": "COMPLETED", "conclusion": "CANCELLED"],
      ["name": "build", "status": "COMPLETED", "conclusion": "SUCCESS"],
    ])
    XCTAssertEqual(checks.map(\.conclusion), [.success])
  }

  func testCommitStatusUsesContextAsName() {
    let checks = PRMonitor.parseChecks([
      [
        "__typename": "StatusContext", "context": "ci/circleci", "state": "SUCCESS",
        "createdAt": "2026-10-30T18:00:00Z",
      ]
    ])
    XCTAssertEqual(checks.map(\.name), ["ci/circleci"])
  }

  func testLoneCancelledRunIsPendingNotFailing() {
    let checks = PRMonitor.parseChecks([
      run("lint", "CANCELLED", startedAt: "2026-10-30T18:00:00Z")
    ])
    XCTAssertEqual(PRMonitor.computeRollup(checks: checks), .pending)
  }

  func testInProgressRerunIsPending() {
    let checks = PRMonitor.parseChecks([
      run("lint", "CANCELLED", startedAt: "2026-10-30T18:00:00Z"),
      run("lint", nil, startedAt: "2026-10-30T18:01:00Z", status: "IN_PROGRESS"),
    ])
    XCTAssertEqual(PRMonitor.computeRollup(checks: checks), .pending)
  }

  func testEmptyRollupIsNone() {
    XCTAssertEqual(PRMonitor.computeRollup(checks: []), .none)
  }
}
