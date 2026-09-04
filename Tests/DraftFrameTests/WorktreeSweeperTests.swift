import XCTest

@testable import DraftFrameKit

/// Covers the pure branch-to-merged-PR matching behind the sidebar's sweep.
final class WorktreeSweeperTests: XCTestCase {

  private let root = "/repo"
  private var managed: String { root + WorktreeManager.worktreeSubpath }

  private func worktree(
    _ path: String, branch: String, isBare: Bool = false
  ) -> WorktreeManager.Worktree {
    WorktreeManager.Worktree(path: path, branch: branch, head: "abc", isBare: isBare)
  }

  private func pr(_ number: Int, _ branch: String) -> MergedPR {
    MergedPR(number: number, headRefName: branch, url: "https://example.com/pull/\(number)")
  }

  // MARK: - Matching

  func testMatchesManagedWorktreesWhoseBranchHasMergedPR() {
    let merged = worktree("\(managed)/issue-1", branch: "issue-1")
    let open = worktree("\(managed)/issue-2", branch: "issue-2")
    let result = WorktreeSweeper.candidates(
      worktrees: [merged, open], mergedPRs: [pr(10, "issue-1"), pr(11, "unrelated")])

    XCTAssertEqual(result.count, 1)
    XCTAssertEqual(result.first?.worktree, merged)
    XCTAssertEqual(result.first?.prNumber, 10)
    XCTAssertEqual(result.first?.prURL, "https://example.com/pull/10")
    XCTAssertEqual(result.first?.name, "issue-1")
  }

  func testSkipsPrimaryCheckoutAndUnmanagedWorktrees() {
    let primary = worktree(root, branch: "main")
    let elsewhere = worktree("/tmp/other-checkout", branch: "feature")
    let result = WorktreeSweeper.candidates(
      worktrees: [primary, elsewhere], mergedPRs: [pr(1, "main"), pr(2, "feature")])
    XCTAssertTrue(result.isEmpty)
  }

  func testSkipsBareAndDetachedWorktrees() {
    let bare = worktree("\(managed)/bare", branch: "feature", isBare: true)
    let detached = worktree("\(managed)/detached", branch: "")
    let result = WorktreeSweeper.candidates(
      worktrees: [bare, detached], mergedPRs: [pr(1, "feature"), pr(2, "")])
    XCTAssertTrue(result.isEmpty)
  }

  func testNoMergedPRsYieldsNoCandidates() {
    let wt = worktree("\(managed)/issue-1", branch: "issue-1")
    XCTAssertTrue(WorktreeSweeper.candidates(worktrees: [wt], mergedPRs: []).isEmpty)
  }

  func testMatchesOnBranchNotDirectoryName() {
    // Slash branches live in dash-named directories.
    let wt = worktree("\(managed)/feat-login", branch: "feat/login")
    let result = WorktreeSweeper.candidates(
      worktrees: [wt], mergedPRs: [pr(5, "feat/login"), pr(6, "feat-login")])
    XCTAssertEqual(result.map(\.prNumber), [5])
  }

  func testPrefersHighestNumberedPRForBranch() {
    let wt = worktree("\(managed)/issue-1", branch: "issue-1")
    let result = WorktreeSweeper.candidates(
      worktrees: [wt], mergedPRs: [pr(12, "issue-1"), pr(7, "issue-1")])
    XCTAssertEqual(result.map(\.prNumber), [12])
  }

  func testPreservesWorktreeOrder() {
    let a = worktree("\(managed)/a", branch: "a")
    let b = worktree("\(managed)/b", branch: "b")
    let c = worktree("\(managed)/c", branch: "c")
    let result = WorktreeSweeper.candidates(
      worktrees: [a, b, c], mergedPRs: [pr(3, "c"), pr(1, "a")])
    XCTAssertEqual(result.map(\.name), ["a", "c"])
  }

  // MARK: - Parsing

  func testParsesGHPRListOutput() {
    let json = """
      [
        {"number": 23, "headRefName": "issue-22-persistent-state", "url": "https://x/pull/23"},
        {"number": 24, "headRefName": "fix/thing", "url": "https://x/pull/24"}
      ]
      """
    let parsed = WorktreeSweeper.parseMergedPRList(Data(json.utf8))
    XCTAssertEqual(
      parsed,
      [
        MergedPR(number: 23, headRefName: "issue-22-persistent-state", url: "https://x/pull/23"),
        MergedPR(number: 24, headRefName: "fix/thing", url: "https://x/pull/24"),
      ])
  }

  func testParseSkipsMalformedEntriesAndToleratesGarbage() {
    let json = """
      [{"number": 1, "headRefName": "ok", "url": "u"}, {"number": "2", "headRefName": "bad"}]
      """
    XCTAssertEqual(WorktreeSweeper.parseMergedPRList(Data(json.utf8)).map(\.number), [1])
    XCTAssertTrue(WorktreeSweeper.parseMergedPRList(Data()).isEmpty)
    XCTAssertTrue(WorktreeSweeper.parseMergedPRList(Data("not json".utf8)).isEmpty)
  }
}
