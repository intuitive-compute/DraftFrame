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
    var terminalView: LocalProcessTerminalView?
    private var outputBuffer: String = ""

    init(name: String, worktreePath: String? = nil) {
        self.id = UUID()
        self.name = name
        self.state = .idle
        self.model = "sonnet"
        self.cost = 0.0
        self.tokensIn = 0
        self.tokensOut = 0
        self.worktreePath = worktreePath
    }

    private var lastBufferSnapshot: String = ""

    /// Poll the terminal buffer and detect session state from visible content.
    /// Called periodically by SessionManager's timer.
    func pollTerminalState() {
        guard let tv = terminalView else { return }
        let terminal = tv.getTerminal()
        let rows = terminal.rows

        // Read ALL visible lines
        var lines: [String] = []
        for row in 0..<rows {
            guard let line = terminal.getLine(row: row) else { continue }
            lines.append(line.translateToString())
        }

        let snapshot = lines.joined(separator: "\n")
        lastBufferSnapshot = snapshot
        let oldState = state

        // Get non-empty lines from bottom up for prompt detection
        let bottomLines = lines.reversed().filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let lastLine = bottomLines.first ?? ""
        let trimmedLast = lastLine.trimmingCharacters(in: .whitespaces)

        // --- Claude Code state detection ---
        // Claude Code renders a full TUI. We scan the entire visible buffer.
        let lower = snapshot.lowercased()

        // Signals that Claude is ACTIVELY WORKING (not waiting for user)
        let isWorking = lower.contains("esc to interrupt") ||
                        lower.contains("thinking") ||
                        lower.contains("…") ||       // ellipsis in status like "Jitterbugging…"
                        lower.contains("searching") ||
                        lower.contains("reading") ||
                        lower.contains("writing") ||
                        lower.contains("editing") ||
                        lower.contains("creating") ||
                        lower.contains("updating") ||
                        lower.contains("running")

        // Spinner characters (various braille patterns Claude uses)
        let spinners: Set<Character> = ["⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏","⣾","⣽","⣻","⢿","⡿","⣟","⣯","⣷"]
        let hasSpinner = snapshot.contains(where: { spinners.contains($0) })

        // Thinking: "thinking" keyword or spinner + working indicator
        let isThinking = lower.contains("thinking") || (hasSpinner && isWorking)

        // Generating: tool use visible, or streaming content with "esc to interrupt"
        let hasToolUse = snapshot.contains("Read(") || snapshot.contains("Edit(") || snapshot.contains("Write(") ||
                         snapshot.contains("Bash(") || snapshot.contains("Grep(") || snapshot.contains("Glob(") ||
                         snapshot.contains("Agent(")
        let hasStreamCursor = snapshot.contains("▍") || snapshot.contains("▊")
        let isGenerating = hasToolUse || hasStreamCursor || (isWorking && !isThinking)

        // Needs attention: permission prompts
        let needsAttention = (snapshot.contains("Allow") && snapshot.contains("Deny")) ||
                             snapshot.contains("[Y/n]") || snapshot.contains("(y/N)") ||
                             snapshot.contains("Do you want to")

        // Shell prompt = idle (Claude not running)
        let hasShellPrompt = trimmedLast.hasSuffix("$ ") || trimmedLast.hasSuffix("% ") ||
                             trimmedLast.hasSuffix("# ") ||
                             (trimmedLast.contains("❯") && !lower.contains("esc to interrupt"))

        // Claude waiting for user input: ">" prompt at bottom with NO working indicators
        let hasClaudePrompt = trimmedLast.hasPrefix(">") && !isWorking

        // Priority-based state assignment (most specific first)
        if needsAttention {
            state = .needsAttention
        } else if isThinking {
            state = .thinking
        } else if isGenerating {
            state = .generating
        } else if hasShellPrompt && !isWorking {
            state = .idle
        } else if hasClaudePrompt {
            state = .userInput
        }
        // else: keep current state — avoids flickering on transient frames
        // else: keep current state (don't flicker)

        // --- Cost detection from Claude's status bar ---
        // Claude shows cost in its bottom bar like "$0.42" or "Cost: $1.23"
        for line in lines {
            if let range = line.range(of: #"\$(\d+\.?\d{0,2})"#, options: .regularExpression) {
                let match = String(line[range]).dropFirst()
                if let parsed = Double(match), parsed > 0 && parsed < 1000 {
                    cost = max(cost, parsed) // cost only goes up
                }
            }
        }

        // --- Token detection ---
        for line in lines {
            // Match "12.5K tokens" or "1,234 tokens" patterns
            if let range = line.range(of: #"(\d[\d,.]*)\s*[Kk]?\s*tokens?"#, options: .regularExpression) {
                let match = String(line[range])
                if let numRange = match.range(of: #"[\d,.]+"#, options: .regularExpression) {
                    let numStr = String(match[numRange]).replacingOccurrences(of: ",", with: "")
                    if let num = Double(numStr) {
                        let tokens = match.lowercased().contains("k") ? Int(num * 1000) : Int(num)
                        tokensIn = max(tokensIn, tokens)
                    }
                }
            }
        }

        // --- Model detection from Claude's status bar ---
        let flat = snapshot.lowercased()
        if flat.contains("opus") { model = "opus" }
        else if flat.contains("haiku") { model = "haiku" }
        else if flat.contains("sonnet") { model = "sonnet" }

        if state != oldState {
            NotificationCenter.default.post(name: .sessionsDidChange, object: nil)
        }
    }
}

/// Singleton managing all terminal sessions.
final class SessionManager {
    static let shared = SessionManager()

    private(set) var sessions: [Session] = []
    private(set) var activeSessionIndex: Int = -1

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

    private var pollTimer: Timer?

    private init() {
        // Poll all sessions every 500ms on the main thread (SwiftTerm requires main thread)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            for session in self.sessions {
                session.pollTerminalState()
            }
        }
    }

    /// Create a new session and return it.
    @discardableResult
    func createSession(name: String? = nil, command: String? = nil, worktreePath: String? = nil) -> Session {
        let sessionName = name ?? "session-\(sessions.count + 1)"
        let session = Session(name: sessionName, worktreePath: worktreePath)

        // Create the terminal view
        let tv = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        tv.nativeForegroundColor = Theme.text1
        tv.nativeBackgroundColor = Theme.bg
        tv.selectedTextBackgroundColor = Theme.selected
        tv.caretColor = Theme.accent
        tv.font = Theme.mono(13)
        session.terminalView = tv

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
