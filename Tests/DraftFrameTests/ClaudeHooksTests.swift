import XCTest

@testable import DraftFrameKit

final class ClaudeHooksTests: XCTestCase {

  private let command = "'/Users/me/Library/Application Support/DraftFrame/hook-bridge.sh'"

  /// A user-authored hook that must survive every merge and removal.
  private let userSound: [String: Any] = [
    "hooks": [["type": "command", "command": "afplay /System/Library/Sounds/Hero.aiff"]]
  ]

  func testMergingIntoEmptyWiresEveryEvent() {
    let merged = ClaudeHooks.merging(hooks: nil, command: command)
    XCTAssertEqual(Set(merged.keys), Set(ClaudeHooks.eventNames))
    for event in ClaudeHooks.events {
      let groups = merged[event.name] as? [[String: Any]]
      XCTAssertEqual(groups?.count, 1, event.name)
      let hook = (groups?.first?["hooks"] as? [[String: Any]])?.first
      XCTAssertEqual(hook?["type"] as? String, "command")
      XCTAssertEqual(hook?["command"] as? String, command)
      XCTAssertEqual(hook?["timeout"] as? Int, 5)
      XCTAssertEqual(hook?["async"] as? Bool, event.async ? true : nil, event.name)
      // No matcher: the bridge wants every occurrence of the event.
      XCTAssertNil(groups?.first?["matcher"])
    }
  }

  func testMergingPreservesUserHooksOnTheSameEvent() {
    let existing: [String: Any] = ["Stop": [userSound], "PreCompact": [userSound]]
    let merged = ClaudeHooks.merging(hooks: existing, command: command)
    let stop = merged["Stop"] as? [[String: Any]]
    XCTAssertEqual(stop?.count, 2)
    XCTAssertFalse(ClaudeHooks.isManaged(group: stop![0]))
    XCTAssertTrue(ClaudeHooks.isManaged(group: stop![1]))
    // Events DraftFrame doesn't use pass through untouched.
    XCTAssertEqual((merged["PreCompact"] as? [[String: Any]])?.count, 1)
  }

  func testMergingIsIdempotent() {
    let once = ClaudeHooks.merging(hooks: ["Stop": [userSound]], command: command)
    let twice = ClaudeHooks.merging(hooks: once, command: command)
    XCTAssertEqual((twice["Stop"] as? [[String: Any]])?.count, 2)
    XCTAssertEqual((twice["SessionStart"] as? [[String: Any]])?.count, 1)
  }

  func testMergingReplacesStaleManagedCommand() {
    let stale = ClaudeHooks.merging(hooks: nil, command: "'/old/DraftFrame/hook-bridge.sh'")
    let fresh = ClaudeHooks.merging(hooks: stale, command: command)
    let hook = ((fresh["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first
    XCTAssertEqual(hook?["command"] as? String, command)
    XCTAssertEqual((fresh["Stop"] as? [[String: Any]])?.count, 1)
  }

  func testRemovingManagedLeavesUserHooksAndDropsEmptyEvents() {
    let merged = ClaudeHooks.merging(hooks: ["Stop": [userSound]], command: command)
    let remaining = ClaudeHooks.removingManaged(hooks: merged)
    XCTAssertEqual(remaining?.keys.sorted(), ["Stop"])
    XCTAssertEqual((remaining?["Stop"] as? [[String: Any]])?.count, 1)
  }

  func testRemovingManagedReturnsNilWhenNothingLeft() {
    let merged = ClaudeHooks.merging(hooks: nil, command: command)
    XCTAssertNil(ClaudeHooks.removingManaged(hooks: merged))
  }

  func testManagedEventsDetectsPartialInstall() {
    var merged = ClaudeHooks.merging(hooks: nil, command: command)
    merged.removeValue(forKey: "Notification")
    let events = ClaudeHooks.managedEvents(in: merged)
    XCTAssertEqual(events, Set(ClaudeHooks.eventNames).subtracting(["Notification"]))
    XCTAssertEqual(ClaudeHooks.managedEvents(in: ["Stop": [userSound]]), [])
    XCTAssertEqual(ClaudeHooks.managedEvents(in: nil), [])
  }

  func testUnexpectedShapesPassThroughUntouched() {
    // A non-array value under an event name is left alone, not crashed on.
    let odd: [String: Any] = ["Stop": "oops", "Notification": [userSound]]
    let remaining = ClaudeHooks.removingManaged(hooks: odd)
    XCTAssertEqual(remaining?["Stop"] as? String, "oops")
    let merged = ClaudeHooks.merging(hooks: odd, command: command)
    XCTAssertEqual(merged["Stop"] as? String, "oops")
  }

  func testStopAndSessionBoundariesAreSynchronous() {
    // An async Stop can race a still-running async PostToolUse and lose.
    let sync = Set(ClaudeHooks.events.filter { !$0.async }.map(\.name))
    XCTAssertEqual(sync, ["SessionStart", "Stop", "SessionEnd"])
  }

  func testBridgeScriptInvariants() {
    let script = ClaudeHooks.bridgeScript
    XCTAssertTrue(script.hasPrefix("#!/bin/sh\n"))
    // Must never block Claude Code: every path exits 0, including the early
    // bail for sessions launched outside DraftFrame.
    XCTAssertFalse(script.contains("exit 1"))
    XCTAssertFalse(script.contains("exit 2"))
    XCTAssertTrue(script.hasSuffix("exit 0\n"))
    XCTAssertTrue(script.contains("[ -n \"$\(ClaudeHooks.tabEnvVar)\" ] || exit 0"))
    XCTAssertTrue(script.contains("${\(ClaudeHooks.socketEnvVar):-"))
    XCTAssertTrue(ClaudeHooks.hookCommand.contains(ClaudeHooks.marker))
    XCTAssertTrue(ClaudeHooks.hookCommand.hasPrefix("'"), "path has a space; must be quoted")
  }
}
