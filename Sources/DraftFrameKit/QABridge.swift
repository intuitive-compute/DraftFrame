import AppKit
import SwiftTerm

#if !DEBUG
  /// Release builds compile the QA bridge out entirely; this stub keeps the
  /// call sites (app delegate, persistence guards) building unchanged.
  public enum QABridge {
    public static let isQAMode = false
    public static func startIfEnabled(appDelegate: DFAppDelegate) {}
  }
#else

  /// Debug-only automation bridge for end-to-end QA. Compiled only into debug
  /// builds — release binaries contain none of this code (see the stub above).
  ///
  /// When the app is launched with `DRAFTFRAME_QA_SOCKET=<path>` in its
  /// environment, the bridge listens on a Unix domain socket at that path and
  /// answers one JSON request per connection: the client writes a single
  /// newline-terminated JSON object (`{"cmd": "...", ...params}`) and reads the
  /// JSON response until EOF. The `dfqa` CLI target is the intended client.
  ///
  /// The env-var gate means the bridge never runs for normal users — packaged
  /// builds don't set it, and there is no UI to turn it on.
  /// `@unchecked Sendable`: the mutable fields are written once during
  /// `start` (on the main thread, before the accept thread spawns) and only
  /// read afterwards; all command handling hops to the main actor.
  public final class QABridge: @unchecked Sendable {
    public static let shared = QABridge()

    private weak var appDelegate: DFAppDelegate?
    private var socketFD: Int32 = -1
    private var socketPath = ""

    private init() {}

    /// Whether the app is running under QA automation. Guards side effects
    /// that would leak QA state into the user's real app data (e.g. session
    /// persistence, which is shared with non-QA launches).
    public static var isQAMode: Bool {
      ProcessInfo.processInfo.environment["DRAFTFRAME_QA_SOCKET"]?.isEmpty == false
    }

    /// Start the bridge if `DRAFTFRAME_QA_SOCKET` is set. Call once the main
    /// window exists so handlers can reach the window controller.
    public static func startIfEnabled(appDelegate: DFAppDelegate) {
      guard let path = ProcessInfo.processInfo.environment["DRAFTFRAME_QA_SOCKET"],
        !path.isEmpty
      else { return }
      shared.start(path: path, appDelegate: appDelegate)
    }

    private func start(path: String, appDelegate: DFAppDelegate) {
      self.appDelegate = appDelegate
      socketPath = path
      unlink(path)

      let fd = socket(AF_UNIX, SOCK_STREAM, 0)
      guard fd >= 0 else {
        NSLog("[QABridge] socket() failed: %d", errno)
        return
      }

      var addr = sockaddr_un()
      addr.sun_family = sa_family_t(AF_UNIX)
      let pathBytes = Array(path.utf8)
      guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
        NSLog("[QABridge] socket path too long: %@", path)
        close(fd)
        return
      }
      withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: pathBytes)
      }

      let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
      let bindResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
          bind(fd, sa, addrLen)
        }
      }
      guard bindResult == 0, listen(fd, 4) == 0 else {
        NSLog("[QABridge] bind/listen failed: %d", errno)
        close(fd)
        return
      }

      socketFD = fd
      // Terminal sessions fork PTY children; without CLOEXEC they'd inherit
      // this fd and keep client connections from ever seeing EOF.
      _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
      NSLog("[QABridge] listening on %@", path)

      Thread.detachNewThread { [weak self] in
        self?.acceptLoop(fd: fd)
      }
    }

    private func acceptLoop(fd: Int32) {
      while true {
        let client = accept(fd, nil, nil)
        guard client >= 0 else {
          if errno == EBADF { return }  // socket closed
          continue
        }
        // Same CLOEXEC rationale as the listening fd: a session created while
        // this connection is open must not leak the fd into its PTY child.
        _ = fcntl(client, F_SETFD, FD_CLOEXEC)
        serve(client: client)
        close(client)
      }
    }

    /// Read one newline-terminated JSON request, handle it on the main thread,
    /// write the JSON response. One request per connection.
    private func serve(client: Int32) {
      var data = Data()
      var buf = [UInt8](repeating: 0, count: 4096)
      while data.count < 1_048_576 {
        let n = read(client, &buf, buf.count)
        guard n > 0 else { break }
        data.append(contentsOf: buf[0..<n])
        if buf[0..<n].contains(0x0A) { break }
      }

      // Serialize the response inside the main.sync block so only Sendable
      // Data crosses back to the socket thread, not a [String: Any].
      var out: Data
      if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let cmd = obj["cmd"] as? String
      {
        out = DispatchQueue.main.sync {
          MainActor.assumeIsolated {
            let result = self.handle(cmd: cmd, params: obj)
            return (try? JSONSerialization.data(withJSONObject: result))
              ?? Data(#"{"ok":false,"error":"unencodable response"}"#.utf8)
          }
        }
      } else {
        out = Data(
          #"{"ok":false,"error":"invalid request: expected JSON with a \"cmd\" field"}"#.utf8)
      }
      out.append(0x0A)
      out.withUnsafeBytes { raw in
        var sent = 0
        while sent < raw.count {
          let n = write(client, raw.baseAddress!.advanced(by: sent), raw.count - sent)
          guard n > 0 else { break }
          sent += n
        }
      }
    }

    // MARK: - Command dispatch (main thread)

    @MainActor
    private func handle(cmd: String, params: [String: Any]) -> [String: Any] {
      switch cmd {
      case "ping":
        return [
          "ok": true,
          "version": UpdateManager.currentVersion,
          "pid": Int(getpid()),
          "sessions": SessionManager.shared.sessions.count,
        ]

      case "sessions":
        return ["ok": true, "sessions": sessionList()]

      case "state":
        return appState()

      case "new-session":
        let name = params["name"] as? String
        let worktree = params["worktree"] as? String
        appDelegate?.windowController?.terminalPane.createNewSession(
          name: name, worktreePath: worktree)
        return ["ok": true, "sessions": sessionList()]

      case "select":
        guard let idx = params["index"] as? Int else {
          return ["ok": false, "error": "select requires \"index\""]
        }
        guard idx >= 0, idx < SessionManager.shared.sessions.count else {
          return ["ok": false, "error": "index out of range"]
        }
        SessionManager.shared.switchTo(index: idx)
        return ["ok": true]

      case "close-session":
        guard let idx = params["index"] as? Int else {
          return ["ok": false, "error": "close-session requires \"index\""]
        }
        guard idx >= 0, idx < SessionManager.shared.sessions.count else {
          return ["ok": false, "error": "index out of range"]
        }
        SessionManager.shared.closeSession(at: idx)
        return ["ok": true, "sessions": sessionList()]

      case "send":
        guard let text = params["text"] as? String else {
          return ["ok": false, "error": "send requires \"text\""]
        }
        guard let session = resolveSession(params) else {
          return ["ok": false, "error": "no such session"]
        }
        guard let tv = session.terminalView else {
          return ["ok": false, "error": "session has no terminal view"]
        }
        let enter = params["enter"] as? Bool ?? false
        tv.send(txt: enter ? text + "\r" : text)
        return ["ok": true]

      case "read":
        guard let session = resolveSession(params) else {
          return ["ok": false, "error": "no such session"]
        }
        guard let tv = session.terminalView else {
          return ["ok": false, "error": "session has no terminal view"]
        }
        let requested = params["lines"] as? Int
        return readBuffer(tv: tv, requestedLines: requested)

      case "screenshot":
        guard let path = params["path"] as? String else {
          return ["ok": false, "error": "screenshot requires \"path\""]
        }
        let which = params["window"] as? String ?? "main"
        return screenshot(to: path, window: which)

      case "menu":
        guard let titles = params["path"] as? [String], !titles.isEmpty else {
          return ["ok": false, "error": "menu requires \"path\" (array of menu titles)"]
        }
        return invokeMenu(titles: titles)

      case "open-project":
        guard let path = params["path"] as? String else {
          return ["ok": false, "error": "open-project requires \"path\""]
        }
        guard FileManager.default.fileExists(atPath: path) else {
          return ["ok": false, "error": "no such directory: \(path)"]
        }
        appDelegate?.windowController?.openProject(at: path)
        return ["ok": true]

      case "quit":
        DispatchQueue.main.async { NSApp.terminate(nil) }
        return ["ok": true]

      default:
        return ["ok": false, "error": "unknown cmd: \(cmd)"]
      }
    }

    // MARK: - Helpers

    @MainActor private func resolveSession(_ params: [String: Any]) -> Session? {
      let mgr = SessionManager.shared
      if let idx = params["index"] as? Int {
        guard idx >= 0, idx < mgr.sessions.count else { return nil }
        return mgr.sessions[idx]
      }
      return mgr.activeSession
    }

    @MainActor private func sessionList() -> [[String: Any]] {
      let mgr = SessionManager.shared
      return mgr.sessions.enumerated().map { i, s in
        [
          "index": i,
          "id": s.id.uuidString,
          "name": s.name,
          "displayName": s.displayName,
          "agent": s.agent.rawValue,
          "state": s.state.rawValue,
          "model": s.model,
          "cost": s.cost,
          "contextTokens": s.contextTokens,
          "maxContextTokens": s.maxContextTokens,
          "worktreePath": s.worktreePath ?? NSNull(),
          "agentSessionId": s.agentSessionId ?? NSNull(),
          "active": i == mgr.activeSessionIndex,
        ]
      }
    }

    @MainActor private func appState() -> [String: Any] {
      let mgr = SessionManager.shared
      var state: [String: Any] = [
        "ok": true,
        "sessionCount": mgr.sessions.count,
        "activeIndex": mgr.activeSessionIndex,
        "quickTerminalVisible": DFQuickTerminal.shared.isVisible,
        "windowCount": NSApp.windows.filter { $0.isVisible }.count,
      ]
      if let wc = appDelegate?.windowController {
        state["dashboardVisible"] = !wc.dashboard.isHidden
        if let frame = wc.window?.frame {
          state["windowFrame"] = [
            "x": frame.origin.x, "y": frame.origin.y,
            "w": frame.size.width, "h": frame.size.height,
          ]
        }
      }
      return state
    }

    /// Text of the session's visible terminal screen — what a human QA would
    /// see. `ClaudeTerminalView` pins the viewport to the live screen, so this
    /// tracks program output. `requestedLines` keeps only the last N rows.
    @MainActor private func readBuffer(tv: ClaudeTerminalView, requestedLines: Int?)
      -> [String: Any]
    {
      let term = tv.getTerminal()
      var lines: [String] = []
      for row in 0..<term.rows {
        // Never-written cells render as literal NULs. The TUI leaves them
        // between words too, so map them to spaces rather than deleting them.
        var text =
          term.getLine(row: row)?.translateToString(trimRight: true)
          .replacingOccurrences(of: "\u{0000}", with: " ") ?? ""
        while text.hasSuffix(" ") { text.removeLast() }
        lines.append(text)
      }
      // Drop trailing blank lines — the live screen is usually mostly empty.
      while let last = lines.last, last.isEmpty { lines.removeLast() }
      if let want = requestedLines, want > 0, lines.count > want {
        lines.removeFirst(lines.count - want)
      }
      return [
        "ok": true,
        "text": lines.joined(separator: "\n"),
        "rows": term.rows,
        "cols": term.cols,
      ]
    }

    /// Capture a window's actual pixels into a PNG via CGWindowListCreateImage.
    /// Capturing our own process's windows needs no screen-recording permission,
    /// and unlike `cacheDisplay` it includes SwiftTerm's terminal rendering.
    @MainActor private func screenshot(to path: String, window which: String) -> [String: Any] {
      let win: NSWindow?
      switch which {
      case "quick":
        win = DFQuickTerminal.shared.qaWindow
      case "key":
        win = NSApp.keyWindow
      default:
        win = appDelegate?.windowController?.window
      }
      guard let window = win else {
        return ["ok": false, "error": "window \"\(which)\" not available"]
      }
      guard
        let cgImage = CGWindowListCreateImage(
          .null, .optionIncludingWindow, CGWindowID(window.windowNumber),
          [.boundsIgnoreFraming, .bestResolution])
      else {
        return ["ok": false, "error": "could not capture window"]
      }
      let rep = NSBitmapImageRep(cgImage: cgImage)
      guard let png = rep.representation(using: .png, properties: [:]) else {
        return ["ok": false, "error": "could not encode PNG"]
      }
      do {
        try png.write(to: URL(fileURLWithPath: path))
      } catch {
        return ["ok": false, "error": "write failed: \(error.localizedDescription)"]
      }
      return [
        "ok": true, "path": path,
        "width": rep.pixelsWide, "height": rep.pixelsHigh,
      ]
    }

    /// Find a menu item by its title path (e.g. ["View", "Toggle Dashboard"])
    /// and perform its action. The action fires asynchronously so an item that
    /// opens a modal (About, alerts) can't deadlock the bridge's reply.
    @MainActor private func invokeMenu(titles: [String]) -> [String: Any] {
      guard var menu = NSApp.mainMenu else {
        return ["ok": false, "error": "no main menu"]
      }
      var item: NSMenuItem?
      for (i, title) in titles.enumerated() {
        // Top-level items carry no title of their own; match the submenu's
        // title too (e.g. the "View" in ["View", "Toggle Dashboard"]).
        guard
          let found = menu.items.first(where: {
            $0.title == title || $0.submenu?.title == title || $0.title.hasPrefix(title)
          })
        else {
          return [
            "ok": false, "error": "menu item not found: \(titles[0...i].joined(separator: " > "))",
          ]
        }
        if i == titles.count - 1 {
          item = found
        } else if let sub = found.submenu {
          menu = sub
        } else {
          return ["ok": false, "error": "\(title) has no submenu"]
        }
      }
      guard let target = item, let action = target.action else {
        return ["ok": false, "error": "menu item has no action"]
      }
      DispatchQueue.main.async {
        NSApp.sendAction(action, to: target.target, from: target)
      }
      return ["ok": true, "invoked": target.title]
    }
  }

#endif
