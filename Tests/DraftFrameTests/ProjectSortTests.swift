import XCTest

@testable import DraftFrameKit

final class ProjectSortTests: XCTestCase {

  private func projects(_ paths: [String]) -> [ProjectManager.Project] {
    paths.map { ProjectManager.Project(path: $0, isExpanded: true) }
  }

  func testRecentKeepsStoredOrder() {
    let input = projects(["/a/zebra", "/a/apple", "/a/mango"])
    let sorted = ProjectManager.sort(input, by: .recent, activeProjectPaths: [])
    XCTAssertEqual(sorted.map { $0.path }, ["/a/zebra", "/a/apple", "/a/mango"])
  }

  func testNameAscendingSortsCaseInsensitively() {
    let input = projects(["/a/zebra", "/a/Apple", "/a/mango"])
    let sorted = ProjectManager.sort(input, by: .nameAscending, activeProjectPaths: [])
    XCTAssertEqual(sorted.map { $0.name }, ["Apple", "mango", "zebra"])
  }

  func testNameDescending() {
    let input = projects(["/a/apple", "/a/zebra", "/a/mango"])
    let sorted = ProjectManager.sort(input, by: .nameDescending, activeProjectPaths: [])
    XCTAssertEqual(sorted.map { $0.name }, ["zebra", "mango", "apple"])
  }

  func testNameSortIsStableForEqualNames() {
    let input = projects(["/first/repo", "/second/repo", "/a/apple"])
    let sorted = ProjectManager.sort(input, by: .nameAscending, activeProjectPaths: [])
    XCTAssertEqual(sorted.map { $0.path }, ["/a/apple", "/first/repo", "/second/repo"])
  }

  func testActiveSessionsFloatToTopKeepingRecencyWithinGroups() {
    let input = projects(["/a/one", "/a/two", "/a/three", "/a/four"])
    let sorted = ProjectManager.sort(
      input, by: .activeSessions, activeProjectPaths: ["/a/three", "/a/two"])
    XCTAssertEqual(sorted.map { $0.path }, ["/a/two", "/a/three", "/a/one", "/a/four"])
  }

  func testSortOrderDisplayNames() {
    XCTAssertEqual(ProjectManager.SortOrder.recent.displayName, "Recent")
    XCTAssertEqual(ProjectManager.SortOrder.activeSessions.displayName, "Active Sessions")
    XCTAssertEqual(ProjectManager.SortOrder.nameAscending.displayName, "A-Z")
    XCTAssertEqual(ProjectManager.SortOrder.nameDescending.displayName, "Z-A")
  }
}
