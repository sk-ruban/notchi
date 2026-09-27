import Foundation

nonisolated struct DevinUsage: Equatable, Sendable {
    let daily: QuotaPeriod?
    let weekly: QuotaPeriod?
}

nonisolated enum DevinUsageReader {
    private static let userStatusQuery = """
        SELECT json_extract(CAST(value AS TEXT), '$.userStatusProtoBinaryBase64') \
        FROM ItemTable WHERE key = 'windsurfAuthStatus' LIMIT 1;
        """

    private enum UserStatusField {
        static let planStatus: UInt64 = 13
    }

    private enum PlanStatusField {
        static let planInfo: UInt64 = 1
        static let dailyRemainingPercent: UInt64 = 14
        static let weeklyRemainingPercent: UInt64 = 15
        static let dailyResetUnix: UInt64 = 17
        static let weeklyResetUnix: UInt64 = 18
    }

    private enum QuotaWindow {
        static let daily: TimeInterval = 86_400
        static let weekly: TimeInterval = 604_800
    }

    private enum PlanInfoField {
        static let hideDailyQuota: UInt64 = 36
        static let hideWeeklyQuota: UInt64 = 37
    }

    static var stateDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Devin/User/globalStorage/state.vscdb")
    }

    static func readUsage(databasePath: String = stateDatabaseURL.path, now: Date) -> DevinUsage? {
        guard FileManager.default.fileExists(atPath: databasePath),
              let encoded = CodexFileSystem.runSQLite(query: userStatusQuery, databasePath: databasePath, readOnly: true),
              let proto = Data(base64Encoded: encoded) else {
            return nil
        }

        return usage(fromUserStatusProto: proto, now: now)
    }

    static func usage(fromUserStatusProto proto: Data, now: Date) -> DevinUsage? {
        guard let userStatus = ProtobufFields(proto),
              let planStatusData = userStatus.bytes(UserStatusField.planStatus),
              let planStatus = ProtobufFields(planStatusData) else {
            return nil
        }

        let planInfo = planStatus.bytes(PlanStatusField.planInfo).flatMap(ProtobufFields.init)
        let hidesDaily = planInfo?.varint(PlanInfoField.hideDailyQuota) == 1
        let hidesWeekly = planInfo?.varint(PlanInfoField.hideWeeklyQuota) == 1

        return DevinUsage(
            daily: hidesDaily ? nil : quota(
                remainingPercent: planStatus.varint(PlanStatusField.dailyRemainingPercent),
                resetUnix: planStatus.varint(PlanStatusField.dailyResetUnix),
                window: QuotaWindow.daily,
                now: now
            ),
            weekly: hidesWeekly ? nil : quota(
                remainingPercent: planStatus.varint(PlanStatusField.weeklyRemainingPercent),
                resetUnix: planStatus.varint(PlanStatusField.weeklyResetUnix),
                window: QuotaWindow.weekly,
                now: now
            )
        )
    }

    private static func quota(
        remainingPercent: UInt64?,
        resetUnix: UInt64?,
        window: TimeInterval,
        now: Date
    ) -> QuotaPeriod? {
        guard let resetUnix else { return nil }
        let resetDate = Date(timeIntervalSince1970: TimeInterval(resetUnix))
        guard resetDate > now else {
            let windowsPassed = (now.timeIntervalSince(resetDate) / window).rounded(.down) + 1
            return QuotaPeriod(utilization: 0, resetDate: resetDate.addingTimeInterval(windowsPassed * window))
        }

        let remaining = Double(min(remainingPercent ?? 0, 100))
        return QuotaPeriod(utilization: 100 - remaining, resetDate: resetDate)
    }
}

private nonisolated struct ProtobufFields {
    private var varints: [UInt64: UInt64] = [:]
    private var lengthDelimited: [UInt64: Data] = [:]

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        var index = 0

        while index < bytes.count {
            guard let key = Self.readVarint(bytes, &index) else { return nil }
            let fieldNumber = key >> 3

            switch key & 0x7 {
            case 0:
                guard let value = Self.readVarint(bytes, &index) else { return nil }
                varints[fieldNumber] = value
            case 1:
                index += 8
            case 2:
                guard let length = Self.readVarint(bytes, &index),
                      length <= UInt64(bytes.count - index) else { return nil }
                let end = index + Int(length)
                lengthDelimited[fieldNumber] = Data(bytes[index..<end])
                index = end
            case 5:
                index += 4
            default:
                return nil
            }

            guard index <= bytes.count else { return nil }
        }
    }

    func varint(_ fieldNumber: UInt64) -> UInt64? {
        varints[fieldNumber]
    }

    func bytes(_ fieldNumber: UInt64) -> Data? {
        lengthDelimited[fieldNumber]
    }

    private static func readVarint(_ bytes: [UInt8], _ index: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0

        while index < bytes.count, shift < 64 {
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }

        return nil
    }
}
