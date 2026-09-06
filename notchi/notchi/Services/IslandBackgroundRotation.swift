import Foundation
import Observation

@MainActor
@Observable
final class IslandBackgroundRotation {
    static let shared = IslandBackgroundRotation()

    private(set) var cycle: IslandBackgroundCycle

    init() {
        cycle = Self.newCycle()
    }

    func restart() {
        cycle = Self.newCycle()
    }

    private static func newCycle() -> IslandBackgroundCycle {
        IslandBackgroundCycle(
            startedAt: Date(),
            startingBackground: IslandBackground.terrains.randomElement() ?? .grassland
        )
    }
}
