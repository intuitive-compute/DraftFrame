import AppKit
import DraftFrameKit

// The process entry point runs on the main thread, but top-level code in a
// literal main.swift is not statically main-actor isolated — assert it so the
// @MainActor app delegate can be constructed. `run()` doesn't return until
// quit, keeping `delegate` alive (NSApplication.delegate doesn't retain).
MainActor.assumeIsolated {
  let app = NSApplication.shared
  let delegate = DFAppDelegate()
  app.delegate = delegate
  app.run()
}
