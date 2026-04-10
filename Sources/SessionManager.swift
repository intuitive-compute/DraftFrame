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

    /// Analyze recent terminal output to detect Claude Code state changes.
    func analyzeOutput(_ text: String) {
        outputBuffer += text
        // Keep buffer manageable
        if outputBuffer.count > 4000 {
            outputBuffer = String(outputBuffer.suffix(2000))
        }

        let oldState = state
        let lower = text.lowercased()

        // Detect Claude Code states from terminal output patterns
        if lower.contains("thinking") || lower.contains("⠋") || lower.contains("⠙") || lower.contains("⠹") {
            state = .thinking
        } else if lower.contains("writing") || lower.contains("generating") || lower.contains("editing") {
            state = .generating
        } else if lower.contains("error") || lower.contains("failed") || lower.contains("permission") {
            state = .needsAttention
        } else if lower.contains("❯") || lower.contains("> ") || lower.contains("$ ") {
            state = .userInput
        }

        // Parse cost/token info if present
        if let costRange = text.range(of: #"\$[\d.]+"#, options: .regularExpression) {
            let costStr = String(text[costRange]).dropFirst()
            if let parsedCost = Double(costStr), parsedCost > 0 {
                cost = parsedCost
            }
        }

        // Parse token counts
        if let tokenRange = text.range(of: #"(\d+\.?\d*)[Kk]\s*tokens?"#, options: .regularExpression) {
            let tokenStr = String(text[tokenRange])
            if let numRange = tokenStr.range(of: #"\d+\.?\d*"#, options: .regularExpression) {
                if let num = Double(String(tokenStr[numRange])) {
                    tokensIn = Int(num * 1000)
                }
            }
        }

        // Detect model from output
        if lower.contains("opus") {
            model = "opus"
        } else if lower.contains("sonnet") {
            model = "sonnet"
        } else if lower.contains("haiku") {
            model = "haiku"
        }

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

    private init() {}

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
        // Build environment with PWD set to worktree dir if applicable
        var env: [String] = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        if let wtPath = worktreePath {
            env = env.filter { !$0.hasPrefix("PWD=") }
            env.append("PWD=\(wtPath)")
        }

        if let cmd = command {
            // Run a specific command
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
