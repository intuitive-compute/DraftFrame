import XCTest

@testable import DraftFrameKit

final class TicketLinkTests: XCTestCase {

  func testJiraBrowseURL() {
    XCTAssertEqual(
      TicketLink.suggestedName(from: "https://calm.atlassian.net/browse/ENG-1234"),
      "eng-1234")
  }

  func testJiraBoardSelectedIssueURL() {
    XCTAssertEqual(
      TicketLink.suggestedName(
        from: "https://calm.atlassian.net/jira/software/projects/ENG/boards/1?selectedIssue=ENG-42"
      ),
      "eng-42")
  }

  func testLinearKeyPlusSlugURL() {
    XCTAssertEqual(
      TicketLink.suggestedName(from: "https://linear.app/calm/issue/ENG-1234/fix-login-flow"),
      "eng-1234-fix-login-flow")
  }

  func testLinearCombinedSlugURL() {
    XCTAssertEqual(
      TicketLink.suggestedName(from: "https://linear.app/calm/issue/eng-1234-fix-login"),
      "eng-1234-fix-login")
  }

  func testGitHubIssueURL() {
    XCTAssertEqual(
      TicketLink.suggestedName(from: "https://github.com/calm/app/issues/987"),
      "issue-987")
  }

  func testGitHubPullURL() {
    XCTAssertEqual(
      TicketLink.suggestedName(from: "https://github.com/calm/app/pull/55"),
      "pr-55")
  }

  func testBareIssueKey() {
    XCTAssertEqual(TicketLink.suggestedName(from: "ENG-1234"), "eng-1234")
    XCTAssertEqual(TicketLink.suggestedName(from: "  ENG-1234  "), "eng-1234")
  }

  func testUnknownTrackerFallsBackToLastPathComponent() {
    XCTAssertEqual(
      TicketLink.suggestedName(from: "https://tracker.example.com/tickets/fix-the-thing"),
      "fix-the-thing")
  }

  func testUnknownTrackerPrefersIssueKeyInPath() {
    XCTAssertEqual(
      TicketLink.suggestedName(from: "https://tracker.example.com/ENG-77/some-long-title"),
      "eng-77")
  }

  func testEmptyAndGarbageInput() {
    XCTAssertNil(TicketLink.suggestedName(from: ""))
    XCTAssertNil(TicketLink.suggestedName(from: "   "))
    XCTAssertNil(TicketLink.suggestedName(from: "://"))
  }

  func testSlugIsCappedAndCleaned() {
    let long =
      "https://linear.app/calm/issue/ENG-1/"
      + "a-very-long-title-that-keeps-going-and-going-and-going-forever"
    let name = TicketLink.suggestedName(from: long)
    XCTAssertNotNil(name)
    XCTAssertLessThanOrEqual(name!.count, 40)
    XCTAssertFalse(name!.hasSuffix("-"))
  }

  func testKickoffPromptContainsTicket() {
    let prompt = TicketLink.kickoffPrompt(ticket: "https://calm.atlassian.net/browse/ENG-1")
    XCTAssertTrue(prompt.contains("https://calm.atlassian.net/browse/ENG-1"))
  }

  func testShellSingleQuote() {
    XCTAssertEqual(shellSingleQuote("plain"), "'plain'")
    XCTAssertEqual(shellSingleQuote("it's"), "'it'\\''s'")
  }
}
