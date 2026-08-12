import XCTest

@testable import DraftFrameKit

/// Exercises default-branch detection and the fast-forward pull against real
/// temp git repos: a "remote" repo and a clone of it acting as the project.
final class WorktreeManagerPullTests: XCTestCase {

  private var tempDir: URL!
  private var remoteDir: URL { tempDir.appendingPathComponent("remote") }
  private var localDir: URL { tempDir.appendingPathComponent("local") }

  override func setUpWithError() throws {
    tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("draftframe-pull-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: remoteDir, withIntermediateDirectories: true)
    git(["init", "-b", "main"], in: remoteDir)
    commit("one", in: remoteDir)
    git(["clone", remoteDir.path, localDir.path], in: tempDir)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: tempDir)
  }

  // MARK: - Helpers

  @discardableResult
  private func git(_ args: [String], in dir: URL) -> String {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    proc.arguments = ["-C", dir.path] + args
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    try? proc.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  private func commit(_ name: String, in dir: URL) {
    try? "content-\(name)".write(
      to: dir.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
    git(["add", "."], in: dir)
    git(
      ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", name],
      in: dir)
  }

  private func head(_ ref: String, in dir: URL) -> String {
    git(["rev-parse", ref], in: dir)
  }

  // MARK: - Default branch detection

  func testDetectsDefaultBranchFromRemoteHead() {
    XCTAssertEqual(WorktreeManager.shared.defaultBranch(repoRoot: localDir.path), "main")
  }

  func testDetectsLocalDefaultBranchWithoutRemote() {
    XCTAssertEqual(WorktreeManager.shared.defaultBranch(repoRoot: remoteDir.path), "main")
  }

  func testDetectsMasterFallback() {
    git(["branch", "-m", "main", "master"], in: remoteDir)
    XCTAssertEqual(WorktreeManager.shared.defaultBranch(repoRoot: remoteDir.path), "master")
  }

  func testReturnsNilOutsideGitRepo() {
    let plainDir = tempDir.appendingPathComponent("plain")
    try? FileManager.default.createDirectory(at: plainDir, withIntermediateDirectories: true)
    XCTAssertNil(WorktreeManager.shared.defaultBranch(repoRoot: plainDir.path))
  }

  // MARK: - Pull

  func testPullFastForwardsCheckedOutDefaultBranch() {
    commit("two", in: remoteDir)
    let error = WorktreeManager.shared.pullDefaultBranch(repoRoot: localDir.path, branch: "main")
    XCTAssertNil(error)
    XCTAssertEqual(head("main", in: localDir), head("main", in: remoteDir))
  }

  func testPullFastForwardsUncheckedOutBranchViaFetch() {
    // Move the local checkout off main; the pull must still advance main
    // without touching the checked-out branch.
    git(["checkout", "-b", "feature"], in: localDir)
    commit("two", in: remoteDir)
    let error = WorktreeManager.shared.pullDefaultBranch(repoRoot: localDir.path, branch: "main")
    XCTAssertNil(error)
    XCTAssertEqual(head("main", in: localDir), head("main", in: remoteDir))
    XCTAssertEqual(git(["branch", "--show-current"], in: localDir), "feature")
  }

  func testPullUpdatesDefaultBranchCheckedOutInWorktree() {
    // Check main out in a linked worktree and move the primary checkout off
    // it; the pull should run in the worktree and advance its working tree.
    let wtDir = tempDir.appendingPathComponent("wt-main")
    git(["checkout", "-b", "feature"], in: localDir)
    git(["worktree", "add", wtDir.path, "main"], in: localDir)
    commit("two", in: remoteDir)
    let error = WorktreeManager.shared.pullDefaultBranch(repoRoot: localDir.path, branch: "main")
    XCTAssertNil(error)
    XCTAssertEqual(head("main", in: localDir), head("main", in: remoteDir))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: wtDir.appendingPathComponent("two.txt").path))
  }

  func testPullReportsDivergedBranch() {
    commit("remote-change", in: remoteDir)
    commit("local-change", in: localDir)
    let error = WorktreeManager.shared.pullDefaultBranch(repoRoot: localDir.path, branch: "main")
    XCTAssertNotNil(error)
    // The local branch must be left where it was — no merge, no reset.
    XCTAssertNotEqual(head("main", in: localDir), head("main", in: remoteDir))
  }

  func testPullReportsUnreachableRemote() {
    try? FileManager.default.removeItem(at: remoteDir)
    let error = WorktreeManager.shared.pullDefaultBranch(repoRoot: localDir.path, branch: "main")
    XCTAssertNotNil(error)
  }
}
