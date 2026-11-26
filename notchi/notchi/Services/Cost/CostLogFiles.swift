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
