import Foundation

/// A merged pull request as reported by `gh pr list --state merged`.
struct MergedPR: Equatable {
  let number: Int
  let headRefName: String
  let url: String
}

/// A managed worktree whose branch has a merged PR — a candidate for the
/// sidebar's sweep.
struct SweepCandidate: Equatable {
  let worktree: WorktreeManager.Worktree
  let prNumber: Int
  let prURL: String

  /// Directory name, as shown in the sidebar.
  var name: String { (worktree.path as NSString).lastPathComponent }
}

/// Outcome of one sweep: which worktrees were removed and which failed.
struct SweepResult {
  var removed: [SweepCandidate] = []
  var failures: [(candidate: SweepCandidate, message: String)] = []
}

/// Sweeps draftframe-managed worktrees whose PRs have merged.
///
/// Auto-archive in `PRMonitor` only catches a merge while the worktree has a
/// live session; worktrees that predate the feature, lost their session, or
/// merged while the app was closed accumulate under `.claude/worktrees/`.
/// The sweep finds them with a single `gh pr list` per repo, then removes the
/// user-confirmed set one at a time (removals contend on the repo's index
/// lock, so a serial queue is the right shape). All subprocess work runs on
/// `queue`; callers get results on the main actor.
@MainActor
final class WorktreeSweeper {
  static let shared = WorktreeSweeper()

  /// Page size for `gh pr list`. Repos with more merged PRs than this fall
  /// back to a per-worktree `gh pr view` for the unmatched remainder.
  nonisolated static let listLimit = 200

  private let queue = DispatchQueue(label: "com.draftframe.worktree-sweep", qos: .utility)

  private init() {}

  // MARK: - Pure matching (unit-tested)

  /// Parse `gh pr list --json number,headRefName,url` output. Entries missing
  /// any field are skipped rather than failing the whole list.
  nonisolated static func parseMergedPRList(_ data: Data) -> [MergedPR] {
    guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      return []
    }
    return arr.compactMap { entry in
      guard let number = entry["number"] as? Int,
        let head = entry["headRefName"] as? String,
        let url = entry["url"] as? String
      else { return nil }
      return MergedPR(number: number, headRefName: head, url: url)
    }
  }

  /// Managed, non-bare worktrees whose checked-out branch matches the head
  /// branch of a merged PR. The primary checkout and any worktree living
  /// outside `.claude/worktrees/` are never candidates, and a branch with no
  /// merged PR (open, closed-unmerged, or no PR at all) is left alone. When
  /// several merged PRs share a head branch (reopened and re-merged), the
  /// highest-numbered one is reported.
  nonisolated static func candidates(
    worktrees: [WorktreeManager.Worktree], mergedPRs: [MergedPR]
  ) -> [SweepCandidate] {
    var byBranch: [String: MergedPR] = [:]
    for pr in mergedPRs {
      if let existing = byBranch[pr.headRefName], existing.number >= pr.number { continue }
      byBranch[pr.headRefName] = pr
    }
    return worktrees.compactMap { wt in
      guard !wt.isBare, !wt.branch.isEmpty,
        WorktreeManager.isManagedWorktree(wt.path),
        let pr = byBranch[wt.branch]
      else { return nil }
      return SweepCandidate(worktree: wt, prNumber: pr.number, prURL: pr.url)
    }
  }

  // MARK: - Scan

  /// Find sweep candidates for the repo rooted at `repoRoot`. Runs git and
  /// gh off the main thread; `completion` is called on the main actor.
  func scan(repoRoot: String, completion: @escaping @MainActor ([SweepCandidate]) -> Void) {
    queue.async {
      let found = Self.scanSync(repoRoot: repoRoot)
      DispatchQueue.main.async {
        MainActor.assumeIsolated { completion(found) }
      }
    }
  }

  nonisolated private static func scanSync(repoRoot: String) -> [SweepCandidate] {
    let worktrees = WorktreeManager.shared.listWorktrees(repoRoot: repoRoot)
      .filter { !$0.isBare && WorktreeManager.isManagedWorktree($0.path) }
    guard !worktrees.isEmpty else { return [] }

    let output = PRMonitor.runGH(
      args: [
        "pr", "list", "--state", "merged", "--json", "number,headRefName,url",
        "--limit", String(listLimit),
      ],
      cwd: repoRoot)
    let merged = parseMergedPRList(output.data(using: .utf8) ?? Data())
    var found = candidates(worktrees: worktrees, mergedPRs: merged)

    // A full page means older merged PRs may have been cut off; look the
    // unmatched worktrees up individually so a long-lived repo still sweeps
    // cleanly. Below the limit the list is exhaustive and this is skipped.
    if merged.count >= listLimit {
      let matched = Set(found.map { $0.worktree.path })
      for wt in worktrees where !matched.contains(wt.path) {
        if let pr = lookupMergedPR(branch: wt.branch, cwd: repoRoot) {
          found.append(SweepCandidate(worktree: wt, prNumber: pr.number, prURL: pr.url))
        }
      }
    }
    return found
  }

  /// Per-branch fallback: `gh pr view <branch>` resolves the branch's PR
  /// (most recent if several). Returns it only when merged.
  nonisolated private static func lookupMergedPR(branch: String, cwd: String) -> MergedPR? {
    let output = PRMonitor.runGH(
      args: ["pr", "view", branch, "--json", "number,state,url,headRefName"], cwd: cwd)
    guard let data = output.data(using: .utf8),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      obj["state"] as? String == PRState.merged.rawValue,
      let number = obj["number"] as? Int,
      let url = obj["url"] as? String
    else { return nil }
    return MergedPR(number: number, headRefName: branch, url: url)
  }

  // MARK: - Removal

  /// Remove `candidates` one at a time. Each attached session is closed
  /// through `SessionManager.closeSession` first (on the main actor, so
  /// persistence stays consistent and the worktree isn't resumed on next
  /// launch), then `git worktree remove` runs on the sweep queue. A failed
  /// removal is recorded and the sweep moves on. `progress` fires on the
  /// main actor before each removal with (index, total); `completion` fires
  /// once at the end.
  func sweep(
    repoRoot: String,
    candidates: [SweepCandidate],
    progress: @escaping @MainActor (Int, Int) -> Void,
    completion: @escaping @MainActor (SweepResult) -> Void
  ) {
    let total = candidates.count
    var result = SweepResult()

    func step(_ index: Int) {
      guard index < total else {
        completion(result)
        return
      }
      let candidate = candidates[index]
      progress(index + 1, total)
      Self.closeSessions(attachedTo: candidate.worktree.path)

      let path = candidate.worktree.path
      queue.async {
        let error: String?
        do {
          try WorktreeManager.shared.removeWorktree(repoRoot: repoRoot, path: path)
          error = nil
        } catch let err {
          error = err.localizedDescription
        }
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            if let error = error {
              NSLog("[WorktreeSweeper] remove failed for %@: %@", path, error)
              result.failures.append((candidate, error))
            } else {
              result.removed.append(candidate)
            }
            step(index + 1)
          }
        }
      }
    }
    step(0)
  }

  /// Close every session bound to `worktreePath`. Matches on symlink-resolved
  /// paths: git reports realpaths while a session may hold the spelling the
  /// user opened it with.
  private static func closeSessions(attachedTo worktreePath: String) {
    let resolved = URL(fileURLWithPath: worktreePath).resolvingSymlinksInPath().path
    let ids = SessionManager.shared.sessions.compactMap { session -> UUID? in
      guard let p = session.worktreePath else { return nil }
      let same =
        p == worktreePath
        || URL(fileURLWithPath: p).resolvingSymlinksInPath().path == resolved
      return same ? session.id : nil
    }
    for id in ids {
      SessionManager.shared.closeSession(id: id)
    }
  }
}
