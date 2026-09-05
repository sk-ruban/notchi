import AppKit
import AVFoundation
import Foundation
import Observation

struct SpeechToTextServiceDependencies {
    var makeCapture: @Sendable () -> AudioCapturing
    var makeTranscriber: @Sendable (URL) -> Transcribing
    var isModelDownloaded: @MainActor () -> Bool
    var modelURL: @MainActor () -> URL
    var language: @MainActor () -> String
    var microphoneAuthorized: @Sendable () -> Bool
    var frontmostAppPID: @MainActor () -> pid_t? = { nil }

    static let live = SpeechToTextServiceDependencies(
        makeCapture: { AudioCaptureEngine() },
        makeTranscriber: { WhisperTranscriber(modelURL: $0) },
        isModelDownloaded: {
            guard let model = WhisperCatalog.model(id: AppSettings.dictationModelId) else { return false }
            return WhisperModelStore.shared.isDownloaded(model)
        },
        modelURL: {
            let model = WhisperCatalog.model(id: AppSettings.dictationModelId) ?? WhisperCatalog.models[1]
            return WhisperModelStore.fileURL(for: model)
        },
        language: { AppSettings.dictationLanguage },
        microphoneAuthorized: {
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        },
        // The app the user was in when they held the push-to-talk key — the
        // terminal to paste back into if session-based resolution can't find it.
        frontmostAppPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    )
}

@MainActor
@Observable
final class SpeechToTextService {
    static let shared = SpeechToTextService(dependencies: .live)

    private(set) var phase: DictationPhase = .idle
    var transcript: String = ""
    /// PID of the app frontmost when recording started (paste-back fallback).
    private(set) var originAppPID: pid_t?

    private let dependencies: SpeechToTextServiceDependencies
    private var capture: AudioCapturing?
    // Text already in the box when a new recording starts, so re-dictation
    // appends to the existing transcript instead of replacing it.
    private var carriedTranscript: String = ""
    // Reused across dictations so the (multi-hundred-MB) model file is loaded
    // once, not reloaded from disk on every finishRecording(). Rebuilt only when
    // the selected model URL changes.
    private var transcriber: Transcribing?
    private var transcriberURL: URL?

    init(dependencies: SpeechToTextServiceDependencies) {
        self.dependencies = dependencies
    }

    func startRecording() {
        // WHY: AVAudioEngine crashes if start() is called again without an
        // intervening stop(); guard against re-entrant taps on the notch shortcut.
        guard phase != .recording, phase != .transcribing else { return }
        guard dependencies.microphoneAuthorized() else { phase = .error(.microphoneDenied); return }
        guard dependencies.isModelDownloaded() else { phase = .error(.modelMissing); return }

        // Carry any text already under review so this recording appends to it.
        let carried: String
        if case .review = phase { carried = transcript } else { carried = "" }

        let capture = dependencies.makeCapture()
        do {
            try capture.start()
        } catch {
            phase = .error(.transcriptionFailed)
            return
        }
        self.capture = capture
        carriedTranscript = carried
        originAppPID = dependencies.frontmostAppPID()
        transcript = carried
        phase = .recording
    }

    func finishRecording() async {
        guard case .recording = phase, let capture else { return }
        let samples = capture.stop()
        self.capture = nil
        phase = .transcribing

        let url = dependencies.modelURL()
        let transcriber: Transcribing
        if let cached = self.transcriber, transcriberURL == url {
            transcriber = cached
        } else {
            transcriber = dependencies.makeTranscriber(url)
            self.transcriber = transcriber
            transcriberURL = url
        }
        let language = dependencies.language()
        do {
            let newText = try await transcriber.transcribe(samples: samples, language: language)
            // WHY: re-check phase — the user may have cancelled (reset → .idle) or
            // started a new recording while transcription was in flight. Committing
            // the result unconditionally would resurrect a dismissed dictation box.
            guard case .transcribing = phase else { return }
            let combined = Self.appended(carriedTranscript, newText)
            guard !combined.isEmpty else { phase = .error(.transcriptionFailed); return }
            transcript = combined
            phase = .review(combined)
        } catch {
            guard case .transcribing = phase else { return }
            phase = .error(.transcriptionFailed)
        }
    }

    static func appended(_ existing: String, _ addition: String) -> String {
        guard !existing.isEmpty else { return addition }
        guard !addition.isEmpty else { return existing }
        return existing + " " + addition
    }

    func reset() {
        _ = capture?.stop()
        capture = nil
        carriedTranscript = ""
        originAppPID = nil
        transcript = ""
        phase = .idle
    }

    @discardableResult
    func send(
        using injector: (String, SessionData?) async -> InjectionResult,
        targetSession: SessionData?
    ) async -> InjectionResult {
        guard case .review = phase else { return .failed }
        phase = .sending
        let result = await injector(transcript, targetSession)
        switch result {
        case .sent:
            reset()
        case .noSession:
            phase = .error(.noActiveSession)
        case .notInjectable:
            phase = .error(.sessionNotInjectable)
        case .needsAccessibility:
            phase = .error(.accessibilityDenied)
        case .failed:
            phase = .review(transcript)
        }
        return result
    }
}
