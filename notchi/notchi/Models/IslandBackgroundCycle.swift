import Foundation

struct IslandBackgroundCycle {
    static let interval: TimeInterval = 30 * 60

    let startedAt: Date
    let startingBackground: IslandBackground

    init(startedAt: Date, startingBackground: IslandBackground) {
        self.startedAt = startedAt
        self.startingBackground = startingBackground == .automatic ? .grassland : startingBackground
    }

    func background(at date: Date) -> IslandBackground {
        let terrains = IslandBackground.terrains
        let startIndex = terrains.firstIndex(of: startingBackground) ?? 0
        let elapsed = max(0, date.timeIntervalSince(startedAt))
        let step = Int(floor(elapsed / Self.interval).truncatingRemainder(dividingBy: Double(terrains.count)))
        return terrains[(startIndex + step) % terrains.count]
    }
}
