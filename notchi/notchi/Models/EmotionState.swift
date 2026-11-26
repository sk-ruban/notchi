import Foundation
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "EmotionState")

@MainActor
@Observable
final class EmotionState {
    private(set) var currentEmotion: NotchiEmotion = .neutral
    private(set) var scores: [NotchiEmotion: Double] = [
        .happy: 0.0,
        .sad: 0.0
    ]

    static let sadThreshold = 0.45
    static let happyThreshold = 0.6
    static let elatedEscalationThreshold = 0.9
    static let sobEscalationThreshold = 0.9
    static let intensityDampen = 0.5
    static let decayRate = 0.92
    static let interEmotionDecay = 0.9
    static let neutralCounterDecay = 0.85
    static let decayInterval: Duration = .seconds(60)

    private var scoresDescription: String {
        scores
            .sorted(by: { $0.key.rawValue < $1.key.rawValue })
            .map { "\($0.key.rawValue): \(String(format: "%.2f", $0.value))" }
            .joined(separator: ", ")
    }

    init() {}

    nonisolated deinit {}

    func recordEmotion(_ rawEmotion: String, intensity: Double, prompt _: String) {
        let emotion = NotchiEmotion(rawValue: rawEmotion)

        if let emotion, emotion != .neutral {
            let dampened = intensity * Self.intensityDampen
            scores[emotion, default: 0.0] = min(scores[emotion, default: 0.0] + dampened, 1.0)
            for key in scores.keys where key != emotion {
                scores[key, default: 0.0] *= Self.interEmotionDecay
            }
        } else {
            // Neutral or unknown: actively counter all non-neutral scores
            for key in scores.keys {
                scores[key, default: 0.0] *= Self.neutralCounterDecay
            }
        }

        updateCurrentEmotion()
        logger.info(
            "Emotion analysis: detected \(rawEmotion, privacy: .public) intensity \(String(format: "%.2f", intensity), privacy: .public); current \(self.currentEmotion.rawValue, privacy: .public); scores {\(self.scoresDescription, privacy: .public)}"
        )
    }

    var hasScores: Bool {
        scores.values.contains { $0 > 0 }
    }

    func decayAll() {
        var anyChanged = false
        for key in scores.keys {
            let old = scores[key, default: 0.0]
            let new = old * Self.decayRate
            scores[key] = new < 0.01 ? 0.0 : new
            if scores[key] != old { anyChanged = true }
        }

        if anyChanged {
            updateCurrentEmotion()
        }
    }

    private func updateCurrentEmotion() {
        currentEmotion = Self.resolvedEmotion(for: scores)
    }

    static func resolvedEmotion(for scores: [NotchiEmotion: Double]) -> NotchiEmotion {
        let best = scores.max(by: { $0.value < $1.value })

        if let best {
            let threshold = best.key == .sad ? Self.sadThreshold : Self.happyThreshold
            if best.value >= threshold {
                if best.key == .happy && best.value >= Self.elatedEscalationThreshold {
                    return .elated
                } else if best.key == .sad && best.value >= Self.sobEscalationThreshold {
                    return .sob
                } else {
                    return best.key
                }
            } else {
                return .neutral
            }
        } else {
            return .neutral
        }
    }
}
