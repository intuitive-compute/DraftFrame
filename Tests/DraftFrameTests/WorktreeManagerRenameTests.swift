import XCTest

@testable import DraftFrameKit

/// Exercises worktree renaming against a real temp git repo with a
/// draftframe-managed worktree under `.claude/worktrees/`.
final class WorktreeManagerRenameTests: XCTestCase {

  private var tempDir: URL!
  private var repoDir: URL { tempDir.appendingPathComponent("repo") }
  private var worktreesDir: URL {
    repoDir.appendingPathComponent(".claude/worktrees")
  }

  override func setUpWithError() throws {
    tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("draftframe-rename-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
    git(["init", "-b", "main"], in: repoDir)
    commit("one", in: repoDir)
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

  private func makeWorktree(named name: String) -> WorktreeManager.Worktree {
    let path = worktreesDir.appendingPathComponent(name).path
    git(["worktree", "add", "-b", name, path, "main"], in: repoDir)
    let listed = WorktreeManager.shared.listWorktrees(repoRoot: repoDir.path)
      .first { $0.branch == name }
    return listed
      ?? WorktreeManager.Worktree(path: path, branch: name, head: "", isBare: false)
  }

  // MARK: - Rename

  func testRenameMovesDirectoryAndRenamesBranch() throws {
    let wt = makeWorktree(named: "old-name")
    let newPath = try WorktreeManager.shared.renameWorktree(
      repoRoot: repoDir.path, worktree: wt, newName: "new-name")

    XCTAssertEqual(newPath, worktreesDir.appendingPathComponent("new-name").path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: newPath))
    XCTAssertFalse(FileManager.default.fileExists(atPath: wt.path))
    XCTAssertEqual(
      git(["branch", "--show-current"], in: URL(fileURLWithPath: newPath)), "new-name")

    let branches = git(["branch", "--list"], in: repoDir)
    XCTAssertTrue(branches.contains("new-name"))
    XCTAssertFalse(branches.contains("old-name"))

    // Git lists realpaths (/private/var vs /var for macOS temp dirs), so
    // compare symlink-resolved paths.
    let resolvedNew = URL(fileURLWithPath: newPath).resolvingSymlinksInPath().path
    let listed = WorktreeManager.shared.listWorktrees(repoRoot: repoDir.path)
    XCTAssertTrue(
      listed.contains {
        URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == resolvedNew
          && $0.branch == "new-name"
      })
  }

  func testRenamePreservesUncommittedChanges() throws {
    let wt = makeWorktree(named: "dirty")
    let scratch = URL(fileURLWithPath: wt.path).appendingPathComponent("scratch.txt")
    try "uncommitted".write(to: scratch, atomically: true, encoding: .utf8)

    let newPath = try WorktreeManager.shared.renameWorktree(
      repoRoot: repoDir.path, worktree: wt, newName: "renamed-dirty")

    let moved = URL(fileURLWithPath: newPath).appendingPathComponent("scratch.txt")
    XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "uncommitted")
  }

  func testRenameToSameNameIsANoop() throws {
    let wt = makeWorktree(named: "same")
    let newPath = try WorktreeManager.shared.renameWorktree(
      repoRoot: repoDir.path, worktree: wt, newName: "same")
    XCTAssertEqual(newPath, wt.path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: wt.path))
  }

  func testRenameRejectsEmptyName() {
    let wt = makeWorktree(named: "keep")
    XCTAssertThrowsError(
      try WorktreeManager.shared.renameWorktree(
        repoRoot: repoDir.path, worktree: wt, newName: "  "))
  }

  func testRenameRejectsNameWithSlash() {
    let wt = makeWorktree(named: "flat")
    XCTAssertThrowsError(
      try WorktreeManager.shared.renameWorktree(
        repoRoot: repoDir.path, worktree: wt, newName: "a/b"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: wt.path))
  }

  func testRenameRejectsExistingBranchAndLeavesWorktreeInPlace() {
    makeWorktree(named: "taken")
    let wt = makeWorktree(named: "source")
    XCTAssertThrowsError(
      try WorktreeManager.shared.renameWorktree(
        repoRoot: repoDir.path, worktree: wt, newName: "taken"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: wt.path))
    XCTAssertEqual(git(["branch", "--show-current"], in: URL(fileURLWithPath: wt.path)), "source")
  }

  func testRenameRejectsOccupiedDestinationPath() throws {
    let wt = makeWorktree(named: "blocked")
    // Occupy the destination path with a plain directory; the rename must
    // refuse before touching the branch or the worktree.
    let destination = worktreesDir.appendingPathComponent("occupied")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

    XCTAssertThrowsError(
      try WorktreeManager.shared.renameWorktree(
        repoRoot: repoDir.path, worktree: wt, newName: "occupied"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: wt.path))
    XCTAssertEqual(git(["branch", "--show-current"], in: URL(fileURLWithPath: wt.path)), "blocked")
  }
}
