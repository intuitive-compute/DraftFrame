import AppKit
import Foundation

// MARK: - GitHub Release Model

struct GitHubRelease: Decodable {
  let tagName: String
  let name: String?
  let body: String?
  let prerelease: Bool
  let htmlUrl: String
  let assets: [Asset]

  struct Asset: Decodable {
    let name: String
    let browserDownloadUrl: String
    let size: Int

    enum CodingKeys: String, CodingKey {
      case name
      case browserDownloadUrl = "browser_download_url"
      case size
    }
  }

  enum CodingKeys: String, CodingKey {
    case tagName = "tag_name"
    case name, body, prerelease
    case htmlUrl = "html_url"
    case assets
  }
}

// MARK: - Update Error

struct UpdateError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
  init(_ message: String) { self.message = message }
}

// MARK: - Update Manager

final class UpdateManager: NSObject, URLSessionDownloadDelegate {
  static let shared = UpdateManager()

  static var currentVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
  }

  private let owner = "intuitive-compute"
  private let repo = "draftframe"
  private let checkIntervalSeconds: TimeInterval = 86400
  private let lastCheckKey = "DFLastUpdateCheck"
  private let skippedVersionKey = "DFSkippedVersion"

  private var downloadingAsset: GitHubRelease.Asset?
  private var downloadTask: URLSessionDownloadTask?
  private lazy var downloadSession: URLSession = {
    URLSession(configuration: .default, delegate: self, delegateQueue: .main)
  }()
  private var downloadProgressWindow: NSWindow?
  private var progressIndicator: NSProgressIndicator?

  override private init() {
    super.init()
  }

  // MARK: - Public API

  func checkOnLaunchIfNeeded() {
    let lastCheck = UserDefaults.standard.double(forKey: lastCheckKey)
    let elapsed = Date().timeIntervalSince1970 - lastCheck
    guard elapsed >= checkIntervalSeconds else { return }

    Task {
      guard let release = try? await fetchLatestRelease() else { return }
      await MainActor.run {
        if self.isUpdateAvailable(release) {
          self.showUpdateAlert(release)
        }
      }
    }
  }

  func checkNow() {
    Task {
      do {
        let release = try await fetchLatestRelease()
        await MainActor.run {
          if self.isUpdateAvailable(release) {
            self.showUpdateAlert(release)
          } else {
            self.showUpToDateAlert()
          }
        }
      } catch {
        await MainActor.run {
          self.showErrorAlert("Could not check for updates: \(error.localizedDescription)")
        }
      }
    }
  }

  // MARK: - Network

  private func fetchLatestRelease() async throws -> GitHubRelease {
    let url = URL(
      string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
    var request = URLRequest(url: url)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.timeoutInterval = 15

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      throw URLError(.badServerResponse)
    }

    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
    return try JSONDecoder().decode(GitHubRelease.self, from: data)
  }

  // MARK: - Version Comparison

  private func isUpdateAvailable(_ release: GitHubRelease) -> Bool {
    guard !release.prerelease else { return false }

    let remote =
      release.tagName.hasPrefix("v")
      ? String(release.tagName.dropFirst()) : release.tagName

    let skipped = UserDefaults.standard.string(forKey: skippedVersionKey)
    if skipped == remote { return false }

    return isNewer(remote, than: Self.currentVersion)
  }

  private func isNewer(_ remote: String, than local: String) -> Bool {
    let rParts = remote.split(separator: ".").compactMap { Int($0) }
    let lParts = local.split(separator: ".").compactMap { Int($0) }
    let r = rParts + Array(repeating: 0, count: max(0, 3 - rParts.count))
    let l = lParts + Array(repeating: 0, count: max(0, 3 - lParts.count))
    for i in 0..<3 {
      if r[i] > l[i] { return true }
      if r[i] < l[i] { return false }
    }
    return false
  }

  // MARK: - Download

  // Matches the architecture this binary was built for. An x86_64 build under
  // Rosetta stays on x86_64 rather than being switched to arm64 mid-update.
  private static var machineArch: String {
    #if arch(arm64)
      return "arm64"
    #else
      return "x86_64"
    #endif
  }

  private func dmgAsset(in release: GitHubRelease) -> GitHubRelease.Asset? {
    let dmgs = release.assets.filter { $0.name.hasSuffix(".dmg") }
    return dmgs.first { $0.name.contains(Self.machineArch) } ?? dmgs.first
  }

  private func downloadUpdate(_ release: GitHubRelease) {
    guard let asset = dmgAsset(in: release),
      let url = URL(string: asset.browserDownloadUrl)
    else {
      showErrorAlert("No DMG found in this release.")
      return
    }

    downloadingAsset = asset
    showDownloadProgress()
    let task = downloadSession.downloadTask(with: url)
    downloadTask = task
    task.resume()
  }

  // MARK: - URLSessionDownloadDelegate

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    if totalBytesExpectedToWrite > 0 {
      let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
      progressIndicator?.doubleValue = progress * 100
    }
  }

  func urlSession(
    _ session: URLSession, downloadTask task: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    dismissDownloadProgress()

    guard let asset = downloadingAsset else { return }
    downloadingAsset = nil

    let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    let dest = downloads.appendingPathComponent(asset.name)

    do {
      try? FileManager.default.removeItem(at: dest)
      try FileManager.default.moveItem(at: location, to: dest)
      showReadyToInstallAlert(dmgPath: dest.path)
    } catch {
      showErrorAlert("Failed to save update: \(error.localizedDescription)")
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error = error {
      dismissDownloadProgress()
      showErrorAlert("Download failed: \(error.localizedDescription)")
    }
  }

  // MARK: - Install

  private static let expectedTeamID = "49V6GRJ827"

  private func installUpdate(dmgPath: String) {
    showProgressPanel(label: "Installing update\u{2026}", indeterminate: true)
    Task.detached(priority: .userInitiated) {
      do {
        let appPath = try Self.performInstall(dmgPath: dmgPath)
        await MainActor.run {
          self.dismissProgressPanel()
          Self.relaunch(appPath: appPath)
        }
      } catch {
        await MainActor.run {
          self.dismissProgressPanel()
          self.showInstallFailedAlert(dmgPath: dmgPath, error: error)
        }
      }
    }
  }

  // Mounts the DMG, verifies the new app's signature, swaps it into place,
  // and cleans up. Returns the installed app path. Runs off the main thread.
  private static func performInstall(dmgPath: String) throws -> String {
    let mountPoint = try mountDMG(dmgPath)
    defer { detachDMG(mountPoint) }

    let fm = FileManager.default
    guard
      let appName = try fm.contentsOfDirectory(atPath: mountPoint)
        .first(where: { $0.hasSuffix(".app") })
    else {
      throw UpdateError("No app found in the update disk image.")
    }
    let sourceApp = URL(fileURLWithPath: mountPoint).appendingPathComponent(appName)

    try verifySignature(of: sourceApp)

    let destApp = installDestination()
    let destDir = destApp.deletingLastPathComponent()
    let pid = ProcessInfo.processInfo.processIdentifier
    let staged = destDir.appendingPathComponent(".\(appName).update-\(pid)")
    let backup = destDir.appendingPathComponent(".\(appName).backup-\(pid)")

    // Stage a copy next to the destination so the final move is a same-volume
    // rename, then swap: old aside, new in, old removed. Renaming and removing
    // the running app's bundle is safe; the executable stays mapped.
    try? fm.removeItem(at: staged)
    try fm.copyItem(at: sourceApp, to: staged)
    _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])

    if fm.fileExists(atPath: destApp.path) {
      try fm.moveItem(at: destApp, to: backup)
    }
    do {
      try fm.moveItem(at: staged, to: destApp)
    } catch {
      try? fm.moveItem(at: backup, to: destApp)
      try? fm.removeItem(at: staged)
      throw error
    }
    try? fm.removeItem(at: backup)
    try? fm.removeItem(atPath: dmgPath)
    return destApp.path
  }

  // The running bundle's location, unless it isn't a normal writable install
  // (translocated, on a DMG, or a dev build) — then fall back to /Applications.
  private static func installDestination() -> URL {
    let bundleURL = Bundle.main.bundleURL
    let path = bundleURL.path
    if path.hasSuffix(".app"),
      !path.contains("/AppTranslocation/"),
      !path.hasPrefix("/Volumes/"),
      FileManager.default.isWritableFile(
        atPath: bundleURL.deletingLastPathComponent().path)
    {
      return bundleURL
    }
    return URL(fileURLWithPath: "/Applications/DraftFrame.app")
  }

  private static func mountDMG(_ path: String) throws -> String {
    let result = try run(
      "/usr/bin/hdiutil", ["attach", path, "-nobrowse", "-noautoopen", "-plist"])
    guard result.status == 0,
      let plist = try? PropertyListSerialization.propertyList(
        from: result.stdout, format: nil),
      let dict = plist as? [String: Any],
      let entities = dict["system-entities"] as? [[String: Any]],
      let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first
    else {
      throw UpdateError("Could not mount the update disk image.")
    }
    return mountPoint
  }

  private static func detachDMG(_ mountPoint: String) {
    _ = try? run("/usr/bin/hdiutil", ["detach", mountPoint, "-force"])
  }

  private static func verifySignature(of app: URL) throws {
    let verify = try run(
      "/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    guard verify.status == 0 else {
      throw UpdateError("The downloaded update failed code signature verification.")
    }
    // codesign -dv prints signing info, including TeamIdentifier, to stderr.
    let info = try run("/usr/bin/codesign", ["-dv", "--verbose=2", app.path])
    guard info.stderr.contains("TeamIdentifier=\(expectedTeamID)") else {
      throw UpdateError("The downloaded update is not signed by the expected developer.")
    }
  }

  // Spawns a detached shell that waits for this process to exit, then opens
  // the new app, and quits. The child survives our exit (it is reparented).
  private static func relaunch(appPath: String) {
    let pid = ProcessInfo.processInfo.processIdentifier
    let script =
      "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.1; done; "
      + "/usr/bin/open \"\(appPath)\""
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/sh")
    proc.arguments = ["-c", script]
    try? proc.run()
    NSApp.terminate(nil)
  }

  @discardableResult
  private static func run(
    _ tool: String, _ args: [String]
  ) throws -> (status: Int32, stdout: Data, stderr: String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: tool)
    proc.arguments = args
    let out = Pipe()
    let err = Pipe()
    proc.standardOutput = out
    proc.standardError = err
    try proc.run()
    // Drain pipes before waiting so a full pipe buffer can't deadlock the child.
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return (proc.terminationStatus, outData, String(data: errData, encoding: .utf8) ?? "")
  }

  // MARK: - Alerts

  private func showUpdateAlert(_ release: GitHubRelease) {
    let version =
      release.tagName.hasPrefix("v")
      ? String(release.tagName.dropFirst()) : release.tagName

    let alert = NSAlert()
    alert.messageText = "DraftFrame \(version) is Available"
    alert.informativeText = formatReleaseNotes(release)
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Download Update")
    alert.addButton(withTitle: "Skip This Version")
    alert.addButton(withTitle: "Remind Me Later")

    let response = alert.runModal()
    switch response {
    case .alertFirstButtonReturn:
      downloadUpdate(release)
    case .alertSecondButtonReturn:
      UserDefaults.standard.set(version, forKey: skippedVersionKey)
    default:
      break
    }
  }

  private func showReadyToInstallAlert(dmgPath: String) {
    let alert = NSAlert()
    alert.messageText = "Update Downloaded"
    alert.informativeText =
      "DraftFrame will install the update and relaunch."
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Install & Relaunch")
    alert.addButton(withTitle: "Later")

    let response = alert.runModal()
    if response == .alertFirstButtonReturn {
      installUpdate(dmgPath: dmgPath)
    }
  }

  private func showInstallFailedAlert(dmgPath: String, error: Error) {
    let alert = NSAlert()
    alert.messageText = "Automatic Update Failed"
    alert.informativeText =
      "\(error.localizedDescription)\n\n"
      + "You can install manually instead: open the disk image and drag "
      + "DraftFrame to your Applications folder, then relaunch the app."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Open DMG & Quit")
    alert.addButton(withTitle: "Later")

    let response = alert.runModal()
    if response == .alertFirstButtonReturn {
      NSWorkspace.shared.open(URL(fileURLWithPath: dmgPath))
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        NSApp.terminate(nil)
      }
    }
  }

  private func showUpToDateAlert() {
    let alert = NSAlert()
    alert.messageText = "You\u{2019}re Up to Date"
    alert.informativeText =
      "DraftFrame \(Self.currentVersion) is the latest version."
    alert.alertStyle = .informational
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }

  private func showErrorAlert(_ message: String) {
    let alert = NSAlert()
    alert.messageText = "Update Check Failed"
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }

  // MARK: - Progress Panel

  private func showDownloadProgress() {
    showProgressPanel(label: "Downloading update\u{2026}", indeterminate: false)
  }

  private func dismissDownloadProgress() {
    dismissProgressPanel()
  }

  private func showProgressPanel(label labelText: String, indeterminate: Bool) {
    dismissProgressPanel()

    let indicator = NSProgressIndicator()
    indicator.style = .bar
    indicator.minValue = 0
    indicator.maxValue = 100
    indicator.isIndeterminate = indeterminate
    indicator.frame = NSRect(x: 20, y: 20, width: 260, height: 20)
    if indeterminate { indicator.startAnimation(nil) }
    progressIndicator = indicator

    let label = NSTextField(labelWithString: labelText)
    label.frame = NSRect(x: 20, y: 50, width: 260, height: 20)

    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
    contentView.addSubview(label)
    contentView.addSubview(indicator)

    let window = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
      styleMask: [.titled],
      backing: .buffered, defer: false)
    window.title = "Updating DraftFrame"
    window.contentView = contentView
    window.center()
    window.orderFront(self)
    downloadProgressWindow = window
  }

  private func dismissProgressPanel() {
    downloadProgressWindow?.close()
    downloadProgressWindow = nil
    progressIndicator = nil
  }

  // MARK: - Helpers

  private func formatReleaseNotes(_ release: GitHubRelease) -> String {
    guard let body = release.body, !body.isEmpty else {
      return "A new version of DraftFrame is available."
    }
    var text = body
    text = text.replacingOccurrences(
      of: #"#{1,6}\s*"#, with: "", options: .regularExpression)
    text = text.replacingOccurrences(
      of: #"\*\*(.+?)\*\*"#, with: "$1", options: .regularExpression)
    if text.count > 500 { text = String(text.prefix(500)) + "\u{2026}" }
    return text
  }
}
