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
    private let _resetDate: Date?

    private static let isoFormatterWithFractionalSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoFormatter = ISO8601DateFormatter()

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        utilization = try container.decode(Double.self, forKey: .utilization)
        resetsAt = try container.decodeIfPresent(String.self, forKey: .resetsAt)
        _resetDate = nil
    }

    init(utilization: Double, resetsAt: String? = nil) {
        self.utilization = utilization
        self.resetsAt = resetsAt
        _resetDate = nil
    }

    init(utilization: Double, resetDate: Date?) {
        self.utilization = utilization
        self.resetsAt = nil
        self._resetDate = resetDate
    }

    var usagePercentage: Int {
        Int(utilization.rounded())
    }

    var resetDate: Date? {
        if let _resetDate { return _resetDate }
        guard let resetsAt else { return nil }
        return Self.isoFormatterWithFractionalSeconds.date(from: resetsAt)
            ?? Self.isoFormatter.date(from: resetsAt)
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
