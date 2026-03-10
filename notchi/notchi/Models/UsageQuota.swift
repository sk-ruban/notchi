import Foundation

struct UsageResponse: Decodable {
    let fiveHour: QuotaPeriod?
    let sevenDay: QuotaPeriod?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

struct QuotaPeriod: Decodable {
    let utilization: Double
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    init(utilization: Double, resetsAt: String? = nil) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    var usagePercentage: Int {
        // API returns utilization as percentage (0-100), not decimal (0-1)
        Int(utilization.rounded())
    }

    var resetDate: Date? {
        guard let resetsAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: resetsAt) ?? ISO8601DateFormatter().date(from: resetsAt)
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

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}
