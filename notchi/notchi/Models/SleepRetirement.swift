import Foundation

/// How long a session may sleep before it is removed; its next event brings it back.
enum SleepRetirement: String, CaseIterable, Identifiable {
    case thirtyMinutes
    case oneHour
    case twoHours
    case fiveHours
    case twelveHours
    case oneDay
    case never

    private static let secondsPerMinute: TimeInterval = 60
    private static let secondsPerHour: TimeInterval = 3600

    var id: String { rawValue }

    var duration: TimeInterval? {
        switch self {
        case .thirtyMinutes: 30 * Self.secondsPerMinute
        case .oneHour: Self.secondsPerHour
        case .twoHours: 2 * Self.secondsPerHour
        case .fiveHours: 5 * Self.secondsPerHour
        case .twelveHours: 12 * Self.secondsPerHour
        case .oneDay: 24 * Self.secondsPerHour
        case .never: nil
        }
    }

    var displayName: String {
        switch self {
        case .thirtyMinutes: String(localized: "30 minutes")
        case .oneHour: String(localized: "1 hour")
        case .twoHours: String(localized: "2 hours")
        case .fiveHours: String(localized: "5 hours")
        case .twelveHours: String(localized: "12 hours")
        case .oneDay: String(localized: "24 hours")
        case .never: String(localized: "Never")
        }
    }

    /// The label that fits a chip in the settings row.
    var shortName: String {
        switch self {
        case .thirtyMinutes: String(localized: "30m")
        case .oneHour: String(localized: "1h")
        case .twoHours: String(localized: "2h")
        case .fiveHours: String(localized: "5h")
        case .twelveHours: String(localized: "12h")
        case .oneDay: String(localized: "24h")
        case .never: String(localized: "Off")
        }
    }
}
