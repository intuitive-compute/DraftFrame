import Foundation
import os

/// Unix-socket listener for Claude Code hook events forwarded by the bridge
/// script (`ClaudeHooks.bridgeScript`). One newline-terminated JSON message
/// per connection, no reply. Parsed events are routed on the main actor to
/// the tab they name via `SessionManager`.
///
/// Always started with the app, regardless of whether hooks are installed:
/// listening is free, and it lets the health check distinguish "hooks not
/// installed" from "installed but nothing arrives".
///
/// `@unchecked Sendable`: `socketPath`/`socketFD` are written once in
/// `start` before the accept thread exists; the counters are lock-guarded.
final class HookEventServer: @unchecked Sendable {
  static let shared = HookEventServer()

  /// Routed on the main actor for every parsed event. Defaults to the
  /// session manager; tests swap in a recorder.
  typealias Handler = @MainActor @Sendable (HookEvent) -> Void

  private(set) var socketPath: String?
  private var socketFD: Int32 = -1
  private let handler: Handler

  private struct Stats {
    var eventCount = 0
    var lastEventAt: Date?
    var rejectedCount = 0
  }
  private let stats = OSAllocatedUnfairLock(initialState: Stats())

  var isListening: Bool { socketFD >= 0 }
  var eventCount: Int { stats.withLock { $0.eventCount } }
  var lastEventAt: Date? { stats.withLock { $0.lastEventAt } }
  /// Messages that reached the socket but couldn't be parsed.
  var rejectedCount: Int { stats.withLock { $0.rejectedCount } }

  private convenience init() {
    self.init(handler: { event in SessionManager.shared.routeHookEvent(event) })
  }

  init(handler: @escaping Handler) {
    self.handler = handler
  }

  deinit { stop() }

  /// Start listening for the app. Uses the default socket unless another
  /// live instance already owns it (or under QA automation), in which case
  /// a pid-suffixed path is used; sessions learn the path via
  /// `DRAFTFRAME_HOOK_SOCKET` either way.
  func startForApp() {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: ClaudeHooks.supportDir, withIntermediateDirectories: true)
    var path = ClaudeHooks.defaultSocketPath
    if QABridge.isQAMode || Self.isSocketLive(path) {
      path = ClaudeHooks.supportDir + "/hooks-\(getpid()).sock"
    }
    start(path: path)
  }

  /// Bind and listen on `path`, replacing any stale socket file there.
  func start(path: String) {
    guard socketFD < 0 else { return }
    unlink(path)

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
      NSLog("[HookEventServer] socket() failed: %d", errno)
      return
    }
    guard var addr = Self.address(for: path) else {
      NSLog("[HookEventServer] socket path too long: %@", path)
      close(fd)
      return
    }
    let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
    let bound = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, addrLen) }
    }
    guard bound == 0, listen(fd, 16) == 0 else {
      NSLog("[HookEventServer] bind/listen failed: %d", errno)
      close(fd)
      return
    }
    // Session shells must not inherit the listening fd: a child holding it
    // would keep the socket alive past the app and confuse bridge clients.
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    socketFD = fd
    socketPath = path
    NSLog("[HookEventServer] listening on %@", path)

    Thread.detachNewThread { [weak self] in
      self?.acceptLoop(fd: fd)
    }
  }

  func stop() {
    guard socketFD >= 0 else { return }
    close(socketFD)
    socketFD = -1
    if let path = socketPath { unlink(path) }
  }

  // MARK: - Accept / read

  private func acceptLoop(fd: Int32) {
    while true {
      let client = accept(fd, nil, nil)
      guard client >= 0 else {
        if errno == EBADF || errno == EINVAL { return }  // socket closed
        // EMFILE, ECONNABORTED and friends: back off instead of spinning
        // the accept thread at full speed until the condition clears.
        usleep(100_000)
        continue
      }
      _ = fcntl(client, F_SETFD, FD_CLOEXEC)
      // The bridge writes and exits; never let a stuck client pin the
      // accept thread.
      var tv = timeval(tv_sec: 2, tv_usec: 0)
      setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
      let data = readMessage(client)
      close(client)
      dispatch(data)
    }
  }

  /// Read until EOF, a terminating newline after a complete JSON object, or
  /// the receive timeout.
  private func readMessage(_ client: Int32) -> Data {
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 8192)
    while data.count < 1_048_576 {
      let n = read(client, &buf, buf.count)
      guard n > 0 else { break }
      data.append(contentsOf: buf[0..<n])
      if buf[n - 1] == 0x0A, (try? JSONSerialization.jsonObject(with: data)) != nil { break }
    }
    return data
  }

  private func dispatch(_ data: Data) {
    guard let event = HookEvent.parse(data) else {
      stats.withLock { $0.rejectedCount += 1 }
      return
    }
    stats.withLock {
      $0.eventCount += 1
      $0.lastEventAt = Date()
    }
    deliver(event)
  }

  /// Hand an already-parsed event to the handler on the main actor. Also the
  /// entry point for synthetic events injected by the QA bridge.
  func deliver(_ event: HookEvent) {
    let handler = self.handler
    DispatchQueue.main.async {
      MainActor.assumeIsolated { handler(event) }
    }
  }

  // MARK: - Helpers

  static func address(for path: String) -> sockaddr_un? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
    return addr
  }

  /// True when something currently accepts connections at `path`.
  static func isSocketLive(_ path: String) -> Bool {
    guard var addr = address(for: path) else { return false }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    return withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) == 0 }
    }
  }
}
