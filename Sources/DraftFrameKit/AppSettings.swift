import Foundation

/// UserDefaults-backed app-wide defaults. These seed new sessions and
/// worktrees; explicit per-worktree toggles (sidebar PR action rows) and
/// per-watchdog edits still override them.
enum AppSettings {
  private static let defaults = UserDefaults.standard

  private static let autoFixKey = "DFDefaultPRAutoFix"
  private static let autoMergeKey = "DFDefaultPRAutoMerge"
  private static let autoArchiveKey = "DFDefaultPRAutoArchive"
  private static let watchdogKeyPrefix = "DFWatchdogEnabled."

  /// PR automation config applied to any worktree the user hasn't
  /// explicitly configured via the sidebar rows.
  static var defaultPRConfig: PRMonitorConfig {
    get {
      PRMonitorConfig(
        autoFix: defaults.bool(forKey: autoFixKey),
        autoMerge: defaults.bool(forKey: autoMergeKey),
        autoArchive: defaults.bool(forKey: autoArchiveKey)
      )
    }
    set {
      defaults.set(newValue.autoFix, forKey: autoFixKey)
      defaults.set(newValue.autoMerge, forKey: autoMergeKey)
      defaults.set(newValue.autoArchive, forKey: autoArchiveKey)
    }
  }

  /// Persisted enabled state for a built-in watchdog, or `fallback` if the
  /// user has never toggled it.
  static func watchdogEnabled(name: String, fallback: Bool) -> Bool {
    let key = watchdogKeyPrefix + name
    guard defaults.object(forKey: key) != nil else { return fallback }
    return defaults.bool(forKey: key)
  }

  static func setWatchdogEnabled(name: String, _ enabled: Bool) {
    defaults.set(enabled, forKey: watchdogKeyPrefix + name)
  }
}
