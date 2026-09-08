import XCTest

@testable import DraftFrameKit

/// The environment every app-spawned git process runs with. Read-only
/// queries (sidebar `git status`, diff overlay) must never take the optional
/// `index.lock`, or they race Claude's own `git add`/`git commit` in the
/// same worktree (issue #28).
final class GitEnvironmentTests: XCTestCase {

  func testDisablesOptionalLocks() {
    XCTAssertEqual(WorktreeManager.gitEnvironment()["GIT_OPTIONAL_LOCKS"], "0")
  }

  func testDisablesTerminalPrompt() {
    XCTAssertEqual(WorktreeManager.gitEnvironment()["GIT_TERMINAL_PROMPT"], "0")
  }

  func testScrubsInheritedGitVariables() {
    setenv("GIT_DIR", "/nonexistent/.git", 1)
    setenv("GIT_WORK_TREE", "/nonexistent", 1)
    defer {
      unsetenv("GIT_DIR")
      unsetenv("GIT_WORK_TREE")
    }
    let env = WorktreeManager.gitEnvironment()
    XCTAssertNil(env["GIT_DIR"])
    XCTAssertNil(env["GIT_WORK_TREE"])
  }

  /// End-to-end: `git status` under the app's environment leaves no
  /// `index.lock` behind and never refreshes the index on disk, even when the
  /// stat cache is stale.
  func testStatusUnderAppEnvironmentDoesNotWriteIndex() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("draftframe-gitenv-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    func run(_ args: [String], env: [String: String]? = nil) {
      let proc = Process()
      proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      proc.arguments = ["-C", dir.path] + args
      if let env { proc.environment = env }
      proc.standardOutput = FileHandle.nullDevice
      proc.standardError = FileHandle.nullDevice
      try? proc.run()
      proc.waitUntilExit()
    }

    run(["init", "-q"])
    run(["config", "user.email", "t@example.com"])
    run(["config", "user.name", "t"])
    let file = dir.appendingPathComponent("a.txt")
    try "one".write(to: file, atomically: true, encoding: .utf8)
    run(["add", "a.txt"])
    run(["commit", "-q", "-m", "one"])

    // Invalidate the stat cache so a plain `git status` would want to
    // rewrite the index (and take index.lock to do so).
    let indexPath = dir.appendingPathComponent(".git/index").path
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: indexPath)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: file.path)
    let before = try Data(contentsOf: URL(fileURLWithPath: indexPath))

    run(["status", "--porcelain"], env: WorktreeManager.gitEnvironment())

    let after = try Data(contentsOf: URL(fileURLWithPath: indexPath))
    XCTAssertEqual(before, after, "git status must not rewrite the index under the app env")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git/index.lock").path))
  }
}
