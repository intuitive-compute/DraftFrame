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
