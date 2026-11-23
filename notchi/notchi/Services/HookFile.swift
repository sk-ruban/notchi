import Foundation

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

    private static func writeTarget(for url: URL, fileManager: FileManager) -> URL {
        // resolvingSymlinksInPath() leaves a link to a missing file unresolved, and an atomic write would replace it.
        if !fileManager.fileExists(atPath: url.path),
           let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path) {
            return URL(fileURLWithPath: destination, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
        }
        return url.resolvingSymlinksInPath()
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
