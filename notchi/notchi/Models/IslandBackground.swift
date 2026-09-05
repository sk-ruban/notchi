import Foundation

enum IslandBackground: String, CaseIterable, Identifiable {
    case grassland
    case water
    case ground

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .grassland: String(localized: "Grassland")
        case .water: String(localized: "Water")
        case .ground: String(localized: "Ground")
        }
    }

    var assetName: String {
        switch self {
        case .grassland: "GrassIsland"
        case .water: WaterAnimation.assetName(frame: 0)
        case .ground: "IslandGround"
        }
    }

    static func resolve(_ rawValue: String?) -> IslandBackground {
        rawValue.flatMap(Self.init(rawValue:)) ?? .grassland
    }
}

enum WaterAnimation {
    static let frameCount = 8
    static let framesPerSecond: Double = 4

    static func frameIndex(at date: Date, reduceMotion: Bool = false) -> Int {
        guard !reduceMotion else { return 0 }
        let frame = Int(floor(date.timeIntervalSinceReferenceDate * framesPerSecond))
        return ((frame % frameCount) + frameCount) % frameCount
    }

    static func assetName(frame: Int) -> String {
        "IslandWater\(frame)"
    }
}
