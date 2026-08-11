import AppKit
import SwiftTerm

/// Orientation of a quick-terminal split: `vertical` divides the space with a
/// vertical divider (panes side-by-side), `horizontal` divides it with a
/// horizontal divider (panes stacked).
enum QTSplitDirection {
  case horizontal
  case vertical
}

/// One leaf terminal within a quick-terminal tab's split tree.
final class QTPane {
  let id = UUID()
  let terminalView: ClaudeTerminalView

  init(terminalView: ClaudeTerminalView) {
    self.terminalView = terminalView
  }
}

/// A node in a quick-terminal tab's split tree: either a single terminal, or
/// a split dividing space between two (or more, once further split) child
/// nodes. Splitting always inserts exactly two children; further splitting
/// one of those children nests another two-child split beneath it, so the
/// tree stays an arbitrary binary split tree (tmux/iTerm-style).
indirect enum QTNode {
  case leaf(QTPane)
  case split(QTSplitDirection, [QTNode])

  /// All panes in this subtree, in depth-first left-to-right order — used
  /// both for numbering (Cmd+Shift+1-9) and for locating a pane's terminal
  /// view.
  func allPanes() -> [QTPane] {
    switch self {
    case .leaf(let pane):
      return [pane]
    case .split(_, let children):
      return children.flatMap { $0.allPanes() }
    }
  }

  /// Returns a new tree with the leaf matching `paneID` replaced by a split
  /// containing that leaf followed by `newPane`. Returns `self` unchanged if
  /// `paneID` isn't found.
  func replacing(paneID: UUID, withSplit direction: QTSplitDirection, newPane: QTPane) -> QTNode {
    switch self {
    case .leaf(let pane):
      if pane.id == paneID {
        return .split(direction, [.leaf(pane), .leaf(newPane)])
      }
      return self
    case .split(let dir, let children):
      return .split(
        dir,
        children.map { $0.replacing(paneID: paneID, withSplit: direction, newPane: newPane) })
    }
  }

  /// Returns a new tree with the leaf matching `paneID` removed, collapsing
  /// any split left with a single child down to that child. Returns `nil` if
  /// removing `paneID` empties this subtree entirely (i.e. this node *is*
  /// that leaf).
  func removing(paneID: UUID) -> QTNode? {
    switch self {
    case .leaf(let pane):
      return pane.id == paneID ? nil : self
    case .split(let dir, let children):
      let remaining = children.compactMap { $0.removing(paneID: paneID) }
      if remaining.count == 1 {
        return remaining[0]
      }
      if remaining.isEmpty {
        return nil
      }
      return .split(dir, remaining)
    }
  }
}

/// One tab within a session's quick terminal, holding its own split tree.
/// Tabs have no stored name — they're displayed by position (1, 2, …), so
/// numbering stays contiguous as tabs are closed and matches Option+1-9.
final class QTTab {
  let id = UUID()
  var root: QTNode
  var lastFocusedPaneID: UUID

  init(pane: QTPane) {
    self.root = .leaf(pane)
    self.lastFocusedPaneID = pane.id
  }

  func allPanes() -> [QTPane] {
    root.allPanes()
  }

  /// The pane last known to be focused, falling back to the tab's first pane
  /// if that pane no longer exists (e.g. it was just closed).
  func focusedPane() -> QTPane? {
    let panes = allPanes()
    return panes.first(where: { $0.id == lastFocusedPaneID }) ?? panes.first
  }

  /// Split the pane matching `paneID` in `direction`, inserting `newPane`
  /// alongside it.
  func split(paneID: UUID, direction: QTSplitDirection, newPane: QTPane) {
    root = root.replacing(paneID: paneID, withSplit: direction, newPane: newPane)
    lastFocusedPaneID = newPane.id
  }

  /// Remove the pane matching `paneID`. Returns `true` if the tab is now
  /// empty (its last pane was removed).
  func remove(paneID: UUID) -> Bool {
    guard let newRoot = root.removing(paneID: paneID) else {
      return true
    }
    root = newRoot
    if lastFocusedPaneID == paneID {
      lastFocusedPaneID = root.allPanes().first?.id ?? paneID
    }
    return false
  }
}

/// A session's full quick-terminal state: its tabs, each with its own split
/// tree, and which tab is currently active.
final class QTSessionState {
  var tabs: [QTTab] = []
  var activeTabIndex: Int = 0

  var activeTab: QTTab? {
    tabs.indices.contains(activeTabIndex) ? tabs[activeTabIndex] : nil
  }

  /// The tab index containing the pane matching `paneID`, if any.
  func tabIndex(ofPane paneID: UUID) -> Int? {
    tabs.firstIndex { tab in tab.allPanes().contains { $0.id == paneID } }
  }
}
