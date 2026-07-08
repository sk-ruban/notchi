import Foundation

nonisolated struct UsageResponse: Decodable {
    let fiveHour: QuotaPeriod?
    let sevenDay: QuotaPeriod?
    let sevenDayOpus: QuotaPeriod?
    let sevenDaySonnet: QuotaPeriod?
    let extraUsage: ExtraUsage?
    let limits: [UsageLimitEntry]?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage = "extra_usage"
        case limits
    }

    var modelWeekly: (name: String, period: QuotaPeriod)? {
        if let entry = limits?.first(where: { $0.kind == "weekly_scoped" && $0.scope?.model != nil }) {
            let name = entry.scope?.model?.displayName ?? "Model"
            return (name, QuotaPeriod(utilization: entry.percent, resetsAt: entry.resetsAt))
        }
        if let sevenDayOpus {
            return ("Opus", sevenDayOpus)
        }
        if let sevenDaySonnet {
            return ("Sonnet", sevenDaySonnet)
        }
        return nil
    }
}

nonisolated struct UsageLimitEntry: Decodable {
    let kind: String
    let percent: Double
    let resetsAt: String?
    let scope: Scope?

    struct Scope: Decodable {
        let model: Model?

        struct Model: Decodable {
            let displayName: String?

            enum CodingKeys: String, CodingKey {
                case displayName = "display_name"
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case percent
        case resetsAt = "resets_at"
        case scope
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

        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = hours >= 48 ? [.day, .hour] : (hours > 0 ? [.hour, .minute] : [.minute])
        return formatter.string(from: interval)
    }
}

extension QuotaPeriod {
    nonisolated init(utilization: Double, resetDate: Date?) {
        self.utilization = utilization
        self.resetsAt = resetDate.map { Self.isoFractional.string(from: $0) }
    }
}
