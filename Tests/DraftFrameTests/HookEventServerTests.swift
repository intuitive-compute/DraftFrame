import XCTest

@testable import DraftFrameKit

/// Exercises the real transport: the bridge script DraftFrame installs,
/// run by `/bin/sh` with the environment Claude Code would inherit from a
/// session shell, delivering into a listening `HookEventServer`.
final class HookEventServerTests: XCTestCase {

  private var dir: String!

  override func setUpWithError() throws {
    // Keep the socket path short: sockaddr_un caps it at ~104 bytes.
    dir = "/tmp/dfhook-\(UUID().uuidString.prefix(8))"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(atPath: dir)
  }

  private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [HookEvent] = []
    var events: [HookEvent] { lock.withLock { _events } }
    func append(_ e: HookEvent) { lock.withLock { _events.append(e) } }
  }

  /// Run the bridge script exactly as Claude Code would: payload on stdin,
  /// tab and socket in the environment. Returns the exit status.
  private func runBridge(payload: String, env: [String: String]) throws -> Int32 {
    let script = dir + "/hook-bridge.sh"
    try ClaudeHooks.bridgeScript.write(toFile: script, atomically: true, encoding: .utf8)
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/sh")
    proc.arguments = [script]
    var fullEnv = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
    fullEnv.merge(env) { $1 }
    proc.environment = fullEnv
    let stdin = Pipe()
    proc.standardInput = stdin
    proc.standardOutput = Pipe()
    proc.standardError = Pipe()
    try proc.run()
    stdin.fileHandleForWriting.write(Data(payload.utf8))
    try stdin.fileHandleForWriting.close()
    proc.waitUntilExit()
    return proc.terminationStatus
  }

  func testBridgeScriptDeliversEventToServer() throws {
    let recorder = Recorder()
    let exp = expectation(description: "delivered")
    let server = HookEventServer { event in
      recorder.append(event)
      exp.fulfill()
    }
    let sock = dir + "/hooks.sock"
    server.start(path: sock)
    defer { server.stop() }
    XCTAssertTrue(server.isListening)
    XCTAssertTrue(HookEventServer.isSocketLive(sock))

    let tab = UUID()
    // Claude Code pretty-prints nothing here, but a multi-line payload must
    // work too since the bridge passes stdin through verbatim.
    let payload = """
      {
        "session_id": "abc-123",
        "transcript_path": "/tmp/t.jsonl",
        "cwd": "/tmp",
        "hook_event_name": "Notification",
        "notification_type": "permission_prompt",
        "message": "Claude needs your permission to use Bash"
      }
      """
    let status = try runBridge(
      payload: payload,
      env: [ClaudeHooks.tabEnvVar: tab.uuidString, ClaudeHooks.socketEnvVar: sock])
    XCTAssertEqual(status, 0)

    wait(for: [exp], timeout: 5)
    XCTAssertEqual(recorder.events.count, 1)
    let e = try XCTUnwrap(recorder.events.first)
    XCTAssertEqual(e.tabID, tab)
    XCTAssertEqual(e.name, "Notification")
    XCTAssertEqual(e.sessionId, "abc-123")
    XCTAssertEqual(e.notificationType, "permission_prompt")
    XCTAssertEqual(e.stateTransition, .needsAttention)
    XCTAssertNotNil(e.ppid, "bridge forwards its parent pid")
    XCTAssertEqual(server.eventCount, 1)
    XCTAssertNotNil(server.lastEventAt)
  }

  func testBridgeExitsZeroWithoutTabOrSocket() throws {
    let sock = dir + "/hooks.sock"
    // No tab variable: sessions outside DraftFrame. Must exit 0 and send nothing.
    XCTAssertEqual(try runBridge(payload: "{}", env: [ClaudeHooks.socketEnvVar: sock]), 0)
    // Tab set but no app listening: still 0, never a hook error in Claude Code.
    XCTAssertEqual(
      try runBridge(
        payload: "{}",
        env: [ClaudeHooks.tabEnvVar: UUID().uuidString, ClaudeHooks.socketEnvVar: sock]), 0)
  }

  func testGarbageIsCountedNotDelivered() throws {
    let recorder = Recorder()
    let server = HookEventServer { recorder.append($0) }
    let sock = dir + "/hooks.sock"
    server.start(path: sock)
    defer { server.stop() }

    // Connect directly and send something unparseable.
    guard var addr = HookEventServer.address(for: sock) else { return XCTFail("addr") }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
    }
    XCTAssertEqual(connected, 0)
    let junk = Array("this is not json\n".utf8)
    _ = junk.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    close(fd)

    let deadline = Date().addingTimeInterval(3)
    while server.rejectedCount == 0, Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    XCTAssertEqual(server.rejectedCount, 1)
    XCTAssertEqual(server.eventCount, 0)
    XCTAssertTrue(recorder.events.isEmpty)
  }

  func testIsSocketLiveIsFalseForStaleFile() throws {
    let sock = dir + "/stale.sock"
    FileManager.default.createFile(atPath: sock, contents: nil)
    XCTAssertFalse(HookEventServer.isSocketLive(sock))
    XCTAssertFalse(HookEventServer.isSocketLive(dir + "/missing.sock"))
  }
}
