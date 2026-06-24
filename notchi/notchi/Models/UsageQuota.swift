import Foundation

nonisolated struct UsageResponse: Decodable {
    let fiveHour: QuotaPeriod?
    let sevenDay: QuotaPeriod?
    let sevenDaySonnet: QuotaPeriod?
    let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage = "extra_usage"
    }
}

nonisolated struct ExtraUsage: Codable, Equatable {
    let isEnabled: Bool
    let monthlyLimit: Double?
    let usedCredits: Double?
    let utilization: Double?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
    }
}

nonisolated struct QuotaPeriod: Codable, Equatable, Sendable {
    let utilization: Double
    let resetsAt: String?

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoBasic = ISO8601DateFormatter()

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    var usagePercentage: Int {
        Int(utilization.rounded())
    }

    var resetDate: Date? {
        guard let resetsAt else { return nil }
        return Self.isoFractional.date(from: resetsAt) ?? Self.isoBasic.date(from: resetsAt)
    }

    var isExpired: Bool {
        guard let resetDate else { return true }
        return resetDate <= Date()
    }

    var formattedResetTime: String? {
        guard let resetDate else { return nil }
        let now = Date()
        guard resetDate > now else { return nil }

        let interval = resetDate.timeIntervalSince(now)
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60

        if hours >= 48 {
            let remainingHours = hours % 24
            return remainingHours > 0 ? "\(hours / 24)d \(remainingHours)h" : "\(hours / 24)d"
        } else if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}

extension QuotaPeriod {
    nonisolated init(utilization: Double, resetDate: Date?) {
        self.utilization = utilization
        self.resetsAt = resetDate.map { Self.isoFractional.string(from: $0) }
    }
}
