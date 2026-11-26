import Foundation

/// A `.jsonl` log as it stood when a scan listed it.
nonisolated struct CostLogFile {
    let url: URL
    let size: Int64
    let mtime: Double
}

nonisolated enum CostLogFiles {
    /// Every log under `roots`, stat'ed once. `isComplete` is false when part of a root couldn't be read,
    /// so files there only look missing.
    static func list(in roots: [URL]) -> (files: [CostLogFile], isComplete: Bool) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        var files: [CostLogFile] = []
        var isComplete = true
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: Array(keys),
                errorHandler: { _, _ in isComplete = false; return true }) else {
                isComplete = false
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: keys), let size = values.fileSize else { continue }
                files.append(CostLogFile(url: url, size: Int64(size),
                                         mtime: values.contentModificationDate?.timeIntervalSince1970 ?? 0))
            }
        }
        return (files, isComplete)
    }
}

extension CostUsageCache {
    /// Lines up tracked file state with the logs on disk, so every tracked file can resume from its offset.
    nonisolated mutating func track(_ logs: [CostLogFile], listingIsComplete: Bool) {
        if listingIsComplete {
            forgetMissingFiles(keepingMovesTo: logs)
        }
        // A log rewritten shorter may have lost lines that are already counted, so rebuild from scratch.
        if logs.contains(where: { log in files[log.url.path].map { log.size < $0.size } ?? false }) {
            files = [:]
            buckets = [:]
        }
    }

    /// Their counted cost stays in the buckets. Codex archives a session by moving it to another folder under
    /// the same name, so a moved log keeps its state instead of being counted again from the top.
    nonisolated private mutating func forgetMissingFiles(keepingMovesTo logs: [CostLogFile]) {
        let listedPaths = Set(logs.map(\.url.path))
        let missingPaths = files.keys.filter { !listedPaths.contains($0) }
        guard !missingPaths.isEmpty else { return }
        var movedFrom = Dictionary(grouping: missingPaths) { URL(fileURLWithPath: $0).lastPathComponent }
            .compactMapValues { $0.count == 1 ? $0[0] : nil }
        for log in logs where files[log.url.path] == nil {
            if let oldPath = movedFrom.removeValue(forKey: log.url.lastPathComponent) {
                files[log.url.path] = files[oldPath]
            }
        }
        for path in missingPaths {
            files[path] = nil
        }
    }
}

nonisolated enum CostLogLine {
    // A timestamp written with a UTC offset (-12:00 to +14:00) can name a day up to two days off the local one.
    static let timeZoneSlackDays = 2

    private static let timestampKey = Data(#""timestamp""#.utf8)
    private static let valueStart = Data(#":""#.utf8)
    private static let dayLength = "yyyy-MM-dd".count

    /// The day a line's timestamp must reach to possibly fall in a window starting at `windowStart`.
    static func cutoffDay(forWindowStart windowStart: Date, calendar: Calendar) -> Data {
        let cutoff = calendar.date(byAdding: .day, value: -timeZoneSlackDays, to: windowStart) ?? windowStart
        return Data(DailyCostReport.dayKey(cutoff, calendar: calendar).utf8)
    }

    /// True when the line has a timestamp and every one is dated before `cutoffDay`, so parsing it can be skipped.
    /// Every one is checked because tool input nested in the line can carry its own.
    static func isDated(_ line: Data, before cutoffDay: Data) -> Bool {
        var searchStart = line.startIndex
        var foundTimestamp = false
        while let key = line.range(of: timestampKey, in: searchStart..<line.endIndex) {
            let dayStart = key.upperBound + valueStart.count
            let dayEnd = dayStart + dayLength
            guard dayEnd <= line.endIndex,
                  line[key.upperBound..<dayStart] == valueStart,
                  line[dayStart..<dayEnd].lexicographicallyPrecedes(cutoffDay) else { return false }
            foundTimestamp = true
            searchStart = dayEnd
        }
        return foundTimestamp
    }
}
