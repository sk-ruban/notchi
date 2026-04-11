import Foundation

nonisolated enum CodexCLIFinder {
    nonisolated static func resolveExecutableURL() -> URL? {
        for path in searchPaths() where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    nonisolated private static func searchPaths() -> [String] {
        let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let pathEntries = environmentPath
            .split(separator: ":")
            .map { String($0) }
            .map { ($0 as NSString).appendingPathComponent("codex") }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let wellKnownPaths = [
            "\(home)/.local/bin/codex",
            "\(home)/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex",
        ]

        return Array(NSOrderedSet(array: pathEntries + wellKnownPaths)) as? [String] ?? wellKnownPaths
    }
}
