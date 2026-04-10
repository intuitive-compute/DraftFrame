import AppKit
import SwiftTerm

/// Notification posted whenever session list or session state changes.
extension Notification.Name {
    static let sessionsDidChange = Notification.Name("DFSessionsDidChange")
    static let activeSessionDidChange = Notification.Name("DFActiveSessionDidChange")
}

/// State of a Claude Code session, detected from terminal output.
enum SessionState: String {
    case generating
    case thinking
    case userInput
    case idle
    case needsAttention

    var color: NSColor {
        switch self {
        case .generating:     return Theme.green
        case .thinking:       return Theme.yellow
        case .userInput:      return Theme.accent
        case .needsAttention: return Theme.red
        case .idle:           return Theme.cyan
        }
    }

    var label: String {
        switch self {
        case .generating:     return "Generating"
        case .thinking:       return "Thinking"
        case .userInput:      return "Input"
        case .needsAttention: return "Attention"
        case .idle:           return "Idle"
        }
    }
}

/// A single terminal session.
final class Session {
    let id: UUID
    var name: String
    var state: SessionState
    var model: String
    var cost: Double
    var tokensIn: Int
    var tokensOut: Int
    var worktreePath: String?
    var terminalView: ClaudeTerminalView?

    /// Real-time PTY stream analyzer for Claude Code state detection.
    let ptyAnalyzer = PTYStreamAnalyzer()

    /// Watches the Claude Code JSONL log for cost/token updates.
    var jsonlWatcher: SessionJSONLWatcher?

    init(name: String, worktreePath: String? = nil) {
        self.id = UUID()
        self.name = name
        self.state = .idle
        self.model = "sonnet"
        self.cost = 0.0
        self.tokensIn = 0
        self.tokensOut = 0
        self.worktreePath = worktreePath

        // Wire up state changes from the PTY analyzer
        ptyAnalyzer.onStateChange = { [weak self] newState in
            guard let self = self else { return }
            self.state = newState
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .sessionsDidChange, object: nil)
            }
        }
    }

    /// Start monitoring the JSONL file for the given working directory.
    func startJSONLWatcher(directory: String) {
        jsonlWatcher = SessionJSONLWatcher(workingDirectory: directory) { [weak self] cost, tokensIn, tokensOut, model in
            guard let self = self else { return }
            self.cost = cost
            self.tokensIn = tokensIn
            self.tokensOut = tokensOut
            self.model = model
            NotificationCenter.default.post(name: .sessionsDidChange, object: nil)
        }
    }
}

/// Singleton managing all terminal sessions.
final class SessionManager {
    static let shared = SessionManager()

    private(set) var sessions: [Session] = []
    private(set) var activeSessionIndex: Int = -1
    var projectDir: String?

    var activeSession: Session? {
        guard activeSessionIndex >= 0, activeSessionIndex < sessions.count else { return nil }
        return sessions[activeSessionIndex]
    }

    var totalCost: Double {
        sessions.reduce(0) { $0 + $1.cost }
    }

    var totalTokensIn: Int {
        sessions.reduce(0) { $0 + $1.tokensIn }
    }

    var totalTokensOut: Int {
        sessions.reduce(0) { $0 + $1.tokensOut }
    }

    private init() {}

    /// Create a new session and return it.
    @discardableResult
    func createSession(name: String? = nil, command: String? = nil, worktreePath: String? = nil) -> Session {
        let sessionName = name ?? "session-\(sessions.count + 1)"
        let session = Session(name: sessionName, worktreePath: worktreePath)

        // Create the terminal view (ClaudeTerminalView intercepts PTY data)
        let tv = ClaudeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        tv.nativeForegroundColor = Theme.text1
        tv.nativeBackgroundColor = Theme.bg
        tv.selectedTextBackgroundColor = Theme.selected
        tv.caretColor = Theme.accent
        tv.font = Theme.mono(13)
        session.terminalView = tv

        // Wire PTY data stream to the analyzer for real-time state detection
        tv.onPtyData = { [weak session] bytes in
            session?.ptyAnalyzer.feed(bytes)
        }

        // Start the process
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let env: [String] = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }

        if let cmd = command {
            tv.startProcess(executable: shell,
                            args: ["-l", "-c", cmd],
                            environment: env,
                            execName: nil)
        } else {
            tv.startProcess(executable: shell,
                            args: ["--login"],
                            environment: env,
                            execName: nil)
        }

        // cd into worktree directory then launch claude
        if let wtPath = worktreePath {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                tv.send(txt: "cd \(wtPath) && clear && claude\r")
            }
        } else {
            // No worktree — just launch claude
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                tv.send(txt: "claude\r")
            }
        }

        // Start JSONL watcher for cost/token tracking.
        let watchDir = worktreePath ?? projectDir ?? FileManager.default.currentDirectoryPath
        session.startJSONLWatcher(directory: watchDir)

        sessions.append(session)
        activeSessionIndex = sessions.count - 1

        NotificationCenter.default.post(name: .sessionsDidChange, object: nil)
        NotificationCenter.default.post(name: .activeSessionDidChange, object: nil)

        return session
    }

    /// Switch to session at index.
    func switchTo(index: Int) {
        guard index >= 0, index < sessions.count else { return }
        activeSessionIndex = index
        NotificationCenter.default.post(name: .activeSessionDidChange, object: nil)
    }

    /// Close session at index.
    func closeSession(at index: Int) {
        guard index >= 0, index < sessions.count else { return }
        sessions[index].jsonlWatcher?.stop()
        sessions.remove(at: index)

        if sessions.isEmpty {
            activeSessionIndex = -1
        } else if activeSessionIndex >= sessions.count {
            activeSessionIndex = sessions.count - 1
        }

        NotificationCenter.default.post(name: .sessionsDidChange, object: nil)
        NotificationCenter.default.post(name: .activeSessionDidChange, object: nil)
    }

    /// Close session by ID.
    func closeSession(id: UUID) {
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            closeSession(at: idx)
        }
    }

    /// Restart session by ID — closes and re-creates.
    func restartSession(id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        let old = sessions[idx]
        closeSession(at: idx)
        createSession(name: old.name, worktreePath: old.worktreePath)
    }

    /// Get the current git branch for the active session's directory.
    func currentBranch() -> String {
        let dir = activeSession?.worktreePath ?? FileManager.default.currentDirectoryPath
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", dir, "rev-parse", "--abbrev-ref", "HEAD"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "main"
        } catch {
            return "main"
        }
    }
}
