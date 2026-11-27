import Foundation
import os.log

nonisolated enum HookFile {
    static let executablePermissions: Int16 = 0o755
    // Agent configs can hold credentials, so files notchi creates are owner-only.
    private static let newConfigPermissions: Int16 = 0o600
    private static let bundledSocketAssignment = #"SOCKET_PATH="$HOME/Library/Application Support/Notchi/notchi.sock""#

    static func installableScript(from bundled: Data, socketPath: String = SocketServer.socketPath) -> Data {
        guard let script = String(data: bundled, encoding: .utf8), script.contains(bundledSocketAssignment) else {
            return bundled
        }
        return Data(script.replacingOccurrences(of: bundledSocketAssignment, with: "SOCKET_PATH=\(shellQuote(socketPath))").utf8)
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func writeScriptIfNeeded(
        _ bundledData: Data,
        to url: URL,
        fileManager: FileManager = .default
    ) throws {
        if let existingData = try? Data(contentsOf: url),
           existingData == bundledData,
           hasExecutablePermissions(at: url, fileManager: fileManager) {
            return
        }

        try bundledData.write(to: url, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: executablePermissions],
            ofItemAtPath: url.path
        )
    }

    /// Installs the app's bundled `<resource>.sh` at `url`; false, logged, when it can't.
    static func installBundledScript(named resource: String, to url: URL, agentName: String, logger: Logger) -> Bool {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create \(agentName, privacy: .public) hook directory: \(error.localizedDescription)")
            return false
        }

        guard let bundled = Bundle.main.url(forResource: resource, withExtension: "sh") else {
            logger.error("\(agentName, privacy: .public) hook script not found in bundle")
            return false
        }

        do {
            let bundledData = try Data(contentsOf: bundled)
            try writeScriptIfNeeded(installableScript(from: bundledData), to: url, fileManager: fileManager)
            return true
        } catch {
            logger.error("Failed to install \(agentName, privacy: .public) hook script: \(error.localizedDescription)")
            return false
        }
    }

    /// Writes atomically through symlinks (dotfiles), keeping the file's permissions.
    static func writeConfig(_ data: Data, to url: URL, fileManager: FileManager = .default) throws {
        let target = writeTarget(for: url, fileManager: fileManager)
        let existingPermissions = (try? fileManager.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?
            .int16Value
        try data.write(to: target, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: existingPermissions ?? newConfigPermissions],
            ofItemAtPath: target.path
        )
    }

    // Bounds a symlink cycle; real dotfile chains are one or two links deep.
    private static let maxSymlinkHops = 32

    /// Follows every link to the final file, even a missing one, so an atomic write keeps the links.
    /// resolvingSymlinksInPath() stops at a link whose target doesn't exist yet.
    private static func writeTarget(for url: URL, fileManager: FileManager) -> URL {
        var target = url
        for _ in 0..<maxSymlinkHops {
            guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: target.path) else { break }
            // A relative link's ".." is taken from the real directory, which may itself be a symlink.
            let linkDirectory = target.deletingLastPathComponent().resolvingSymlinksInPath()
            target = URL(fileURLWithPath: destination, relativeTo: linkDirectory).standardizedFileURL
        }
        return target
    }

    /// Empty or whitespace-only content, which is safe to treat as a new file.
    static func isBlank(_ data: Data) -> Bool {
        data.allSatisfy { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\n") || $0 == UInt8(ascii: "\r") || $0 == UInt8(ascii: "\t") }
    }

    static func hasExecutablePermissions(at url: URL, fileManager: FileManager = .default) -> Bool {
        guard let permissions = try? fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber else {
            return false
        }
        return permissions.int16Value == executablePermissions
    }
}
