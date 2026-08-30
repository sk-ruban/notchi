import Foundation

enum GitBranchReader {
    private nonisolated static let symbolicRefPrefix = "ref: refs/heads/"
    private nonisolated static let gitdirPrefix = "gitdir: "
    private nonisolated static let shortShaLength = 7

    nonisolated static func branch(forRepositoryAt path: String) -> String? {
        guard !path.isEmpty, let gitDirectory = findGitDirectory(startingAt: URL(fileURLWithPath: path)) else {
            return nil
        }
        guard let head = try? String(contentsOf: gitDirectory.appendingPathComponent("HEAD"), encoding: .utf8) else {
            return nil
        }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(symbolicRefPrefix) {
            return String(trimmed.dropFirst(symbolicRefPrefix.count))
        }
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(shortShaLength))
    }

    private nonisolated static func findGitDirectory(startingAt start: URL) -> URL? {
        var current = start.standardizedFileURL
        while true {
            let candidate = current.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) {
                return isDirectory.boolValue ? candidate : resolveGitdirFile(candidate, relativeTo: current)
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
    }

    private nonisolated static func resolveGitdirFile(_ file: URL, relativeTo base: URL) -> URL? {
        guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(gitdirPrefix) else { return nil }
        let target = String(trimmed.dropFirst(gitdirPrefix.count))
        return target.hasPrefix("/")
            ? URL(fileURLWithPath: target)
            : base.appendingPathComponent(target).standardizedFileURL
    }
}
