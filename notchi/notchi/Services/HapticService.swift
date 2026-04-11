import AppKit
import Foundation

@MainActor
final class HapticService {
    static let shared = HapticService()

    private static let hoverCooldown: TimeInterval = 0.12

    private var lastHoverClickAt: Date?

    private init() {}

    func playHoverClick() {
        let now = Date()
        if let lastHoverClickAt,
           now.timeIntervalSince(lastHoverClickAt) < Self.hoverCooldown {
            return
        }

        lastHoverClickAt = now
        // Alignment feedback reads like a light trackpad click on supported Macs.
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    func playToggle() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    func playSessionSelection() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    func playNavigationTap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}
