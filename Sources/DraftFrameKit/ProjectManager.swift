import Foundation

/// Manages the list of opened projects and their expanded/collapsed state.
/// Persists to ~/.config/draftframe/projects.json.
final class ProjectManager {
  static let shared = ProjectManager()

  struct Project: Codable {
    let path: String
    var isExpanded: Bool

    var name: String { (path as NSString).lastPathComponent }
  }

  private(set) var projects: [Project] = []

  private static let configPath = NSHomeDirectory() + "/.config/draftframe/projects.json"

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
