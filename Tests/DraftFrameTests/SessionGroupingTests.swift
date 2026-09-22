import XCTest

@testable import DraftFrameKit

final class SessionGroupingTests: XCTestCase {

  // MARK: - Display order

  func testDisplayOrderPutsGroupsFirstInGroupOrderThenUngrouped() {
    let a = UUID()
    let b = UUID()
    // Sessions: 0 ungrouped, 1 in b, 2 in a, 3 in b, 4 ungrouped, 5 in a
    let ids: [UUID?] = [nil, b, a, b, nil, a]
    let order = SessionGrouping.displayOrder(groupIDs: ids, groupOrder: [a, b])
    XCTAssertEqual(order, [2, 5, 1, 3, 0, 4])
  }

  func testDisplayOrderIsStableWithinBlocks() {
    let a = UUID()
    let ids: [UUID?] = [a, a, nil, a, nil]
    let order = SessionGrouping.displayOrder(groupIDs: ids, groupOrder: [a])
    XCTAssertEqual(order, [0, 1, 3, 2, 4])
  }

  func testDisplayOrderTreatsUnknownGroupAsUngrouped() {
    let a = UUID()
    let gone = UUID()
    let ids: [UUID?] = [gone, a, nil]
    let order = SessionGrouping.displayOrder(groupIDs: ids, groupOrder: [a])
    XCTAssertEqual(order, [1, 0, 2])
  }

  func testDisplayOrderWithNoGroupsIsIdentity() {
    let order = SessionGrouping.displayOrder(groupIDs: [nil, nil, nil], groupOrder: [])
    XCTAssertEqual(order, [0, 1, 2])
  }

  // MARK: - Moving groups

  func testMovingShiftsForwardAndBackward() {
    let items = ["a", "b", "c", "d"]
    XCTAssertEqual(SessionGrouping.moving(items, from: 0, to: 4), ["b", "c", "d", "a"])
    XCTAssertEqual(SessionGrouping.moving(items, from: 3, to: 0), ["d", "a", "b", "c"])
    XCTAssertEqual(SessionGrouping.moving(items, from: 0, to: 2), ["b", "a", "c", "d"])
    XCTAssertEqual(SessionGrouping.moving(items, from: 2, to: 1), ["a", "c", "b", "d"])
  }

  func testMovingReturnsNilForNoOpsAndBadIndices() {
    XCTAssertNil(SessionGrouping.moving(["a", "b", "c"], from: 1, to: 1))
    XCTAssertNil(SessionGrouping.moving(["a", "b", "c"], from: 1, to: 2))
    XCTAssertNil(SessionGrouping.moving(["a", "b", "c"], from: -1, to: 0))
    XCTAssertNil(SessionGrouping.moving(["a", "b", "c"], from: 3, to: 0))
    XCTAssertNil(SessionGrouping.moving(["a", "b", "c"], from: 0, to: 4))
    XCTAssertNil(SessionGrouping.moving([String](), from: 0, to: 0))
  }

  @MainActor
  func testManagerMoveGroupReordersGroupsAndKeepsMembersTogether() {
    let mgr = SessionManager.shared
    let a = mgr.createGroup(name: "move-a", color: .red)
    let b = mgr.createGroup(name: "move-b", color: .green)
    let c = mgr.createGroup(name: "move-c", color: .blue)
    defer { for g in [a, b, c] { mgr.deleteGroup(id: g.id) } }
    let base = mgr.groups.count - 3

    mgr.moveGroup(from: base + 2, to: base)
    XCTAssertEqual(mgr.groups.suffix(3).map(\.name), ["move-c", "move-a", "move-b"])

    mgr.moveGroup(id: a.id, to: mgr.groups.count)
    XCTAssertEqual(mgr.groups.suffix(3).map(\.name), ["move-c", "move-b", "move-a"])

    // Out-of-range and no-op moves leave the order alone.
    mgr.moveGroup(from: -1, to: 0)
    mgr.moveGroup(from: base, to: base + 1)
    mgr.moveGroup(id: UUID(), to: 0)
    XCTAssertEqual(mgr.groups.suffix(3).map(\.name), ["move-c", "move-b", "move-a"])

    // With no sessions the display order is trivially consistent; the
    // session-level guarantee comes from displayOrder, covered above.
    let order = SessionGrouping.displayOrder(
      groupIDs: mgr.sessions.map(\.groupID), groupOrder: mgr.groups.map(\.id))
    XCTAssertEqual(mgr.sessions.indices.map { $0 }, order)
  }

  // MARK: - Colors

  func testHexRoundTrip() {
    for color in SessionGrouping.palette {
      let hex = SessionGrouping.hexString(color)
      XCTAssertEqual(hex.count, 7)
      let back = SessionGrouping.color(fromHex: hex)
      XCTAssertNotNil(back)
      XCTAssertEqual(back.map(SessionGrouping.hexString), hex)
    }
    XCTAssertEqual(
      SessionGrouping.color(fromHex: "ff9500").map(SessionGrouping.hexString), "#FF9500")
    XCTAssertNil(SessionGrouping.color(fromHex: "nope"))
    XCTAssertNil(SessionGrouping.color(fromHex: "#FFF"))
  }

  func testRandomColorsAreDistinctAndAvoidUsedOnes() {
    let used = Array(SessionGrouping.palette.prefix(3))
    let picked = SessionGrouping.randomColors(count: 3, avoiding: used)
    let hexes = picked.map(SessionGrouping.hexString)
    XCTAssertEqual(Set(hexes).count, 3)
    for h in hexes {
      XCTAssertFalse(used.map(SessionGrouping.hexString).contains(h))
    }
  }

  func testRandomColorsWrapsWhenPaletteExhausted() {
    let picked = SessionGrouping.randomColors(count: SessionGrouping.palette.count + 2)
    XCTAssertEqual(picked.count, SessionGrouping.palette.count + 2)
  }

  // MARK: - Persistence format

  func testSessionsFileDecodesWithoutGroups() throws {
    let json = """
      {"projectDir":"/p","sessions":[{"name":"a","worktreePath":null,"agent":"claude","agentSessionId":null}],"activeSessionIndex":0}
      """
    let file = try JSONDecoder().decode(
      SessionPersistence.SessionsFile.self, from: Data(json.utf8))
    XCTAssertNil(file.groups)
    XCTAssertNil(file.sessions[0].groupID)
  }

  func testSessionsFileRoundTripsGroups() throws {
    let gid = UUID()
    let file = SessionPersistence.SessionsFile(
      projectDir: "/p",
      sessions: [
        .init(name: "a", worktreePath: nil, agent: "claude", agentSessionId: nil, groupID: gid)
      ],
      activeSessionIndex: 0,
      groups: [.init(id: gid, name: "In QA", color: "#32D4DE", isCollapsed: true)])
    let data = try JSONEncoder().encode(file)
    let back = try JSONDecoder().decode(SessionPersistence.SessionsFile.self, from: data)
    XCTAssertEqual(back.groups?.count, 1)
    XCTAssertEqual(back.groups?[0].id, gid)
    XCTAssertEqual(back.groups?[0].name, "In QA")
    XCTAssertEqual(back.groups?[0].isCollapsed, true)
    XCTAssertEqual(back.sessions[0].groupID, gid)
  }

  func testDedupingResumeIdsKeepsGroup() {
    let gid = UUID()
    let deduped = SessionPersistence.dedupingResumeIds([
      .init(name: "a", worktreePath: nil, agent: "claude", agentSessionId: "x", groupID: gid),
      .init(name: "b", worktreePath: nil, agent: "claude", agentSessionId: "x", groupID: gid),
    ])
    XCTAssertNil(deduped[1].agentSessionId)
    XCTAssertEqual(deduped[1].groupID, gid)
  }
}
