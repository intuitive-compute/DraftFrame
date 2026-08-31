import Foundation

/// Manages the list of opened projects and their expanded/collapsed state.
/// Persists to ~/.config/draftframe/projects.json.
@MainActor
final class ProjectManager {
  static let shared = ProjectManager()

  struct Project: Codable {
    let path: String
    var isExpanded: Bool

    var name: String { (path as NSString).lastPathComponent }
  }

  /// How the sidebar orders the project list.
  enum SortOrder: String, CaseIterable {
    case recent
    case activeSessions
    case nameAscending
    case nameDescending

    var displayName: String {
      switch self {
      case .recent: return "Recent"
      case .activeSessions: return "Active Sessions"
      case .nameAscending: return "A-Z"
      case .nameDescending: return "Z-A"
      }
    }
  }

  private(set) var projects: [Project] = []

  private static let configPath = NSHomeDirectory() + "/.config/draftframe/projects.json"
  private static let sortOrderKey = "DFProjectSortOrder"

  var sortOrder: SortOrder {
    get {
      SortOrder(rawValue: UserDefaults.standard.string(forKey: Self.sortOrderKey) ?? "")
        ?? .recent
    }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.sortOrderKey) }
  }

  /// Projects in the persisted sort order. The stored array is already
  /// most-recently-opened first, so `.recent` returns it as-is; the other
  /// orders are stable reorderings of it (ties keep recency order).
  func sortedProjects(activeProjectPaths: Set<String> = []) -> [Project] {
    Self.sort(projects, by: sortOrder, activeProjectPaths: activeProjectPaths)
  }

  nonisolated static func sort(
    _ projects: [Project], by order: SortOrder, activeProjectPaths: Set<String>
  ) -> [Project] {
    switch order {
    case .recent:
      return projects
    case .activeSessions:
      return projects.filter { activeProjectPaths.contains($0.path) }
        + projects.filter { !activeProjectPaths.contains($0.path) }
    case .nameAscending:
      return projects.enumerated().sorted {
        switch $0.element.name.localizedCaseInsensitiveCompare($1.element.name) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return $0.offset < $1.offset
        }
      }.map { $0.element }
    case .nameDescending:
      return projects.enumerated().sorted {
        switch $0.element.name.localizedCaseInsensitiveCompare($1.element.name) {
        case .orderedAscending: return false
        case .orderedDescending: return true
        case .orderedSame: return $0.offset < $1.offset
        }
      }.map { $0.element }
    }
  }

  private init() {
    load()
  }

  /// Add a project (or move it to front if already present).
  func addProject(path: String) {
    // Remove if already exists
    projects.removeAll { $0.path == path }
    // Insert at front, expanded
    projects.insert(Project(path: path, isExpanded: true), at: 0)
    save()
  }

  /// Remove a project from the list.
  func removeProject(path: String) {
    projects.removeAll { $0.path == path }
    save()
  }

  /// Toggle expanded/collapsed for a project.
  func toggleExpanded(path: String) {
    if let idx = projects.firstIndex(where: { $0.path == path }) {
      projects[idx].isExpanded = !projects[idx].isExpanded
      save()
    }
  }

  /// Set expanded state.
  func setExpanded(path: String, expanded: Bool) {
    if let idx = projects.firstIndex(where: { $0.path == path }) {
      projects[idx].isExpanded = expanded
      save()
    }
  }

  // MARK: - Persistence

  private func save() {
    // QA runs share this file with real launches; never let their throwaway
    // projects overwrite the user's project list.
    if QABridge.isQAMode { return }
    let dir = (ProjectManager.configPath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(projects) {
      try? data.write(to: URL(fileURLWithPath: ProjectManager.configPath))
    }
  }

  private func load() {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: ProjectManager.configPath)),
      let loaded = try? JSONDecoder().decode([Project].self, from: data)
    else {
      return
    }
    // Filter out projects whose directories no longer exist
    projects = loaded.filter { FileManager.default.fileExists(atPath: $0.path) }
  }
}
