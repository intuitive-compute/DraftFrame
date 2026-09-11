import XCTest

@testable import DraftFrameKit

/// `Session.repoName` feeds the repo label in the bottom right corner of each
/// session card. Managed worktrees resolve by path; everything else asks git
/// once and caches the answer.
@MainActor
final class SessionRepoNameTests: XCTestCase {

  private var tempDir: URL!
  private var repoDir: URL { tempDir.appendingPathComponent("MyRepo") }

  override func setUpWithError() throws {
    tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("draftframe-reponame-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
    git(["init", "-b", "main"], in: repoDir)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: tempDir)
  }

  private func git(_ args: [String], in dir: URL) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    proc.arguments = ["-C", dir.path] + args
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    try? proc.run()
    proc.waitUntilExit()
  }

  func testNoWorktreeHasNoRepoName() {
    let session = Session(name: "scratch")
    XCTAssertNil(session.repoRoot)
    XCTAssertNil(session.repoName)
  }

  func testManagedWorktreeResolvesByPathWithoutGit() {
    // The directory does not exist, so only the path-based resolution can
    // produce an answer.
    let session = Session(
      name: "fix-login",
      worktreePath: "/nonexistent/Projects/DraftFrame/.claude/worktrees/fix-login")
    XCTAssertEqual(session.repoRoot, "/nonexistent/Projects/DraftFrame")
    XCTAssertEqual(session.repoName, "DraftFrame")
  }

  func testPrimaryCheckoutResolvesThroughGit() {
    let session = Session(name: "main", worktreePath: repoDir.path)
    XCTAssertEqual(session.repoName, "MyRepo")
    XCTAssertEqual(
      URL(fileURLWithPath: session.repoRoot!).resolvingSymlinksInPath().path,
      repoDir.resolvingSymlinksInPath().path)
  }

  func testSubdirectoryOfRepoResolvesToRepoName() throws {
    let sub = repoDir.appendingPathComponent("Sources/Deep")
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    let session = Session(name: "feature", worktreePath: sub.path)
    XCTAssertEqual(session.repoName, "MyRepo")
  }

  func testPathOutsideAnyRepoHasNoRepoName() throws {
    let plain = tempDir.appendingPathComponent("plain")
    try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
    // Guard against a git repo enclosing the temp directory on the test host.
    let session = Session(name: "plain", worktreePath: plain.path)
    if WorktreeManager.repoRoot(at: tempDir.path) == nil {
      XCTAssertNil(session.repoName)
    }
  }

  func testChangingWorktreePathInvalidatesCache() {
    let session = Session(
      name: "a", worktreePath: "/x/Alpha/.claude/worktrees/a")
    XCTAssertEqual(session.repoName, "Alpha")
    session.worktreePath = "/x/Beta/.claude/worktrees/a"
    XCTAssertEqual(session.repoName, "Beta")
    session.worktreePath = nil
    XCTAssertNil(session.repoName)
  }

  func testDisplayNameSubstitutionUnchanged() {
    let session = Session(
      name: "main", worktreePath: "/x/Alpha/.claude/worktrees/main")
    XCTAssertEqual(session.displayName, "Alpha")
    let branch = Session(
      name: "fix-login", worktreePath: "/x/Alpha/.claude/worktrees/fix-login")
    XCTAssertEqual(branch.displayName, "fix-login")
  }
}
