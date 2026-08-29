import Foundation

/// dfqa — CLI client for DraftFrame's QA automation bridge.
///
/// The app must be running with DRAFTFRAME_QA_SOCKET set; dfqa connects to
/// that socket (same env var, default /tmp/draftframe-qa.sock), sends one
/// JSON command, and prints the response.
///
/// Usage:
///   dfqa ping | sessions | state | quit
///   dfqa open-project --path DIR
///   dfqa new-session [--name NAME] [--worktree PATH]
///   dfqa select --index N
///   dfqa close-session --index N
///   dfqa send --text STR [--index N] [--enter]
///   dfqa read [--index N] [--lines N]
///   dfqa screenshot PATH [--window main|quick|key]
///   dfqa menu "View>Toggle Dashboard"
///   dfqa raw '{"cmd": "..."}'

func fail(_ msg: String) -> Never {
  FileHandle.standardError.write(Data((msg + "\n").utf8))
  exit(1)
}

func socketPath() -> String {
  ProcessInfo.processInfo.environment["DRAFTFRAME_QA_SOCKET"] ?? "/tmp/draftframe-qa.sock"
}

/// Send one newline-terminated JSON request, return the response data.
func roundTrip(_ request: [String: Any]) -> Data {
  let path = socketPath()
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  guard fd >= 0 else { fail("socket() failed") }
  defer { close(fd) }

  var addr = sockaddr_un()
  addr.sun_family = sa_family_t(AF_UNIX)
  let pathBytes = Array(path.utf8)
  guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
    fail("socket path too long: \(path)")
  }
  withUnsafeMutableBytes(of: &addr.sun_path) { raw in
    raw.copyBytes(from: pathBytes)
  }
  let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
  let connected = withUnsafePointer(to: &addr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
      connect(fd, sa, addrLen)
    }
  }
  guard connected == 0 else {
    fail("cannot connect to \(path) — is DraftFrame running with DRAFTFRAME_QA_SOCKET=\(path)?")
  }

  guard var out = try? JSONSerialization.data(withJSONObject: request) else {
    fail("could not encode request")
  }
  out.append(0x0A)
  out.withUnsafeBytes { raw in
    var sent = 0
    while sent < raw.count {
      let n = write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
      guard n > 0 else { fail("write failed") }
      sent += n
    }
  }

  var response = Data()
  var buf = [UInt8](repeating: 0, count: 4096)
  while true {
    let n = read(fd, &buf, buf.count)
    guard n > 0 else { break }
    response.append(contentsOf: buf[0..<n])
  }
  return response
}

/// Parse `--key value` and `--flag` options from the remaining args.
func parseOptions(_ args: [String], flags: Set<String>) -> ([String: Any], [String]) {
  var opts: [String: Any] = [:]
  var positional: [String] = []
  var i = 0
  while i < args.count {
    let arg = args[i]
    if arg.hasPrefix("--") {
      let key = String(arg.dropFirst(2))
      if flags.contains(key) {
        opts[key] = true
      } else {
        guard i + 1 < args.count else { fail("missing value for --\(key)") }
        i += 1
        let value = args[i]
        if let n = Int(value), key == "index" || key == "lines" {
          opts[key] = n
        } else {
          opts[key] = value
        }
      }
    } else {
      positional.append(arg)
    }
    i += 1
  }
  return (opts, positional)
}

let usage = """
  usage: dfqa <command> [options]
    ping | sessions | state | quit
    open-project --path DIR
    new-session [--name NAME] [--worktree PATH]
    select --index N
    close-session --index N
    send --text STR [--index N] [--enter]
    read [--index N] [--lines N]
    screenshot PATH [--window main|quick|key]
    menu "View>Toggle Dashboard"
    raw '{"cmd": "..."}'
  Socket: $DRAFTFRAME_QA_SOCKET (default /tmp/draftframe-qa.sock)
  """

let argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else { fail(usage) }
let rest = Array(argv.dropFirst())

var request: [String: Any]
switch command {
case "ping", "sessions", "state", "quit":
  request = ["cmd": command]

case "new-session", "select", "close-session", "send", "read", "open-project":
  let (opts, _) = parseOptions(rest, flags: ["enter"])
  request = opts
  request["cmd"] = command
  if command == "open-project" {
    guard let path = opts["path"] as? String else { fail("open-project requires --path DIR") }
    request["path"] = URL(fileURLWithPath: path).standardizedFileURL.path
  }

case "screenshot":
  let (opts, positional) = parseOptions(rest, flags: [])
  guard let path = positional.first else { fail("screenshot requires a PATH argument") }
  request = opts
  request["cmd"] = "screenshot"
  // The bridge writes the file from inside the app, so resolve to an
  // absolute path against dfqa's cwd, not the app's.
  request["path"] = URL(fileURLWithPath: path).standardizedFileURL.path

case "menu":
  guard let spec = rest.first else { fail("menu requires a \"Title>Subtitle\" argument") }
  request = [
    "cmd": "menu",
    "path": spec.split(separator: ">").map { $0.trimmingCharacters(in: .whitespaces) },
  ]

case "raw":
  guard let json = rest.first,
    let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
  else { fail("raw requires a JSON object argument") }
  request = obj

case "-h", "--help", "help":
  print(usage)
  exit(0)

default:
  fail("unknown command: \(command)\n\(usage)")
}

let responseData = roundTrip(request)
guard let response = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
else {
  FileHandle.standardOutput.write(responseData)
  exit(1)
}

// Terminal text reads print raw text; everything else pretty-prints JSON.
if command == "read", response["ok"] as? Bool == true, let text = response["text"] as? String {
  print(text)
} else {
  let pretty = try! JSONSerialization.data(
    withJSONObject: response, options: [.prettyPrinted, .sortedKeys])
  print(String(data: pretty, encoding: .utf8)!)
}
exit(response["ok"] as? Bool == true ? 0 : 1)
