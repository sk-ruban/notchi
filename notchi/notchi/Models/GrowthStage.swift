import Foundation

enum GrowthStage: Int, CaseIterable, Codable {
    case egg = 0
    case larva = 1
    case pupa = 2
    case butterfly = 3
    case radiant = 4

    /// Minimum cumulative tokens required to reach this stage.
    var tokenThreshold: Int {
        switch self {
        case .egg:       return 0
        case .larva:     return 1_000_000
        case .pupa:      return 10_000_000
        case .butterfly: return 50_000_000
        case .radiant:   return 200_000_000
        }
    }

    var displayName: String {
        switch self {
        case .egg:       return "Egg"
        case .larva:     return "Larva"
        case .pupa:      return "Pupa"
        case .butterfly: return "Butterfly"
        case .radiant:   return "Radiant"
        }
    }

    var emoji: String {
        switch self {
        case .egg:       return "🥚"
        case .larva:     return "🐛"
        case .pupa:      return "🫘"
        case .butterfly: return "🦋"
        case .radiant:   return "✨"
        }
    }

    /// The next stage, or nil if already at max.
    var next: GrowthStage? {
        GrowthStage(rawValue: rawValue + 1)
    }

    /// Returns the stage corresponding to a given cumulative token count.
    static func stage(for tokenCount: Int) -> GrowthStage {
        GrowthStage.allCases.reversed().first { tokenCount >= $0.tokenThreshold } ?? .egg
    }

    /// Progress from 0.0 to 1.0 toward the next stage, or 1.0 if at max.
    func progress(for tokenCount: Int) -> Double {
        guard let nextStage = next else { return 1.0 }
        let current = Double(tokenCount - tokenThreshold)
        let range = Double(nextStage.tokenThreshold - tokenThreshold)
        guard range > 0 else { return 1.0 }
        return min(max(current / range, 0.0), 1.0)
    }
}
