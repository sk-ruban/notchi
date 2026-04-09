import Foundation
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "TokenGrowth")

@MainActor
@Observable
final class TokenGrowthService {
    static let shared = TokenGrowthService()

    private(set) var weeklyTokens: Int
    private(set) var currentStage: GrowthStage
    private(set) var justLeveledUp: Bool = false
    private(set) var isScanning: Bool = false
    private var weeklyTokensBeforeScan: Int = 0

    private init() {
        let storedWeek = AppSettings.weeklyTokenWeek
        let currentWeek = Self.currentWeekKey()

        let tokens: Int
        if storedWeek == currentWeek {
            tokens = AppSettings.weeklyTokenCount
        } else {
            tokens = 0
            AppSettings.weeklyTokenCount = 0
            AppSettings.weeklyTokenWeek = currentWeek
        }

        self.weeklyTokens = tokens
        self.currentStage = GrowthStage.stage(for: tokens)
        performStartupScan()
    }

    /// Add newly observed tokens. Resets automatically if the week rolled over.
    func addTokens(_ count: Int) {
        guard count > 0 else { return }

        let currentWeek = Self.currentWeekKey()
        if AppSettings.weeklyTokenWeek != currentWeek {
            weeklyTokens = 0
            AppSettings.weeklyTokenWeek = currentWeek
            currentStage = .egg
        }

        let previousStage = currentStage
        weeklyTokens += count
        AppSettings.weeklyTokenCount = weeklyTokens

        let newStage = GrowthStage.stage(for: weeklyTokens)
        currentStage = newStage

        if newStage != previousStage {
            justLeveledUp = true
            logger.info("Stage up: \(previousStage.displayName) → \(newStage.displayName) at \(self.weeklyTokens) tokens")
            Task {
                try? await Task.sleep(for: .seconds(3))
                justLeveledUp = false
            }
        }
    }

    var progressToNextStage: Double {
        currentStage.progress(for: weeklyTokens)
    }

    var tokensUntilNextStage: Int? {
        guard let next = currentStage.next else { return nil }
        return max(0, next.tokenThreshold - weeklyTokens)
    }

    static func formatTokens(_ count: Int) -> String {
        switch count {
        case 0..<1_000:
            return "\(count)"
        case 1_000..<1_000_000:
            let k = Double(count) / 1_000.0
            return k.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(k))K" : String(format: "%.1fK", k)
        default:
            let m = Double(count) / 1_000_000.0
            return m.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(m))M" : String(format: "%.1fM", m)
        }
    }

    // MARK: - Week Helpers

    static func currentWeekKey() -> String {
        let cal = Calendar(identifier: .iso8601)
        let week = cal.component(.weekOfYear, from: Date())
        let year = cal.component(.yearForWeekOfYear, from: Date())
        return String(format: "%d-W%02d", year, week)
    }

    static func currentWeekStart() -> Date {
        let cal = Calendar(identifier: .iso8601)
        let now = Date()
        let week = cal.component(.weekOfYear, from: now)
        let year = cal.component(.yearForWeekOfYear, from: now)
        var comps = DateComponents()
        comps.weekOfYear = week
        comps.yearForWeekOfYear = year
        comps.weekday = 2  // Monday
        comps.hour = 0; comps.minute = 0; comps.second = 0
        return cal.date(from: comps) ?? now
    }

    // MARK: - Startup Scan

    /// On startup, scan this week's JSONL messages and take the max with stored value.
    private func performStartupScan() {
        isScanning = true
        weeklyTokensBeforeScan = weeklyTokens
        let weekStart = Self.currentWeekStart()
        Task.detached(priority: .background) {
            let scanTotal = await Self.scanWeeklyJSONLTokens(since: weekStart)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isScanning = false
                // Any tokens added via addTokens() while the scan was running must be
                // preserved even if the scan didn't reach those JSONL lines yet.
                let liveAddedDuringScan = max(0, self.weeklyTokens - self.weeklyTokensBeforeScan)
                let reconciled = max(scanTotal, self.weeklyTokensBeforeScan) + liveAddedDuringScan
                guard reconciled > self.weeklyTokens else { return }
                logger.info("Startup scan: \(reconciled) tokens this week (scan=\(scanTotal), live=\(liveAddedDuringScan))")
                self.weeklyTokens = reconciled
                AppSettings.weeklyTokenCount = reconciled
                self.currentStage = GrowthStage.stage(for: reconciled)
            }
        }
    }

    /// Reads all *.jsonl files under ~/.claude/projects/ and sums tokens from
    /// assistant messages whose timestamp falls within the current week.
    static func scanWeeklyJSONLTokens(since weekStart: Date) async -> Int {
        let projectsURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects")
        guard FileManager.default.fileExists(atPath: projectsURL.path) else { return 0 }

        var total = 0
        let enumerator = FileManager.default.enumerator(
            at: projectsURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        let isoFractional: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        let isoBasic = ISO8601DateFormatter()

        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "jsonl" else { continue }

            // Skip files not modified since week start (fast path)
            if let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               modDate < weekStart { continue }

            total += countWeeklyTokens(in: url, since: weekStart,
                                       isoFractional: isoFractional, isoBasic: isoBasic)
        }

        return total
    }

    private static func countWeeklyTokens(
        in url: URL,
        since weekStart: Date,
        isoFractional: ISO8601DateFormatter,
        isoBasic: ISO8601DateFormatter
    ) -> Int {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        var total = 0

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            guard line.contains("\"type\":\"assistant\""),
                  let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            // Filter by timestamp
            if let tsStr = json["timestamp"] as? String {
                let ts = isoFractional.date(from: tsStr) ?? isoBasic.date(from: tsStr)
                if let ts, ts < weekStart { continue }
            }

            guard let messageDict = json["message"] as? [String: Any],
                  let usage = messageDict["usage"] as? [String: Any] else { continue }

            total += usage["input_tokens"] as? Int ?? 0
            total += usage["output_tokens"] as? Int ?? 0
            total += usage["cache_creation_input_tokens"] as? Int ?? 0
            // cache_read excluded: served from cache, not new AI work
        }

        return total
    }
}
