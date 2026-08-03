import Foundation

/// Derives worktree names and session kickoff prompts from pasted ticket
/// links (Jira, Linear, GitHub issues/PRs, or a bare issue key). Parsing is
/// purely lexical — no network, no credentials; the launched agent fetches
/// the ticket itself with whatever tools it has.
enum TicketLink {

  /// Matches an issue key like `ENG-1234` (used both for bare-key input and
  /// for picking keys out of URL components).
  private static let keyPattern = try! NSRegularExpression(
    pattern: #"^[A-Za-z][A-Za-z0-9]*-\d+$"#)

  /// A git-safe worktree/branch name derived from `input`, or nil when
  /// nothing name-worthy can be extracted. Accepts full ticket URLs or a
  /// bare key like `ENG-1234`.
  static func suggestedName(from input: String) -> String? {
    let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return nil }

    if isIssueKey(raw) { return slugify(raw) }

    guard let url = URL(string: raw), let host = url.host?.lowercased() else { return nil }
    let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }

    // Jira: .../browse/ENG-1234 (also ?selectedIssue=ENG-1234 board links).
    if let i = parts.firstIndex(of: "browse"), i + 1 < parts.count, isIssueKey(parts[i + 1]) {
      return slugify(parts[i + 1])
    }
    if let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
      let selected = query.first(where: { $0.name == "selectedIssue" })?.value,
      isIssueKey(selected)
    {
      return slugify(selected)
    }

    // Linear: /team/issue/ENG-1234/fix-login (key + slug as separate
    // components) or the older /team/issue/eng-1234-fix-login.
    if host.hasSuffix("linear.app"), let i = parts.firstIndex(of: "issue"), i + 1 < parts.count {
      let key = parts[i + 1]
      if isIssueKey(key), i + 2 < parts.count {
        return slugify("\(key)-\(parts[i + 2])")
      }
      return slugify(key)
    }

    // GitHub: /owner/repo/issues/123 or /owner/repo/pull/123.
    if host == "github.com", parts.count >= 4 {
      if parts[2] == "issues", Int(parts[3]) != nil { return slugify("issue-\(parts[3])") }
      if parts[2] == "pull", Int(parts[3]) != nil { return slugify("pr-\(parts[3])") }
    }

    // Unknown tracker: an issue key anywhere in the path, else the last
    // path component if it slugs into something usable.
    if let key = parts.first(where: isIssueKey) { return slugify(key) }
    if let last = parts.last { return slugify(last) }
    return nil
  }

  /// The first message a new session sends its agent so work on the ticket
  /// starts immediately.
  static func kickoffPrompt(ticket: String) -> String {
    "Work on this ticket: \(ticket) . "
      + "First read the ticket using the tools you have "
      + "(gh for GitHub, or an MCP integration for Jira/Linear), "
      + "then briefly state your plan and implement it."
  }

  private static func isIssueKey(_ s: String) -> Bool {
    keyPattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
  }

  /// Lowercase and reduce to `[a-z0-9-]` so the result is legal as both a
  /// git branch name and a directory name; capped so pasted long titles
  /// don't produce unwieldy branches.
  private static func slugify(_ s: String) -> String? {
    var out = ""
    for ch in s.lowercased() {
      if ch.isLetter && ch.isASCII || ch.isNumber && ch.isASCII {
        out.append(ch)
      } else if !out.isEmpty && out.last != "-" {
        out.append("-")
      }
    }
    while out.last == "-" { out.removeLast() }
    if out.count > 40 {
      out = String(out.prefix(40))
      while out.last == "-" { out.removeLast() }
    }
    return out.isEmpty ? nil : out
  }
}

/// Quote a string so it survives verbatim inside a single-line shell command.
func shellSingleQuote(_ s: String) -> String {
  "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
