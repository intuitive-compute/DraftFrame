import AVFoundation
import AppKit
import Speech

/// Push-to-talk voice transcription using on-device SFSpeechRecognizer.
/// Cmd+Shift+V starts listening; releasing stops and sends transcription to active session.
final class VoiceManager {
  static let shared = VoiceManager()

  /// Published state for the UI (microphone indicator).
  private(set) var isListening = false {
    didSet {
      DispatchQueue.main.async {
        NotificationCenter.default.post(name: .voiceListeningDidChange, object: nil)
      }
    }
  }

  private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private let audioEngine = AVAudioEngine()

  /// Accumulated transcription from the current listening session.
  private var currentTranscription = ""

  private init() {
    speechRecognizer?.supportsOnDeviceRecognition = true
  }

  // MARK: - Authorization

  /// Request microphone and speech recognition permissions. Call on launch.
  func requestAuthorization() {
    SFSpeechRecognizer.requestAuthorization { status in
      switch status {
      case .authorized:
        NSLog("[VoiceManager] Speech recognition authorized")
      case .denied, .restricted, .notDetermined:
        NSLog("[VoiceManager] Speech recognition not authorized: \(status.rawValue)")
      @unknown default:
        break
      }
    }

    // Microphone permission is requested implicitly when AVAudioEngine starts,
    // but we can prime it here.
    AVCaptureDevice.requestAccess(for: .audio) { granted in
      NSLog("[VoiceManager] Microphone access: \(granted)")
    }
  }

  // MARK: - Listening

  /// Begin recording and transcribing audio.
  func startListening() {
    guard !isListening else { return }
    guard let recognizer = speechRecognizer, recognizer.isAvailable else {
      NSLog("[VoiceManager] Speech recognizer not available")
      return
    }

    // Cancel any in-flight task
    recognitionTask?.cancel()
    recognitionTask = nil

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    if recognizer.supportsOnDeviceRecognition {
      request.requiresOnDeviceRecognition = true
    }
    recognitionRequest = request
    currentTranscription = ""

    let inputNode = audioEngine.inputNode
    let recordingFormat = inputNode.outputFormat(forBus: 0)

    inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
      request.append(buffer)
    }

    audioEngine.prepare()

    do {
      try audioEngine.start()
    } catch {
      NSLog("[VoiceManager] Audio engine failed to start: \(error)")
      cleanup()
      return
    }

    recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
      guard let self = self else { return }

      if let result = result {
        self.currentTranscription = result.bestTranscription.formattedString
      }

      if error != nil || (result?.isFinal ?? false) {
        // Task ended naturally or with error — don't cleanup here,
        // stopListening handles it.
      }
    }

    isListening = true
    NSLog("[VoiceManager] Started listening")
  }

  /// Stop recording, finalize transcription, and send to active session.
  @discardableResult
  func stopListening() -> String {
    guard isListening else { return "" }

    // Stop audio
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    recognitionRequest?.endAudio()

    // Give a brief moment for final transcription to arrive
    let text = currentTranscription.trimmingCharacters(in: .whitespacesAndNewlines)

    cleanup()

    NSLog("[VoiceManager] Stopped listening. Transcription: \(text)")

    // Send to active terminal session
    if !text.isEmpty {
      DispatchQueue.main.async {
        SessionManager.shared.activeSession?.terminalView?.send(txt: text)
      }
    }

    return text
  }

  private func cleanup() {
    recognitionTask?.cancel()
    recognitionTask = nil
    recognitionRequest = nil
    isListening = false
  }
}

// MARK: - Notification

extension Notification.Name {
  static let voiceListeningDidChange = Notification.Name("DFVoiceListeningDidChange")
}
