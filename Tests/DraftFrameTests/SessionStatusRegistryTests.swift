import XCTest

@testable import DraftFrameKit

final class SessionStatusRegistryTests: XCTestCase {

  private var dir: String!

  override func setUpWithError() throws {
    dir = NSTemporaryDirectory() + "df-status-registry-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(atPath: dir)
  }

  /// Callbacks land on the main queue; collect them without racing the test.
  private final class StateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _states: [SessionState] = []
    var states: [SessionState] { lock.withLock { _states } }
    func append(_ s: SessionState) { lock.withLock { _states.append(s) } }
  }

  /// Write a pid file the way Claude Code does. Uses our own pid so the
  /// registry's `kill(pid, 0)` liveness check passes.
  private func writePidFile(
    name: String, cwd: String, status: String, startedAt: Double, pid: Int32 = getpid()
  ) throws {
    let obj: [String: Any] = [
      "cwd": cwd, "pid": Int(pid), "startedAt": startedAt, "status": status,
    ]
    let data = try JSONSerialization.data(withJSONObject: obj)
    try data.write(to: URL(fileURLWithPath: dir + "/" + name))
  }

  func testReportsStateFromMatchingPidFile() async throws {
    let cwd = "/tmp/df-project-a"
    try writePidFile(name: "\(getpid()).json", cwd: cwd, status: "busy", startedAt: 100)

    let registry = SessionStatusRegistry(sessionsDir: dir)
    let log = StateLog()
    let exp = expectation(description: "reported")
    let id = UUID()
    await registry.subscribe(id: id, cwd: cwd, isActive: { true }) { state in
      log.append(state)
      exp.fulfill()
    }
    await fulfillment(of: [exp], timeout: 5)
    XCTAssertEqual(log.states, [.generating])
    await registry.unsubscribe(id: id)
  }

  func testReportsIdleWhenNoPidFileMatches() async throws {
    let registry = SessionStatusRegistry(sessionsDir: dir)
    let log = StateLog()
    let exp = expectation(description: "reported")
    let id = UUID()
    await registry.subscribe(id: id, cwd: "/tmp/df-nowhere", isActive: { true }) { state in
      log.append(state)
      exp.fulfill()
    }
    await fulfillment(of: [exp], timeout: 5)
    XCTAssertEqual(log.states, [.idle])
    await registry.unsubscribe(id: id)
  }

  func testNewestStartedAtWinsForSameCwd() async throws {
    let cwd = "/tmp/df-project-b"
    try writePidFile(name: "older.json", cwd: cwd, status: "busy", startedAt: 100)
    try writePidFile(name: "newer.json", cwd: cwd, status: "waiting", startedAt: 200)

    let registry = SessionStatusRegistry(sessionsDir: dir)
    let log = StateLog()
    let exp = expectation(description: "reported")
    let id = UUID()
    await registry.subscribe(id: id, cwd: cwd, isActive: { true }) { state in
      log.append(state)
      exp.fulfill()
    }
    await fulfillment(of: [exp], timeout: 5)
    XCTAssertEqual(log.states, [.needsAttention])
    await registry.unsubscribe(id: id)
  }

  func testInactiveSubscriberIsRefusedAndNeverCalled() async throws {
    let cwd = "/tmp/df-project-c"
    try writePidFile(name: "\(getpid()).json", cwd: cwd, status: "busy", startedAt: 100)

    let registry = SessionStatusRegistry(sessionsDir: dir)
    let log = StateLog()
    // A handle stopped before its subscribe hop lands (stop() racing init)
    // presents an isActive that already answers false.
    await registry.subscribe(id: UUID(), cwd: cwd, isActive: { false }) { state in
      log.append(state)
    }
    // Give any (incorrect) callback time to land on main.
    try await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertEqual(log.states, [])
  }

  func testMatchesAcrossSymlinkSpellings() async throws {
    // Claude Code writes the realpath (/private/tmp/...) into the pid file;
    // the session may watch the symlinked spelling (/tmp/...). On macOS
    // /tmp is a symlink to /private/tmp, so these two spellings must match.
    // Symlink resolution only converges spellings for paths that exist, so
    // create the directory the way a real project dir would.
    let cwd = "/tmp/df-symlink-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: cwd) }
    try writePidFile(
      name: "\(getpid()).json", cwd: "/private" + cwd,
      status: "busy", startedAt: 100)

    let registry = SessionStatusRegistry(sessionsDir: dir)
    let log = StateLog()
    let exp = expectation(description: "reported")
    let id = UUID()
    await registry.subscribe(id: id, cwd: cwd, isActive: { true }) { state in
      log.append(state)
      exp.fulfill()
    }
    await fulfillment(of: [exp], timeout: 5)
    XCTAssertEqual(log.states, [.generating])
    await registry.unsubscribe(id: id)
  }

  func testDeadPidIsIgnored() async throws {
    let cwd = "/tmp/df-project-d"
    // PID 0 always fails the kill(pid, 0) liveness probe's intent here —
    // use an fd-safe guaranteed-dead pid instead: fork would be overkill,
    // and pid_t(99_999_999) exceeds macOS's max pid, so kill returns ESRCH.
    try writePidFile(
      name: "dead.json", cwd: cwd, status: "busy", startedAt: 100, pid: 99_999_999)

    let registry = SessionStatusRegistry(sessionsDir: dir)
    let log = StateLog()
    let exp = expectation(description: "reported")
    let id = UUID()
    await registry.subscribe(id: id, cwd: cwd, isActive: { true }) { state in
      log.append(state)
      exp.fulfill()
    }
    await fulfillment(of: [exp], timeout: 5)
    // The only pid file for this cwd is dead, so the cwd has no live claude.
    XCTAssertEqual(log.states, [.idle])
    await registry.unsubscribe(id: id)
  }
}
