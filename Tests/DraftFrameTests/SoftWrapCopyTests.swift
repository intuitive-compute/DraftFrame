import SwiftTerm
import XCTest

@testable import DraftFrameKit

private final class StubTerminalDelegate: TerminalDelegate {
  func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

final class SoftWrapCopyTests: XCTestCase {

  private func makeTerminal(cols: Int, rows: Int) -> (Terminal, StubTerminalDelegate) {
    let delegate = StubTerminalDelegate()
    let terminal = Terminal(delegate: delegate)
    terminal.resize(cols: cols, rows: rows)
    return (terminal, delegate)
  }

  func testSoftWrappedCommandCopiesAsSingleLine() {
    let (terminal, _) = makeTerminal(cols: 20, rows: 24)
    let command = "echo hello-this-is-a-very-long-command"
    XCTAssertGreaterThan(command.count, 20, "command must be long enough to soft-wrap at 20 cols")

    terminal.feed(text: command + "\r\n")

    let start = Position(col: 0, row: 0)
    let end = Position(col: 20, row: 1)
    let copied = terminal.getText(start: start, end: end)

    XCTAssertEqual(
      copied, command,
      "Soft-wrapped selection should join continuation rows with no newline or padding. Got: \(copied.debugDescription)"
    )
  }

  func testHardNewlinesArePreserved() {
    let (terminal, _) = makeTerminal(cols: 40, rows: 24)
    terminal.feed(text: "line one\r\nline two\r\n")

    let copied = terminal.getText(start: Position(col: 0, row: 0), end: Position(col: 8, row: 1))

    XCTAssertEqual(
      copied, "line one\nline two",
      "Distinct logical lines must be separated by a single newline. Got: \(copied.debugDescription)"
    )
  }

  func testMixedHardAndSoftWrap() {
    let (terminal, _) = makeTerminal(cols: 20, rows: 24)
    let longCommand = "echo hello-this-is-a-very-long-command"
    terminal.feed(text: longCommand + "\r\nshort\r\n")

    let copied = terminal.getText(start: Position(col: 0, row: 0), end: Position(col: 5, row: 2))

    XCTAssertEqual(
      copied, longCommand + "\nshort",
      "Soft-wrap should join, hard newline should be preserved. Got: \(copied.debugDescription)")
  }
}
