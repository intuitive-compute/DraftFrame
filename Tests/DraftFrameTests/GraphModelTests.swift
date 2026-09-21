import XCTest

@testable import DraftFrameKit

final class GraphModelTests: XCTestCase {

  private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

  private func root(pr: GraphPRInput? = nil, state: SessionState = .generating) -> GraphSessionInput
  {
    GraphSessionInput(
      id: UUID(), displayName: "coordinator", branch: "coordinator", state: state,
      model: "fable", cost: 4.25, pr: pr)
  }

  private func agent(
    _ id: String, skill: String?, status: SubagentRecord.Status = .completed,
    offset: TimeInterval = 0,
    type: String? = "general-purpose", cost: Double = 0.5
  ) -> SubagentRecord {
    SubagentRecord(
      agentID: id, transcriptPath: "/t/agent-\(id).jsonl", agentType: type, skill: skill,
      model: "opus", promptSummary: "You are a reviewer", startedAt: t0.addingTimeInterval(offset),
      lastActivityAt: t0.addingTimeInterval(offset + 90), status: status, cost: cost,
      tokensIn: 10, tokensOut: 5, turns: 3)
  }

  // MARK: - Builder

  func testRootOnlyModel() {
    let r = root()
    let model = GraphModelBuilder.build(root: r, agents: [])
    XCTAssertEqual(model.nodes.count, 1)
    let node = model.nodes[0]
    XCTAssertEqual(node.kind, .session)
    XCTAssertEqual(node.sessionID, r.id)
    XCTAssertTrue(node.isActive, "a generating session is drawn live")
    XCTAssertEqual(node.detail, "Generating · $4.25 · No sub-agents")
    XCTAssertTrue(model.edges.isEmpty)
  }

  func testPullRequestHangsOffRoot() {
    let r = root(pr: GraphPRInput(number: 12, text: "PR#12 failing", color: .red, isOpen: true))
    let model = GraphModelBuilder.build(root: r, agents: [])
    let pr = model.nodes(of: .pullRequest)
    XCTAssertEqual(pr.map(\.title), ["PR #12"])
    XCTAssertEqual(model.parents(of: pr[0].id), [GraphModelBuilder.sessionNodeID(r.id)])
  }

  func testAgentsGroupUnderStagesInFirstDispatchOrder() {
    let r = root()
    let agents = [
      agent("a", skill: "code-review", offset: 0),
      agent("b", skill: nil, offset: 10),
      agent("c", skill: "hardened-fix-pipeline", status: .running, offset: 20),
      agent("d", skill: "code-review", offset: 30, cost: 1.0),
    ]
    let model = GraphModelBuilder.build(root: r, agents: agents)
    let rootID = GraphModelBuilder.sessionNodeID(r.id)

    XCTAssertEqual(model.nodes(of: .stage).map(\.title), ["code-review", "hardened-fix-pipeline"])
    XCTAssertEqual(
      model.nodes(of: .agent).map(\.id),
      ["agent:a", "agent:d", "agent:c", "agent:b"].map { $0 },
      "agents are contiguous per stage, skill-less agents last")

    XCTAssertEqual(model.parents(of: "agent:a"), ["stage:code-review"])
    XCTAssertEqual(model.parents(of: "agent:b"), [rootID], "no skill: hangs off the session")
    XCTAssertEqual(model.parents(of: "stage:code-review"), [rootID])

    let review = model.node(id: "stage:code-review")!
    XCTAssertEqual(review.subtitle, "2 agents")
    XCTAssertEqual(review.detail, "$1.50")
    XCTAssertFalse(review.isActive)
    let fix = model.node(id: "stage:hardened-fix-pipeline")!
    XCTAssertEqual(fix.detail, "1 running · $0.50")
    XCTAssertTrue(fix.isActive)

    XCTAssertEqual(model.node(id: rootID)?.detail, "Generating · $4.25 · 4 agents · 1 running")
  }

  func testAgentNodeCarriesStatusAndTranscript() {
    let r = root()
    let model = GraphModelBuilder.build(
      root: r,
      agents: [
        agent("run", skill: nil, status: .running),
        agent("done", skill: nil, status: .completed),
        agent("dead", skill: nil, status: .stopped, type: nil),
      ])
    let run = model.node(id: "agent:run")!
    XCTAssertEqual(run.title, "general-purpose")
    XCTAssertEqual(run.detail, "Running · opus · 1m · $0.50")
    XCTAssertEqual(run.filePath, "/t/agent-run.jsonl")
    XCTAssertTrue(run.isActive)
    XCTAssertEqual(model.edges.first { $0.to == "agent:run" }?.style, .solid)

    let done = model.node(id: "agent:done")!
    XCTAssertTrue(done.detail.hasPrefix("Done"))
    XCTAssertEqual(model.edges.first { $0.to == "agent:done" }?.style, .dashed)

    let dead = model.node(id: "agent:dead")!
    XCTAssertEqual(dead.title, "agent", "missing agent type falls back to a generic title")
    XCTAssertTrue(dead.isMuted)
  }

  func testFormatDuration() {
    XCTAssertEqual(GraphModelBuilder.formatDuration(5), "5s")
    XCTAssertEqual(GraphModelBuilder.formatDuration(125), "2m")
    XCTAssertEqual(GraphModelBuilder.formatDuration(3725), "1h02m")
  }

  // MARK: - Layout

  func testLayoutWithoutStagesUsesTwoColumns() {
    let r = root()
    let model = GraphModelBuilder.build(
      root: r, agents: [agent("a", skill: nil), agent("b", skill: nil), agent("c", skill: nil)])
    let result = GraphLayout.layout(model)

    XCTAssertEqual(result.columnTitles, [0: "SESSION", 1: "AGENTS"])
    XCTAssertEqual(result.positions["agent:a"], GraphLayout.origin(column: 1, row: 0))
    XCTAssertEqual(result.positions["agent:c"], GraphLayout.origin(column: 1, row: 2))
    XCTAssertEqual(
      result.positions[GraphModelBuilder.sessionNodeID(r.id)],
      GraphLayout.origin(column: 0, row: 0), "root stays at the top")
  }

  func testLayoutWithStagesTopAlignsEachLayer() {
    let r = root(pr: GraphPRInput(number: 1, text: "PR#1", color: .green, isOpen: true))
    let model = GraphModelBuilder.build(
      root: r,
      agents: [
        agent("a", skill: "review", offset: 0),
        agent("b", skill: "review", offset: 1),
        agent("c", skill: "fix", offset: 2),
        agent("d", skill: nil, offset: 3),
      ])
    let result = GraphLayout.layout(model)

    XCTAssertEqual(result.columnTitles, [0: "SESSION", 1: "STAGES", 2: "AGENTS"])
    // Agent rows: a0 b1 c2 d3 (stage groups first, then skill-less).
    XCTAssertEqual(result.positions["agent:d"], GraphLayout.origin(column: 2, row: 3))
    XCTAssertEqual(
      result.positions["stage:review"], GraphLayout.origin(column: 1, row: 0),
      "a stage aligns with its first agent")
    XCTAssertEqual(result.positions["stage:fix"], GraphLayout.origin(column: 1, row: 2))
    let rootID = GraphModelBuilder.sessionNodeID(r.id)
    XCTAssertEqual(result.positions[rootID], GraphLayout.origin(column: 0, row: 0))
    XCTAssertEqual(
      result.positions[GraphModelBuilder.prNodeID(r.id)], GraphLayout.origin(column: 0, row: 1),
      "PR sits directly under the session")

    let size = GraphLayout.contentSize(positions: result.positions)
    XCTAssertEqual(
      size.width,
      GraphLayout.origin(column: 2, row: 0).x + GraphLayout.nodeSize.width + GraphLayout.margin)
    XCTAssertEqual(
      size.height,
      GraphLayout.origin(column: 0, row: 3).y + GraphLayout.nodeSize.height + GraphLayout.margin)
  }

  func testLayoutOfEmptyModel() {
    let result = GraphLayout.layout(GraphModel())
    XCTAssertTrue(result.positions.isEmpty)
    XCTAssertEqual(result.columnTitles, [0: "SESSION"])
  }
}
