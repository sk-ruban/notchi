import Foundation

/// A `.jsonl` log as it stood when a scan listed it.
nonisolated struct CostLogFile {
    let url: URL
    let size: Int64
    let mtime: Double
}

nonisolated enum CostLogFiles {
    /// Every log under `roots`, stat'ed once.
    static func list(in roots: [URL]) -> [CostLogFile] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        var files: [CostLogFile] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys))
            else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: keys), let size = values.fileSize else { continue }
                files.append(CostLogFile(url: url, size: Int64(size),
                                         mtime: values.contentModificationDate?.timeIntervalSince1970 ?? 0))
            }
        }
        return files
    }
}

extension CostUsageCache {
    /// Lines up tracked file state with the logs on disk, so every tracked file can resume from its offset.
    nonisolated mutating func track(_ logs: [CostLogFile], windowStart: Date) {
        forgetMissingFiles(lastModifiedBefore: windowStart, keepingMovesTo: logs)
        // A log rewritten shorter may have lost lines that are already counted, so rebuild from scratch.
        if logs.contains(where: { log in files[log.url.path].map { log.size < $0.size } ?? false }) {
            files = [:]
            buckets = [:]
        }
    }

    /// A missing log's counted cost stays in the buckets. Codex archives a session by moving it to another
    /// folder under the same name, so a moved log keeps its state instead of being counted again from the top.
    nonisolated private mutating func forgetMissingFiles(lastModifiedBefore windowStart: Date,
                                                         keepingMovesTo logs: [CostLogFile]) {
        let listedPaths = Set(logs.map(\.url.path))
        let missingPaths = files.keys.filter { !listedPaths.contains($0) }
        guard !missingPaths.isEmpty else { return }
        var movedFrom = Dictionary(grouping: missingPaths) { URL(fileURLWithPath: $0).lastPathComponent }
            .compactMapValues { $0.count == 1 ? $0[0] : nil }
        for log in logs where files[log.url.path] == nil {
            if let oldPath = movedFrom.removeValue(forKey: log.url.lastPathComponent) {
                files[log.url.path] = files.removeValue(forKey: oldPath)
            }
        }
        // A log that comes back, or a root that was briefly unreadable, resumes from its offset. Only a log that
        // can't hold lines in the window is forgotten, since reading it again from the top counts nothing.
        let windowStartTime = windowStart.timeIntervalSince1970
        for path in missingPaths {
            if let state = files[path], state.mtime < windowStartTime {
                files[path] = nil
            }
        }
    }
}

nonisolated extension CostLogFiles {
    /// Calls `body` with each complete line from `startOffset` on and returns the offset just past the last one,
    /// or `startOffset` when there's nothing to read.
    static func forEachLine(in url: URL, from startOffset: Int64, _ body: (UnsafeRawBufferPointer) -> Void) -> Int64 {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return startOffset }
        defer { try? handle.close() }
        if startOffset > 0 { try? handle.seek(toOffset: UInt64(startOffset)) }
        guard let data = try? handle.readToEnd() else { return startOffset }
        return data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return startOffset }
            var lineStart = 0
            while lineStart < bytes.count,
                  let newline = memchr(base + lineStart, Int32(UInt8(ascii: "\n")), bytes.count - lineStart) {
                let lineEnd = base.distance(to: UnsafeRawPointer(newline))
                body(UnsafeRawBufferPointer(rebasing: bytes[lineStart..<lineEnd]))
                lineStart = lineEnd + 1
            }
            return startOffset + Int64(lineStart)
        }
    }
}

/// A byte string to find in log lines. Lines run to kilobytes and most lack the marker, so a
/// Boyer–Moore–Horspool search that skips ahead beats libc's memmem several times over.
nonisolated struct LogLineMarker: Sendable {
    let bytes: [UInt8]
    private let skip: [Int]

    init(_ text: String) {
        bytes = Array(text.utf8)
        var skip = [Int](repeating: bytes.count, count: Int(UInt8.max) + 1)
        for (index, byte) in bytes.dropLast().enumerated() {
            skip[Int(byte)] = bytes.count - 1 - index
        }
        self.skip = skip
    }

    func occurs(in line: UnsafeRawBufferPointer) -> Bool {
        offset(in: line, from: 0) != nil
    }

    func offset(in line: UnsafeRawBufferPointer, from start: Int) -> Int? {
        guard let base = line.baseAddress else { return nil }
        return bytes.withUnsafeBufferPointer { needle in
            guard let needleBase = needle.baseAddress else { return nil }
            return skip.withUnsafeBufferPointer { skip in
                let last = needle.count - 1
                var candidate = start
                while candidate + last < line.count {
                    let tail = line[candidate + last]
                    if tail == needle[last], memcmp(base + candidate, needleBase, last) == 0 {
                        return candidate
                    }
                    candidate += skip[Int(tail)]
                }
                return nil
            }
        }
    }
}

nonisolated enum CostLogLine {
    // A timestamp written with a UTC offset (-12:00 to +14:00) can name a day up to two days off the local one.
    static let timeZoneSlackDays = 2

    private static let fractionalTimestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeSecondTimestamp = Date.ISO8601FormatStyle()
    private static let timestampKey = LogLineMarker(#""timestamp""#)
    private static let valueStart = Array(#":""#.utf8)
    private static let dayLength = "yyyy-MM-dd".count

    /// The day a line's timestamp must reach to possibly fall in a window starting at `windowStart`.
    /// Timestamps name Gregorian days, whatever calendar the window is counted in.
    static func cutoffDay(forWindowStart windowStart: Date, timeZone: TimeZone) -> [UInt8] {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = timeZone
        let cutoff = gregorian.date(byAdding: .day, value: -timeZoneSlackDays, to: windowStart) ?? windowStart
        return Array(DailyCostReport.dayKey(cutoff, calendar: gregorian).utf8)
    }

    /// ISO8601DateFormatter goes through ICU on every call, which made it the slowest step of a scan.
    static func date(fromTimestamp text: String) -> Date? {
        (try? fractionalTimestamp.parse(text)) ?? (try? wholeSecondTimestamp.parse(text))
    }

    /// True when the line has a timestamp and every one is dated before `cutoffDay`, so parsing it can be skipped.
    /// Every one is checked because tool input nested in the line can carry its own.
    static func isDated(_ line: UnsafeRawBufferPointer, before cutoffDay: [UInt8]) -> Bool {
        var searchStart = 0
        var foundTimestamp = false
        while let key = timestampKey.offset(in: line, from: searchStart) {
            let valueOffset = key + timestampKey.bytes.count
            let dayStart = valueOffset + valueStart.count
            let dayEnd = dayStart + dayLength
            guard dayEnd <= line.count,
                  line[valueOffset..<dayStart].elementsEqual(valueStart),
                  line[dayStart..<dayEnd].lexicographicallyPrecedes(cutoffDay) else { return false }
            foundTimestamp = true
            searchStart = dayEnd
        }
        return foundTimestamp
    }
}
