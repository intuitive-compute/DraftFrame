# Graph engineering

DraftFrame's watchdogs are single edges: one trigger, one response,
optionally scoped to a session. A loop is a graph with one cycle. Once a
workflow needs branches ("if tests fail, hand the output to a fixer
session"), fan-out ("review with three sessions, then merge"), or a human
gate ("ask me before pushing"), a flat list of watchdogs stops being
readable. A graph is the honest representation of what people actually
build, and it is the layer Claude Code itself cannot provide: orchestration
across sessions, worktrees, and repos with a human in the loop.

This document is the design for that layer. It is deliberately in three
steps so the visual can be judged before the editor is built.

## Principles

1. **Text is the source of truth.** A graph is a file. It is diffable,
   reviewable, and, most importantly, writable by an agent. The expected
   workflow is that a session authors or restructures the graph and the
   human reads and approves it on the canvas.
2. **The canvas is a live view first, an editor second.** Nodes carry the
   same status the session cards show, plus cost, and open the terminal on
   click. Generic flow builders cannot do this; it is what makes the canvas
   worth opening every day rather than once at setup.
3. **Structural edits on canvas, content edits in text.** Adding a gate,
   dragging an edge, rewiring a branch are natural on a canvas. Editing a
   400-word prompt in a node box is not. Nodes link out to their prompt
   files.
4. **Watchdogs are the degenerate case.** A watchdog is a graph with one
   trigger node and one action node. The runner must express them so
   nothing existing is thrown away.

## Steps

| Step | Deliverable | Status |
|------|-------------|--------|
| 1 | Read-only live canvas of one session and the sub-agents its harness spawned, grouped by dispatching skill. Auto-laid-out, draggable, click-through to the session and to agent transcripts. | Implemented as the Graph mode of the dashboard (Cmd+D). |
| 2 | Graph spec file plus a runner that generalizes watchdogs. Watchdogs load as one-edge graphs. | Design below. |
| 3 | Structural editing on the canvas, written back to the spec. | Not started. |

## Step 1: the live canvas

The dashboard gains a third mode, Graph, next to Grid and Summary. It shows
**one session and the work its harness spawned**, not every open project.
The picker beside the mode selector chooses the session; it follows the
active tab until you pin one.

The graph is a left-to-right tree:

- **Session** (column 0): the coordinator tab, colored by its live state,
  with its model, current-run cost, and an agent count. Its pull request, if
  any, sits directly below it. Clicking the session switches to it and
  closes the dashboard.
- **Stages** (column 1): one node per skill that dispatched sub-agents, in
  order of first dispatch, with member count and summed cost. In the
  ios-rewrite harness these are `hardened-fix-pipeline`, `code-review`,
  `review-gate` and so on. Omitted when no agent carries a skill.
- **Agents** (last column): one node per sub-agent, grouped under its stage,
  oldest first. Each shows agent type, first prompt line, status (running,
  done, stopped), model, elapsed time, and cost. Clicking an agent opens its
  transcript in the code editor.

### Where the children come from

Claude Code writes each sub-agent's transcript to
`~/.claude/projects/<project>/<sessionId>/subagents/agent-<id>.jsonl`. That
directory is the ground truth for "child sessions run by the flow": the
parent transcript does not reliably record dispatches (skills and workflows
spawn agents without a tool_use block), but every agent writes its own
file, stamped with `agentId`, `attributionAgent` (type) and
`attributionSkill` (the dispatching skill).

`SubagentScanner` parses those files: prompt from the first non-meta user
message, model and usage from assistant turns deduplicated by message id
(the same rule `SessionJSONLWatcher` uses), cost from the shared pricing
table, and status from the tail: a text-only assistant turn means the agent
returned; otherwise it is running if the file was written in the last
minute and stopped if not.

`SessionGraphSource` runs the scan off the main thread, caches per file by
size and modification time (transcripts reach a few MB and a coordinator
can spawn thirty), and posts a notification only when the record set
changes.

Layout is layered: agents are the spine, one row each; a stage centers on
its agents; the session centers on everything it points at. Dragging a node
overrides its position for the life of the window. Nothing in step 1
writes to disk.

`GraphModelBuilder` and `GraphLayout` are pure and unit tested;
`DFGraphCanvas` only draws and handles the mouse.

## Step 2: the graph spec

### Where it lives

One file per graph, JSON, in one of two places:

- `<repo>/.draftframe/graphs/<name>.json` for graphs that belong to a
  project and travel with it in git.
- `~/.config/draftframe/graphs/<name>.json` for personal graphs that span
  projects.

JSON rather than YAML because the app already reads and writes JSON
everywhere (projects, toolkit, PR monitor, sessions) and adds no
dependency. The format is small enough that hand-editing is fine.

### Shape

```json
{
  "version": 1,
  "name": "fix-ci",
  "description": "When CI fails on a PR, hand the log to a fixer session and ask before pushing.",
  "nodes": [
    { "id": "ci-failed",  "type": "trigger.pr",     "on": "checks-failing" },
    { "id": "fixer",      "type": "session",        "prompt": "prompts/fix-ci.md", "worktree": "inherit", "agent": "claude" },
    { "id": "tests",      "type": "command",        "run": "swift test" },
    { "id": "approve",    "type": "gate.human",     "message": "Fixer is done and tests pass. Push?" },
    { "id": "push",       "type": "command",        "run": "git push" },
    { "id": "give-up",    "type": "notify",         "message": "Fixer failed twice on {{pr.number}}" }
  ],
  "edges": [
    { "from": "ci-failed", "to": "fixer" },
    { "from": "fixer",     "to": "tests",   "when": "session.idle" },
    { "from": "tests",     "to": "approve", "when": "exit == 0" },
    { "from": "tests",     "to": "fixer",   "when": "exit != 0", "max": 2 },
    { "from": "tests",     "to": "give-up", "when": "exit != 0 && attempts >= 2" },
    { "from": "approve",   "to": "push",    "when": "approved" }
  ]
}
```

### Node types

Every type below maps onto something DraftFrame already has. New code is
the runner and two node types, the human gate and fan-in.

| Type | Backed by today | Notes |
|------|-----------------|-------|
| `trigger.session` | `WatchdogTrigger.needsAttention`, `.idleAfterWork` | `on`: `needs-attention`, `idle-after-work`. |
| `trigger.periodic` | `WatchdogTrigger.periodic` | `every`: seconds. |
| `trigger.pr` | `PRMonitor` | `on`: `opened`, `checks-failing`, `checks-passing`, `merged`. |
| `trigger.files` | `DirectoryWatcher` | `paths`: globs. |
| `session` | `SessionManager.createSession` | `prompt`: file path relative to the graph. `worktree`: `inherit`, `new`, or a path. `agent`: `claude` or `codex`. |
| `send` | `WatchdogResponse.sendText`, `.autoAccept` | Types text into an existing session. `text` may use `{{...}}`. |
| `command` | `ToolkitRunManager` | Runs a shell command in the node's worktree. Exposes `exit` and `output` to outgoing edges. |
| `notify` | `NotificationManager` | macOS notification. |
| `gate.human` | new | Pauses the run and surfaces a prompt in the app. Resolves to `approved` or `rejected`. |
| `join` | new | Waits for every incoming edge to fire once, then fires. Fan-in for parallel sessions. |

### Edges

An edge fires when its `when` condition is true for the source node's
result. Conditions are a tiny expression language over a fixed set of
variables, not a general scripting hook:

- `session.idle`, `session.needs-attention`, `session.exited`
- `exit == 0`, `exit != 0`, `output matches /regex/`
- `approved`, `rejected`
- `attempts`, the number of times this edge has fired in the current run
- `pr.number`, `pr.rollup`, `pr.state`

`max` on an edge caps how many times it may fire per run. This is how a
loop is bounded, and it is required on any edge that closes a cycle. A graph
with an unbounded cycle is rejected at load time.

### Runs

A run is one activation of a graph, started by a trigger firing. Runs are
tracked in memory and appended to
`~/.config/draftframe/graph-runs.jsonl` for the same reason the watchdog
log exists: the human needs to see what fired and why. Each event records
the run, node, edge, timestamp, and the condition that matched.

### Migration

On first launch after step 2, each existing watchdog is written out as a
two-node graph in the personal graphs directory and the watchdog list
becomes a view over graphs with exactly one trigger and one action. The
sidebar section and settings toggles keep working unchanged.

## Step 3: editing

Only after steps 1 and 2 are in daily use. Scope for the first editor pass:

- Add a node of any type from a palette; the app writes a stub to the spec.
- Drag from one node's port to another to add an edge; a popover picks the
  condition from the fixed list.
- Delete a node or edge.
- Double-clicking a `session` node opens its prompt file in the code editor.
- Every canvas edit rewrites the JSON and the file watcher reloads it, so
  external edits, including by an agent, appear on the canvas at once.

The canvas stays native AppKit. If editor polish turns out to need more
than that buys, a WKWebView with a flow library is the fallback, and the
text spec means switching costs nothing in the data model.
