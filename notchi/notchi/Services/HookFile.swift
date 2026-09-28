import Foundation

nonisolated enum HookFile {
    static let executablePermissions: Int16 = 0o755
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

    static func hasExecutablePermissions(at url: URL, fileManager: FileManager = .default) -> Bool {
        guard let permissions = try? fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber else {
            return false
        }
        return permissions.int16Value == executablePermissions
    }
}
