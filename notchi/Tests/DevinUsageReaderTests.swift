import Foundation
import XCTest
@testable import notchi

final class DevinUsageReaderTests: XCTestCase {
    private static let dailyResetUnix: UInt64 = 1_790_496_000
    private static let weeklyResetUnix: UInt64 = 1_790_928_000
    private static let now = Date(timeIntervalSince1970: 1_790_490_000)
    private static let secondsPerDay: UInt64 = 86_400
    private static let secondsPerWeek: UInt64 = 604_800

    func testDecodesDailyAndWeeklyUsageFromPlanStatus() throws {
        let proto = Self.userStatus(planStatus: Self.planStatus(
            dailyRemaining: 99,
            weeklyRemaining: 60,
            dailyReset: Self.dailyResetUnix,
            weeklyReset: Self.weeklyResetUnix
        ))

        let usage = try XCTUnwrap(DevinUsageReader.usage(fromUserStatusProto: proto, now: Self.now))

        XCTAssertEqual(usage.daily?.usagePercentage, 1)
        XCTAssertEqual(usage.daily?.resetDate, Date(timeIntervalSince1970: TimeInterval(Self.dailyResetUnix)))
        XCTAssertEqual(usage.weekly?.usagePercentage, 40)
        XCTAssertEqual(usage.weekly?.resetDate, Date(timeIntervalSince1970: TimeInterval(Self.weeklyResetUnix)))
    }

    func testMissingRemainingPercentWithResetTimeMeansQuotaIsUsedUp() throws {
        let proto = Self.userStatus(planStatus: Self.planStatus(
            dailyRemaining: nil,
            weeklyRemaining: 100,
            dailyReset: Self.dailyResetUnix,
            weeklyReset: Self.weeklyResetUnix
        ))

        let usage = try XCTUnwrap(DevinUsageReader.usage(fromUserStatusProto: proto, now: Self.now))

        XCTAssertEqual(usage.daily?.usagePercentage, 100)
        XCTAssertEqual(usage.weekly?.usagePercentage, 0)
    }

    func testHiddenQuotasAreOmitted() throws {
        let planInfo = Self.varintField(36, 1) + Self.varintField(37, 0)
        let proto = Self.userStatus(planStatus: Self.lengthDelimitedField(1, planInfo) + Self.planStatus(
            dailyRemaining: 99,
            weeklyRemaining: 60,
            dailyReset: Self.dailyResetUnix,
            weeklyReset: Self.weeklyResetUnix
        ))

        let usage = try XCTUnwrap(DevinUsageReader.usage(fromUserStatusProto: proto, now: Self.now))

        XCTAssertNil(usage.daily)
        XCTAssertEqual(usage.weekly?.usagePercentage, 40)
    }

    func testQuotaWithoutResetTimeOrRemainingPercentIsOmitted() throws {
        let proto = Self.userStatus(planStatus: Self.planStatus(
            dailyRemaining: nil,
            weeklyRemaining: 60,
            dailyReset: nil,
            weeklyReset: Self.weeklyResetUnix
        ))

        let usage = try XCTUnwrap(DevinUsageReader.usage(fromUserStatusProto: proto, now: Self.now))

        XCTAssertNil(usage.daily)
        XCTAssertEqual(usage.weekly?.usagePercentage, 40)
    }

    func testPassedDailyResetRollsOverToZeroUsageUntilTheNextDay() throws {
        let proto = Self.userStatus(planStatus: Self.planStatus(
            dailyRemaining: 10,
            weeklyRemaining: 60,
            dailyReset: Self.dailyResetUnix,
            weeklyReset: Self.weeklyResetUnix
        ))
        let afterDailyReset = Date(timeIntervalSince1970: TimeInterval(Self.dailyResetUnix + 1))

        let usage = try XCTUnwrap(DevinUsageReader.usage(fromUserStatusProto: proto, now: afterDailyReset))

        XCTAssertEqual(usage.daily?.usagePercentage, 0)
        XCTAssertEqual(usage.daily?.resetDate, Date(timeIntervalSince1970: TimeInterval(Self.dailyResetUnix + Self.secondsPerDay)))
        XCTAssertEqual(usage.weekly?.usagePercentage, 40)
    }

    func testRolloverSkipsEveryWindowThatHasAlreadyPassed() throws {
        let proto = Self.userStatus(planStatus: Self.planStatus(
            dailyRemaining: 10,
            weeklyRemaining: 60,
            dailyReset: Self.dailyResetUnix,
            weeklyReset: Self.weeklyResetUnix
        ))
        let tenDaysAfterWeeklyReset = Self.weeklyResetUnix + 10 * Self.secondsPerDay
        let dailyWindowsPassed = (tenDaysAfterWeeklyReset - Self.dailyResetUnix) / Self.secondsPerDay + 1

        let usage = try XCTUnwrap(DevinUsageReader.usage(
            fromUserStatusProto: proto,
            now: Date(timeIntervalSince1970: TimeInterval(tenDaysAfterWeeklyReset))
        ))

        XCTAssertEqual(usage.weekly?.usagePercentage, 0)
        XCTAssertEqual(usage.weekly?.resetDate, Date(timeIntervalSince1970: TimeInterval(Self.weeklyResetUnix + 2 * Self.secondsPerWeek)))
        XCTAssertEqual(usage.daily?.usagePercentage, 0)
        XCTAssertEqual(
            usage.daily?.resetDate,
            Date(timeIntervalSince1970: TimeInterval(Self.dailyResetUnix + dailyWindowsPassed * Self.secondsPerDay))
        )
    }

    func testSkipsUnknownFieldsOfEveryWireType() throws {
        let unknownFields = Self.varintField(2, 7)
            + Data([0x19]) + Data(repeating: 0xAB, count: 8)
            + Data([0x25]) + Data(repeating: 0xCD, count: 4)
            + Self.lengthDelimitedField(5, Data("ignored".utf8))
        let proto = unknownFields + Self.userStatus(planStatus: Self.planStatus(
            dailyRemaining: 99,
            weeklyRemaining: 60,
            dailyReset: Self.dailyResetUnix,
            weeklyReset: Self.weeklyResetUnix
        ))

        let usage = try XCTUnwrap(DevinUsageReader.usage(fromUserStatusProto: proto, now: Self.now))

        XCTAssertEqual(usage.daily?.usagePercentage, 1)
    }

    func testReturnsNilWithoutPlanStatus() {
        XCTAssertNil(DevinUsageReader.usage(fromUserStatusProto: Self.varintField(2, 7), now: Self.now))
    }

    func testReturnsNilForTruncatedProto() {
        let proto = Self.userStatus(planStatus: Self.planStatus(
            dailyRemaining: 99,
            weeklyRemaining: 60,
            dailyReset: Self.dailyResetUnix,
            weeklyReset: Self.weeklyResetUnix
        ))

        XCTAssertNil(DevinUsageReader.usage(fromUserStatusProto: proto.dropLast(3), now: Self.now))
    }

    func testReadsUsageFromDevinStateDatabase() throws {
        let proto = Self.userStatus(planStatus: Self.planStatus(
            dailyRemaining: 99,
            weeklyRemaining: 60,
            dailyReset: Self.dailyResetUnix,
            weeklyReset: Self.weeklyResetUnix
        ))
        let authStatus = try JSONSerialization.data(withJSONObject: [
            "apiKey": "secret-key",
            "userStatusProtoBinaryBase64": proto.base64EncodedString(),
        ])
        let databaseURL = try Self.makeStateDatabase(authStatusJSON: String(decoding: authStatus, as: UTF8.self))
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }

        let usage = try XCTUnwrap(DevinUsageReader.readUsage(databasePath: databaseURL.path, now: Self.now))

        XCTAssertEqual(usage.daily?.usagePercentage, 1)
        XCTAssertEqual(usage.weekly?.usagePercentage, 40)
    }

    func testReadUsageReturnsNilWhenDatabaseIsMissing() {
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("state.vscdb")
            .path

        XCTAssertNil(DevinUsageReader.readUsage(databasePath: missingPath, now: Self.now))
    }

    // MARK: - Protobuf fixtures

    private static func planStatus(
        dailyRemaining: UInt64?,
        weeklyRemaining: UInt64?,
        dailyReset: UInt64?,
        weeklyReset: UInt64?
    ) -> Data {
        var data = Data()
        if let dailyRemaining { data += varintField(14, dailyRemaining) }
        if let weeklyRemaining { data += varintField(15, weeklyRemaining) }
        if let dailyReset { data += varintField(17, dailyReset) }
        if let weeklyReset { data += varintField(18, weeklyReset) }
        return data
    }

    private static func userStatus(planStatus: Data) -> Data {
        lengthDelimitedField(13, planStatus)
    }

    private static func varintField(_ number: UInt64, _ value: UInt64) -> Data {
        varint(number << 3) + varint(value)
    }

    private static func lengthDelimitedField(_ number: UInt64, _ value: Data) -> Data {
        varint(number << 3 | 2) + varint(UInt64(value.count)) + value
    }

    private static func varint(_ value: UInt64) -> Data {
        var remaining = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while remaining != 0
        return Data(bytes)
    }

    private static func makeStateDatabase(authStatusJSON: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("state.vscdb")
        let escapedJSON = authStatusJSON.replacingOccurrences(of: "'", with: "''")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            databaseURL.path,
            "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);"
                + "INSERT INTO ItemTable VALUES ('windsurfAuthStatus', '\(escapedJSON)');",
        ]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return databaseURL
    }
}
