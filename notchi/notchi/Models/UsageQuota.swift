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
    let resetDate: Date?

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
        let resetsAt = try container.decodeIfPresent(String.self, forKey: .resetsAt)
        resetDate = resetsAt.flatMap(Self.parseISO8601)
    }

    init(utilization: Double, resetDate: Date? = nil) {
        self.utilization = utilization
        self.resetDate = resetDate
    }

    var usagePercentage: Int {
        Int(utilization.rounded())
    }

    var isExpired: Bool {
        guard let resetDate else { return true }
        return resetDate <= Date()
    }

    var formattedResetTime: String? {
        guard let resetDate, resetDate > Date() else { return nil }

        let interval = resetDate.timeIntervalSince(Date())
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    private static func parseISO8601(_ string: String) -> Date? {
        isoFormatterWithFractionalSeconds.date(from: string)
            ?? isoFormatter.date(from: string)
    }
}
