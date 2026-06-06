import AppKit

/// Opens a file in the user's default application, with a best-effort jump to a
/// specific line when the default app is a recognized code editor.
///
/// SwiftTerm's default link handler passes the raw matched text to
/// `NSWorkspace.open(URL(string:))`, which builds a schemeless URL for a bare or
/// relative path and is rejected by Finder with error -50. We resolve the path
/// ourselves and always open via a proper `file://` URL, falling back to a plain
/// (no-line) open whenever line-aware opening isn't available.
enum EditorOpener {
  /// Open `path` in the default app. When `line` is provided, attempt to open at
  /// that line/column using the default editor's URL scheme or CLI; otherwise just
  /// open the file.
  static func open(path: String, line: Int?, column: Int?) {
    let fileURL = URL(fileURLWithPath: path)

    guard let line = line else {
      NSWorkspace.shared.open(fileURL)
      return
    }

    guard
      let appURL = NSWorkspace.shared.urlForApplication(toOpen: fileURL),
      let bundleID = Bundle(url: appURL)?.bundleIdentifier,
      openAtLine(
        bundleID: bundleID, appURL: appURL, path: path, line: line,
        column: column ?? 1)
    else {
      // No recognized editor (or the line-aware open failed): just open the file.
      NSWorkspace.shared.open(fileURL)
      return
    }
  }

  /// Dispatch a line-aware open for known editors. Returns false when the editor
  /// isn't recognized or its line-aware mechanism is unavailable, so the caller
  /// can fall back to a plain open.
  private static func openAtLine(
    bundleID: String, appURL: URL, path: String, line: Int, column: Int
  ) -> Bool {
    switch bundleID {
    case "com.microsoft.VSCode", "com.visualstudio.code.oss":
      return openURLScheme("vscode", path: path, line: line, column: column)
    case "com.microsoft.VSCodeInsiders":
      return openURLScheme("vscode-insiders", path: path, line: line, column: column)
    case "com.todesktop.230313mzl4w4u92":  // Cursor
      return openURLScheme("cursor", path: path, line: line, column: column)

    case "com.apple.dt.Xcode":
      return run("/usr/bin/xed", ["--line", "\(line)", path])

    case "com.macromates.TextMate":
      guard
        let encoded = path.addingPercentEncoding(
          withAllowedCharacters: .urlPathAllowed),
        let url = URL(
          string: "txmt://open?url=file://\(encoded)&line=\(line)&column=\(column)")
      else { return false }
      return NSWorkspace.shared.open(url)

    case let id where id.hasPrefix("com.sublimetext."):
      guard
        let subl = firstExecutable(["subl"], in: appURL, subpath: "Contents/SharedSupport/bin/subl")
      else { return false }
      return run(subl, ["\(path):\(line):\(column)"])

    case "com.barebones.bbedit":
      guard
        let bbedit = firstExecutable(
          ["bbedit"], in: appURL, subpath: "Contents/Helpers/bbedit_tool")
      else { return false }
      return run(bbedit, ["+\(line)", path])

    default:
      // Includes JetBrains IDEs, whose line-jump CLIs aren't reliably discoverable.
      return false
    }
  }

  /// Open `scheme://file<path>:<line>:<column>` (VS Code / Cursor family).
  private static func openURLScheme(
    _ scheme: String, path: String, line: Int, column: Int
  ) -> Bool {
    guard
      let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
      let url = URL(string: "\(scheme)://file\(encoded):\(line):\(column)")
    else { return false }
    return NSWorkspace.shared.open(url)
  }

  /// Locate an editor CLI by checking common bin locations and an app-relative path.
  private static func firstExecutable(
    _ names: [String], in appURL: URL, subpath: String
  ) -> String? {
    let fm = FileManager.default
    var candidates = [appURL.appendingPathComponent(subpath).path]
    for dir in ["/usr/local/bin", "/opt/homebrew/bin"] {
      for name in names {
        candidates.append("\(dir)/\(name)")
      }
    }
    return candidates.first { fm.isExecutableFile(atPath: $0) }
  }

  /// Launch a CLI tool. Returns false if it couldn't be started.
  @discardableResult
  private static func run(_ executable: String, _ arguments: [String]) -> Bool {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: executable)
    proc.arguments = arguments
    do {
      try proc.run()
      return true
    } catch {
      return false
    }
  }
}
