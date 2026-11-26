import Foundation
import os

nonisolated struct DevinUsage: Equatable, Sendable {
    let daily: QuotaPeriod?
    let weekly: QuotaPeriod?
    var planName: String?
    var hasNoQuota = false
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

    private static let unlimitedMessageLimit = UInt64.max

    private enum PlanInfoField {
        static let planName: UInt64 = 2
        static let messageLimit: UInt64 = 12
        static let hideDailyQuota: UInt64 = 36
        static let hideWeeklyQuota: UInt64 = 37
    }

    static var stateDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Devin/User/globalStorage/state.vscdb")
    }

    private struct FileSignature: Equatable {
        let size: UInt64
        let modifiedAt: Date
    }

    private struct DatabaseSignature: Equatable {
        let databasePath: String
        let database: FileSignature
        let writeAheadLog: FileSignature?
    }

    // Keeps the last query output so an unchanged database doesn't spawn sqlite3 on every poll.
    private static let lastUserStatusRead = OSAllocatedUnfairLock<(signature: DatabaseSignature, encoded: String?)?>(
        initialState: nil
    )

    static func readUsage(
        databasePath: String = stateDatabaseURL.path,
        now: Date,
        runQuery: @Sendable (String, String) -> String? = { CodexFileSystem.runSQLite(query: $0, databasePath: $1, readOnly: true) }
    ) -> DevinUsage? {
        guard let signature = databaseSignature(databasePath: databasePath) else { return nil }

        let encoded: String?
        if let lastRead = lastUserStatusRead.withLock({ $0 }), lastRead.signature == signature {
            encoded = lastRead.encoded
        } else {
            encoded = runQuery(userStatusQuery, databasePath)
            lastUserStatusRead.withLock { $0 = (signature, encoded) }
        }

        guard let encoded, let proto = Data(base64Encoded: encoded) else { return nil }
        return usage(fromUserStatusProto: proto, now: now)
    }

    private static func databaseSignature(databasePath: String) -> DatabaseSignature? {
        guard let database = fileSignature(atPath: databasePath) else { return nil }
        return DatabaseSignature(
            databasePath: databasePath,
            database: database,
            writeAheadLog: fileSignature(atPath: databasePath + "-wal")
        )
    }

    private static func fileSignature(atPath path: String) -> FileSignature? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? UInt64,
              let modifiedAt = attributes[.modificationDate] as? Date else {
            return nil
        }
        return FileSignature(size: size, modifiedAt: modifiedAt)
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
        let dailyRemaining = planStatus.varint(PlanStatusField.dailyRemainingPercent)
        let weeklyRemaining = planStatus.varint(PlanStatusField.weeklyRemainingPercent)

        let hasUnlimitedMessages = planInfo?.varint(PlanInfoField.messageLimit) == unlimitedMessageLimit

        if hasUnlimitedMessages && dailyRemaining == nil && weeklyRemaining == nil {
            return DevinUsage(
                daily: nil,
                weekly: nil,
                planName: planInfo?.bytes(PlanInfoField.planName).map { String(decoding: $0, as: UTF8.self) },
                hasNoQuota: true
            )
        }

        return DevinUsage(
            daily: hidesDaily ? nil : quota(
                remainingPercent: dailyRemaining,
                resetUnix: planStatus.varint(PlanStatusField.dailyResetUnix),
                window: QuotaWindow.daily,
                now: now
            ),
            weekly: hidesWeekly ? nil : quota(
                remainingPercent: weeklyRemaining,
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
