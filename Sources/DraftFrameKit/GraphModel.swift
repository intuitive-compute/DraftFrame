import AppKit

// MARK: - Graph model

/// Graph of one DraftFrame session and the work its harness spawned: the
/// coordinator session at the root, the skills that dispatched sub-agents as
/// stages, and every sub-agent as a leaf. Step 1 of
/// docs/graph-engineering.md. Built from plain inputs by
/// `GraphModelBuilder` so the shape is unit-testable without a window.

enum GraphNodeKind: String, CaseIterable {
  case session
  case pullRequest
  case stage
  case agent

  /// Small caption drawn above the node title.
  var caption: String {
    switch self {
    case .session: return "SESSION"
    case .pullRequest: return "PR"
    case .stage: return "STAGE"
    case .agent: return "AGENT"
    }
  }
}

struct GraphNode: Equatable, Identifiable {
  let id: String
  let kind: GraphNodeKind
  let title: String
  let subtitle: String
  let detail: String
  /// Status color: session state, PR rollup, or agent status.
  let accent: NSColor
  /// Set on session nodes so a click can jump to the terminal.
  let sessionID: UUID?
  /// Set on agent nodes so a click can open the transcript.
  let filePath: String?
  /// Dimmed rendering (stopped agent, closed PR).
  let isMuted: Bool
  /// Drawn with a pulsing border to mark live work.
  let isActive: Bool

  init(
    id: String, kind: GraphNodeKind, title: String, subtitle: String = "", detail: String = "",
    accent: NSColor = Theme.text3, sessionID: UUID? = nil, filePath: String? = nil,
    isMuted: Bool = false, isActive: Bool = false
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.subtitle = subtitle
    self.detail = detail
    self.accent = accent
    self.sessionID = sessionID
    self.filePath = filePath
    self.isMuted = isMuted
    self.isActive = isActive
  }
}

enum GraphEdgeStyle: Equatable {
  case solid
  case dashed
}

struct GraphEdge: Equatable {
  let from: String
  let to: String
  let style: GraphEdgeStyle
}

struct GraphModel: Equatable {
  var nodes: [GraphNode] = []
  var edges: [GraphEdge] = []

  func node(id: String) -> GraphNode? { nodes.first { $0.id == id } }
  func nodes(of kind: GraphNodeKind) -> [GraphNode] { nodes.filter { $0.kind == kind } }
  /// Ids of nodes with an edge into `id`, in edge order.
  func parents(of id: String) -> [String] { edges.filter { $0.to == id }.map(\.from) }
  func children(of id: String) -> [String] { edges.filter { $0.from == id }.map(\.to) }
}

// MARK: - Builder inputs

/// Plain-data view of a session. `Session` is a main-actor class wired to a
/// terminal; the builder takes this instead so it stays pure.
struct GraphSessionInput {
  let id: UUID
  let displayName: String
  let branch: String
  let state: SessionState
  let model: String
  let cost: Double
  let pr: GraphPRInput?
}

struct GraphPRInput {
  let number: Int
  let text: String
  let color: NSColor
  let isOpen: Bool
}

// MARK: - Builder

enum GraphModelBuilder {
  static func sessionNodeID(_ id: UUID) -> String { "session:\(id.uuidString)" }
  static func prNodeID(_ sessionID: UUID) -> String { "pr:\(sessionID.uuidString)" }
  static func stageNodeID(_ skill: String) -> String { "stage:\(skill)" }
  static func agentNodeID(_ agentID: String) -> String { "agent:\(agentID)" }

  /// - Parameters:
  ///   - root: the DraftFrame session whose flow is shown.
  ///   - agents: sub-agents its Claude Code session dispatched, oldest first.
  static func build(root: GraphSessionInput, agents: [SubagentRecord]) -> GraphModel {
    var model = GraphModel()
    let rootID = sessionNodeID(root.id)

    let running = agents.filter { $0.status == .running }.count
    let agentSummary: String
    switch (agents.count, running) {
    case (0, _): agentSummary = "No sub-agents"
    case (let n, 0): agentSummary = n == 1 ? "1 agent" : "\(n) agents"
    case (let n, let r): agentSummary = "\(n) agents · \(r) running"
    }
    model.nodes.append(
      GraphNode(
        id: rootID, kind: .session,
        title: root.displayName,
        subtitle: root.displayName == root.branch ? root.model : root.branch,
        detail: String(format: "%@ · $%.2f · %@", root.state.label, root.cost, agentSummary),
        accent: root.state.color,
        sessionID: root.id,
        isActive: root.state == .generating || root.state == .thinking))

    if let pr = root.pr {
      let prID = prNodeID(root.id)
      model.nodes.append(
        GraphNode(
          id: prID, kind: .pullRequest, title: "PR #\(pr.number)", subtitle: pr.text,
          accent: pr.color, isMuted: !pr.isOpen))
      model.edges.append(GraphEdge(from: rootID, to: prID, style: .solid))
    }

    // Stages: one per skill, in order of first dispatch. Agents without a
    // skill hang directly off the session.
    var stageOrder: [String] = []
    for agent in agents {
      if let skill = agent.skill, !stageOrder.contains(skill) { stageOrder.append(skill) }
    }
    for skill in stageOrder {
      let members = agents.filter { $0.skill == skill }
      let live = members.filter { $0.status == .running }.count
      let cost = members.reduce(0) { $0 + $1.cost }
      let stageID = stageNodeID(skill)
      model.nodes.append(
        GraphNode(
          id: stageID, kind: .stage, title: skill,
          subtitle: members.count == 1 ? "1 agent" : "\(members.count) agents",
          detail: String(format: "%@$%.2f", live > 0 ? "\(live) running · " : "", cost),
          accent: live > 0 ? Theme.green : Theme.accent,
          isActive: live > 0))
      model.edges.append(GraphEdge(from: rootID, to: stageID, style: .solid))
    }

    // Agents, grouped under their stage so stage groups are contiguous in
    // the layout; within a group, oldest first.
    var ordered: [SubagentRecord] = []
    for skill in stageOrder { ordered.append(contentsOf: agents.filter { $0.skill == skill }) }
    ordered.append(contentsOf: agents.filter { $0.skill == nil })

    for agent in ordered {
      let agentID = agentNodeID(agent.agentID)
      let statusText: String
      let accent: NSColor
      switch agent.status {
      case .running:
        statusText = "Running"
        accent = Theme.green
      case .completed:
        statusText = "Done"
        accent = Theme.cyan
      case .stopped:
        statusText = "Stopped"
        accent = Theme.text3
      }
      let elapsed = Self.formatDuration(agent.lastActivityAt.timeIntervalSince(agent.startedAt))
      model.nodes.append(
        GraphNode(
          id: agentID, kind: .agent,
          title: agent.displayTitle,
          subtitle: agent.promptSummary,
          detail: String(
            format: "%@ · %@ · %@ · $%.2f", statusText, agent.model, elapsed, agent.cost),
          accent: accent,
          filePath: agent.transcriptPath,
          isMuted: agent.status == .stopped,
          isActive: agent.status == .running))
      let parent = agent.skill.map(stageNodeID) ?? rootID
      model.edges.append(
        GraphEdge(from: parent, to: agentID, style: agent.status == .running ? .solid : .dashed))
    }

    return model
  }

  static func formatDuration(_ seconds: TimeInterval) -> String {
    let s = Int(max(0, seconds))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    return String(format: "%dh%02dm", s / 3600, (s % 3600) / 60)
  }

  // MARK: Live inputs

  /// Snapshot a running session and its cached sub-agents into a model.
  @MainActor
  static func liveModel(for session: Session) -> GraphModel {
    let pr = PRMonitor.shared.status(for: session.id).map {
      GraphPRInput(
        number: $0.number, text: $0.displayText, color: $0.displayColor,
        isOpen: $0.state == .open)
    }
    let root = GraphSessionInput(
      id: session.id, displayName: session.displayName, branch: session.name,
      state: session.state, model: session.model, cost: session.cost, pr: pr)
    return build(root: root, agents: SessionGraphSource.shared.records(for: session.id))
  }
}

// MARK: - Layout

/// Layered left-to-right tree: session and PR in column 0, stages in column
/// 1, agents in the last column. Top-aligned rather than centered: a
/// coordinator run can have thirty agents, and centering would push the
/// session and stages off the first screen. Origins are top-left in a
/// flipped coordinate space.
struct GraphLayoutResult: Equatable {
  var positions: [String: CGPoint] = [:]
  /// Column index to header title.
  var columnTitles: [Int: String] = [:]
}

enum GraphLayout {
  static let nodeSize = CGSize(width: 240, height: 72)
  static let columnGap: CGFloat = 70
  static let rowGap: CGFloat = 16
  static let margin: CGFloat = 30
  /// Space above row 0 for the column headers.
  static let headerHeight: CGFloat = 40

  static var columnStride: CGFloat { nodeSize.width + columnGap }
  static var rowStride: CGFloat { nodeSize.height + rowGap }

  static func origin(column: Int, row: CGFloat) -> CGPoint {
    CGPoint(
      x: margin + CGFloat(column) * columnStride,
      y: margin + headerHeight + row * rowStride)
  }

  static func layout(_ model: GraphModel) -> GraphLayoutResult {
    var result = GraphLayoutResult()
    let stages = model.nodes(of: .stage)
    let agents = model.nodes(of: .agent)
    let hasStages = !stages.isEmpty
    let agentColumn = hasStages ? 2 : 1

    result.columnTitles[0] = "SESSION"
    if hasStages { result.columnTitles[1] = "STAGES" }
    if !agents.isEmpty { result.columnTitles[agentColumn] = "AGENTS" }

    // Agents are the spine: one row each, in model order (already grouped
    // by stage by the builder).
    var agentRow: [String: Int] = [:]
    for (i, node) in agents.enumerated() {
      agentRow[node.id] = i
      result.positions[node.id] = origin(column: agentColumn, row: CGFloat(i))
    }

    // Stages align with their first agent; a stage with no agents (cannot
    // happen from the builder, but keep the layout total) takes the next
    // free row.
    var nextFreeRow = agents.count
    for node in stages {
      let rows = model.children(of: node.id).compactMap { agentRow[$0] }
      let row: Int
      if let first = rows.min() {
        row = first
      } else {
        row = nextFreeRow
        nextFreeRow += 1
      }
      result.positions[node.id] = origin(column: 1, row: CGFloat(row))
    }

    // Root at the top, PR directly under it.
    for node in model.nodes(of: .session) {
      result.positions[node.id] = origin(column: 0, row: 0)
      for child in model.children(of: node.id) where model.node(id: child)?.kind == .pullRequest {
        result.positions[child] = origin(column: 0, row: 1)
      }
    }

    return result
  }

  /// Bounding size of the laid-out graph including margins.
  static func contentSize(positions: [String: CGPoint]) -> CGSize {
    let maxX = positions.values.map(\.x).max() ?? 0
    let maxY = positions.values.map(\.y).max() ?? 0
    return CGSize(
      width: maxX + nodeSize.width + margin,
      height: maxY + nodeSize.height + margin)
  }
}
