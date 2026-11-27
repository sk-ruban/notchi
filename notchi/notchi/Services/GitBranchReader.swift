import Foundation

enum GitBranchReader {
    private nonisolated static let symbolicRefPrefix = "ref: refs/heads/"
    private nonisolated static let gitdirPrefix = "gitdir: "
    private nonisolated static let shortShaLength = 7
    private nonisolated static let originHeadPrefix = "ref: refs/remotes/origin/"

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

    /// The branch `origin/HEAD` points at, or nil when the clone doesn't record one.
    nonisolated static func defaultBranch(forRepositoryAt path: String) -> String? {
        guard !path.isEmpty, let gitDirectory = findGitDirectory(startingAt: URL(fileURLWithPath: path)) else {
            return nil
        }
        let originHead = commonDirectory(of: gitDirectory).appendingPathComponent("refs/remotes/origin/HEAD")
        guard let contents = try? String(contentsOf: originHead, encoding: .utf8) else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(originHeadPrefix), trimmed.count > originHeadPrefix.count else { return nil }
        return String(trimmed.dropFirst(originHeadPrefix.count))
    }

    // A linked worktree's git directory keeps its own HEAD but shares refs with the main repository.
    private nonisolated static func commonDirectory(of gitDirectory: URL) -> URL {
        guard let contents = try? String(contentsOf: gitDirectory.appendingPathComponent("commondir"), encoding: .utf8) else {
            return gitDirectory
        }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return gitDirectory }
        return trimmed.hasPrefix("/")
            ? URL(fileURLWithPath: trimmed)
            : gitDirectory.appendingPathComponent(trimmed).standardizedFileURL
    }

    private nonisolated static func findGitDirectory(startingAt start: URL) -> URL? {
        var current = start.standardizedFileURL
        while true {
            let candidate = current.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) {
                return isDirectory.boolValue ? candidate : resolveGitdirFile(candidate, relativeTo: current)
            }
            guard current.pathComponents.count > 1 else { return nil }
            current = current.deletingLastPathComponent()
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
