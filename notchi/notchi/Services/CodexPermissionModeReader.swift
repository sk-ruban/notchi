import Foundation

nonisolated enum CodexPermissionMode {
    static let readOnly = "codexReadOnly"
    static let standard = "codexDefault"
    static let fullAccess = "codexFullAccess"

    static func resolve(
        collaborationMode: String? = nil,
        approvalsReviewer: String? = nil,
        sandboxPolicy: [String: Any]?
    ) -> String {
        if collaborationMode == "plan" { return "plan" }
        if approvalsReviewer == "auto_review" { return "auto" }
        switch sandboxPolicy?["type"] as? String {
        case "danger-full-access": return fullAccess
        case "read-only": return readOnly
        case "managed": return managedPolicyAllowsWrites(sandboxPolicy) ? standard : readOnly
        default: return standard
        }
    }

    private static func managedPolicyAllowsWrites(_ sandboxPolicy: [String: Any]?) -> Bool {
        guard let fileSystem = sandboxPolicy?["file_system"] as? [String: Any],
              let entries = fileSystem["entries"] as? [[String: Any]] else { return false }
        return entries.contains { ($0["access"] as? String) == "write" }
    }
}

nonisolated final class CodexPermissionModeReader: @unchecked Sendable {
    static let shared = CodexPermissionModeReader()

    private static let chunkSize = 256 * 1024
    private static let turnContextMarker = Data("\"type\":\"turn_context\"".utf8)
    private static let newline = UInt8(ascii: "\n")

    private struct CacheEntry {
        var scannedThrough: UInt64
        var mode: String?
    }

    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]
    private var bytesRead = 0

    func mode(forTranscriptAt path: String) -> String? {
        guard !path.isEmpty, let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }

        let cached = lock.withLock { cache[path] }
        let entry: CacheEntry
        if let cached, cached.scannedThrough == size {
            return cached.mode
        } else if let cached, cached.scannedThrough < size {
            entry = scanForward(handle, from: cached.scannedThrough, to: size, previousMode: cached.mode)
        } else {
            entry = scanBackward(handle, size: size)
        }
        lock.withLock { cache[path] = entry }
        return entry.mode
    }

    func bytesReadForTesting() -> Int {
        lock.withLock { bytesRead }
    }

    private func read(_ handle: FileHandle, from offset: UInt64, count: Int) -> Data {
        guard count > 0,
              (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: count) else { return Data() }
        lock.withLock { bytesRead += data.count }
        return data
    }

    private func scanForward(_ handle: FileHandle, from start: UInt64, to end: UInt64, previousMode: String?) -> CacheEntry {
        let data = read(handle, from: start, count: Int(end - start))
        guard let lastNewline = data.lastIndex(of: Self.newline) else {
            return CacheEntry(scannedThrough: start, mode: previousMode)
        }
        let complete = data[data.startIndex...lastNewline]
        let mode = Self.latestMode(inLines: complete.split(separator: Self.newline))
        return CacheEntry(scannedThrough: start + UInt64(complete.count), mode: mode ?? previousMode)
    }

    private func scanBackward(_ handle: FileHandle, size: UInt64) -> CacheEntry {
        var end = size
        var tail = Data()
        var scannedThrough: UInt64 = 0
        while true {
            let start = end > UInt64(Self.chunkSize) ? end - UInt64(Self.chunkSize) : 0
            tail = read(handle, from: start, count: Int(end - start)) + tail
            if end == size, let lastNewline = tail.lastIndex(of: Self.newline) {
                scannedThrough = start + UInt64(lastNewline - tail.startIndex + 1)
            }

            var lines = tail.split(separator: Self.newline, omittingEmptySubsequences: false)
            if !lines.isEmpty { lines.removeLast() }
            if start > 0, !lines.isEmpty { lines.removeFirst() }
            if let mode = Self.latestMode(inLines: lines) {
                return CacheEntry(scannedThrough: scannedThrough, mode: mode)
            }
            if start == 0 {
                return CacheEntry(scannedThrough: scannedThrough, mode: nil)
            }
            end = start
        }
    }

    private static func latestMode(inLines lines: [Data]) -> String? {
        lines.reversed().lazy.compactMap(parseTurnContext).first
    }

    private static func parseTurnContext(_ line: Data) -> String? {
        guard line.range(of: turnContextMarker) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "turn_context",
              let payload = object["payload"] as? [String: Any] else { return nil }
        return CodexPermissionMode.resolve(
            collaborationMode: (payload["collaboration_mode"] as? [String: Any])?["mode"] as? String,
            approvalsReviewer: payload["approvals_reviewer"] as? String,
            sandboxPolicy: payload["sandbox_policy"] as? [String: Any]
        )
    }
}
