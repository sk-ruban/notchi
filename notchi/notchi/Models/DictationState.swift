import Foundation

nonisolated enum DictationError: Equatable, Sendable {
    case microphoneDenied
    case accessibilityDenied
    case modelMissing
    case noActiveSession
    case sessionNotInjectable
    case transcriptionFailed
}

nonisolated enum DictationPhase: Equatable, Sendable {
    case idle
    case recording
    case transcribing
    case review(String)
    case sending
    case error(DictationError)
}

nonisolated enum InjectionResult: Equatable, Sendable {
    case sent
    case notInjectable
    case noSession
    case needsAccessibility
    case failed
}
