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

  private var latestRelease: GitHubRelease?
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
          self.latestRelease = release
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
            self.latestRelease = release
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

  private func downloadUpdate(_ release: GitHubRelease) {
    guard let asset = release.assets.first(where: { $0.name.hasSuffix(".dmg") }),
      let url = URL(string: asset.browserDownloadUrl)
    else {
      showErrorAlert("No DMG found in this release.")
      return
    }

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

    guard let release = latestRelease,
      let asset = release.assets.first(where: { $0.name.hasSuffix(".dmg") })
    else { return }

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
      "The update has been downloaded. DraftFrame will open the disk image. "
      + "Drag the new DraftFrame to your Applications folder to complete the update, "
      + "then relaunch the app."
    alert.alertStyle = .informational
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

  // MARK: - Download Progress

  private func showDownloadProgress() {
    let indicator = NSProgressIndicator()
    indicator.style = .bar
    indicator.minValue = 0
    indicator.maxValue = 100
    indicator.isIndeterminate = false
    indicator.frame = NSRect(x: 20, y: 20, width: 260, height: 20)
    progressIndicator = indicator

    let label = NSTextField(labelWithString: "Downloading update\u{2026}")
    label.frame = NSRect(x: 20, y: 50, width: 260, height: 20)

    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
    contentView.addSubview(label)
    contentView.addSubview(indicator)

    let window = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
      styleMask: [.titled],
      backing: .buffered, defer: false)
    window.title = "Downloading Update"
    window.contentView = contentView
    window.center()
    window.orderFront(self)
    downloadProgressWindow = window
  }

  private func dismissDownloadProgress() {
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
