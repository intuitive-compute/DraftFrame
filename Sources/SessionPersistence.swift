import Foundation

/// Saves and restores session names and worktree paths across app launches.
/// Persists to ~/.config/draftframe/sessions.json.
final class SessionPersistence {
    static let shared = SessionPersistence()

    private static let configDir = NSHomeDirectory() + "/.config/draftframe"
    private static let sessionsPath = configDir + "/sessions.json"

    private init() {}

    // MARK: - Data Model

    struct SavedSession: Codable {
        let name: String
        let worktreePath: String?
    }

    struct SessionsFile: Codable {
        let projectDir: String
        let sessions: [SavedSession]
    }

    // MARK: - Save

    /// Save current sessions to disk. Call before quitting.
    func saveSessions() {
        let sessions = SessionManager.shared.sessions
        guard !sessions.isEmpty else { return }

        let projectDir = SessionManager.shared.projectDir ?? FileManager.default.currentDirectoryPath

        let saved = sessions.map { session in
            SavedSession(name: session.name, worktreePath: session.worktreePath)
        }

        let file = SessionsFile(projectDir: projectDir, sessions: saved)

        let fm = FileManager.default
        let dir = SessionPersistence.configDir
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        if let data = try? encoder.encode(file) {
            fm.createFile(atPath: SessionPersistence.sessionsPath, contents: data)
        }
    }

    // MARK: - Restore

    /// Check if there are saved sessions for the given project directory.
    func hasSavedSessions(for projectDir: String) -> Bool {
        guard let file = loadSessionsFile() else { return false }
        return file.projectDir == projectDir && !file.sessions.isEmpty
    }

    /// Load saved sessions from disk. Returns nil if no file or wrong project.
    func loadSavedSessions(for projectDir: String) -> [SavedSession]? {
        guard let file = loadSessionsFile() else { return nil }
        guard file.projectDir == projectDir, !file.sessions.isEmpty else { return nil }
        return file.sessions
    }

    /// Restore saved sessions by creating them in SessionManager.
    func restoreSessions(for projectDir: String) {
        guard let saved = loadSavedSessions(for: projectDir) else { return }

        for entry in saved {
            // Verify worktree path still exists if specified
            var wtPath = entry.worktreePath
            if let path = wtPath, !FileManager.default.fileExists(atPath: path) {
                wtPath = nil
            }

            SessionManager.shared.createSession(name: entry.name, worktreePath: wtPath ?? projectDir)
        }

        // Clear the saved file after restoring
        clearSavedSessions()
    }

    /// Remove the saved sessions file.
    func clearSavedSessions() {
        try? FileManager.default.removeItem(atPath: SessionPersistence.sessionsPath)
    }

    // MARK: - Private

    private func loadSessionsFile() -> SessionsFile? {
        guard let data = FileManager.default.contents(atPath: SessionPersistence.sessionsPath) else {
            return nil
        }
        return try? JSONDecoder().decode(SessionsFile.self, from: data)
    }
}
