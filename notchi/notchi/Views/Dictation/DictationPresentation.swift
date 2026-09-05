import Foundation

nonisolated enum DictationCTA: Equatable {
    case none, grantMicrophone, grantAccessibility, downloadModel, noSession, sessionNotInjectable, retry
}

nonisolated enum DictationPresentation {
    static func cta(for phase: DictationPhase) -> DictationCTA {
        guard case let .error(error) = phase else { return .none }
        switch error {
        case .microphoneDenied: return .grantMicrophone
        case .accessibilityDenied: return .grantAccessibility
        case .modelMissing: return .downloadModel
        case .noActiveSession: return .noSession
        case .sessionNotInjectable: return .sessionNotInjectable
        case .transcriptionFailed: return .retry
        }
    }

    static func isEditable(_ phase: DictationPhase) -> Bool {
        if case .review = phase { return true }
        return false
    }

    static func isBusy(_ phase: DictationPhase) -> Bool {
        switch phase {
        case .recording, .transcribing: return true
        default: return false
        }
    }

    /// Keep the editor mounted across a re-dictation (review → recording →
    /// transcribing → review) whenever there's already text, so the box doesn't
    /// flit out and back — the new speech appends into the same visible field.
    static func showsEditor(_ phase: DictationPhase, hasText: Bool) -> Bool {
        isEditable(phase) || (isBusy(phase) && hasText)
    }

    static func statusText(for phase: DictationPhase) -> String {
        switch phase {
        case .idle: return String(localized: "Hold to dictate")
        case .recording: return String(localized: "Listening…")
        case .transcribing: return String(localized: "Transcribing…")
        case .review: return String(localized: "Review and send")
        case .sending: return String(localized: "Sending…")
        case .error(.microphoneDenied): return String(localized: "Microphone access needed")
        case .error(.accessibilityDenied): return String(localized: "Accessibility access needed")
        case .error(.modelMissing): return String(localized: "Download a model to dictate")
        case .error(.noActiveSession): return String(localized: "No active session")
        case .error(.sessionNotInjectable): return String(localized: "This session can't receive dictation")
        case .error(.transcriptionFailed): return String(localized: "Didn't catch that")
        }
    }
}
