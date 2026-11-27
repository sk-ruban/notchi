import Foundation

/// Usage APIs, credentials and agent transcripts send ISO 8601 dates both with and without fractional seconds.
nonisolated enum ISO8601Timestamps {
    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    static let plain = ISO8601DateFormatter()

    static func date(from string: String) -> Date? {
        fractional.date(from: string) ?? plain.date(from: string)
    }
}
