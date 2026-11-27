import Foundation
import os.log

nonisolated private let devinHookLogger = Logger(subsystem: "com.ruban.notchi", category: "DevinHookInstaller")

struct DevinHookInstaller {
    nonisolated private static let hookScriptName = "notchi-devin-hook.sh"
    nonisolated private static let legacyClaudeHookScriptName = "notchi-hook.sh"
    nonisolated private static let configWritingOptions: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]

    nonisolated static let supportedEvents = [
        "SessionStart",
        "SessionEnd",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "Stop",
    ]

    nonisolated static var devinDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("devin", isDirectory: true)
    }

    nonisolated static var configURL: URL {
        devinDirectoryURL.appendingPathComponent("config.json")
    }

    nonisolated static var hooksDirectoryURL: URL {
        devinDirectoryURL.appendingPathComponent("hooks", isDirectory: true)
    }

    nonisolated static var hookScriptURL: URL {
        hooksDirectoryURL.appendingPathComponent(hookScriptName)
    }

    @discardableResult
    nonisolated static func installIfNeeded() -> Bool {
        let fileManager = FileManager.default

        guard devinDirectoryExists(fileManager: fileManager, directoryURL: devinDirectoryURL) else {
            devinHookLogger.warning("Devin not installed (config dir not found at \(devinDirectoryURL.path, privacy: .public))")
            return false
        }

        guard HookFile.installBundledScript(
            named: "notchi-devin-hook",
            to: hookScriptURL,
            agentName: "Devin",
            logger: devinHookLogger
        ) else { return false }

        let existingData = try? Data(contentsOf: configURL)
        guard let data = upsertConfig(from: existingData, command: hookScriptURL.path) else {
            devinHookLogger.error("Left Devin config.json untouched: it is not a JSON object Notchi can safely update")
            return false
        }

        guard data != existingData else { return true }

        do {
            try writeConfig(data, to: configURL)
            return true
        } catch {
            devinHookLogger.error("Failed to write Devin config.json: \(error.localizedDescription)")
            return false
        }
    }

    nonisolated static func uninstall() {
        try? FileManager.default.removeItem(at: hookScriptURL)

        HookConfigJSON.pruneManagedHooks(
            inConfigAt: configURL,
            fileDescription: "Devin config.json",
            isManaged: isManagedCommand,
            options: configWritingOptions,
            logger: devinHookLogger
        )
    }

    nonisolated static func isInstalled() -> Bool {
        isHookInstalled(in: try? Data(contentsOf: configURL))
    }

    nonisolated static func devinDirectoryExists(
        fileManager: FileManager = .default,
        directoryURL: URL = devinDirectoryURL
    ) -> Bool {
        fileManager.fileExists(atPath: directoryURL.path)
    }

    nonisolated static func upsertConfig(from existingData: Data?, command: String) -> Data? {
        guard var json = HookConfigJSON.editableObject(from: existingData) else { return nil }

        var hooks = json["hooks"] as? [String: Any] ?? [:]
        let hookGroup: [String: Any] = ["hooks": [["type": "command", "command": command]]]

        for event in supportedEvents {
            let existingEntries = hooks[event] as? [[String: Any]] ?? []
            hooks[event] = HookConfigJSON.pruneManagedHooks(from: existingEntries, isManaged: isManagedCommand) + [hookGroup]
        }

        json["hooks"] = hooks
        return HookConfigJSON.serialize(json, options: configWritingOptions)
    }

    nonisolated static func removeManagedHooks(from existingData: Data?) -> Data? {
        HookConfigJSON.removeManagedHooks(from: existingData, isManaged: isManagedCommand, options: configWritingOptions)
    }

    nonisolated static func isHookInstalled(in configData: Data?) -> Bool {
        guard let configData,
              let json = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }

        return supportedEvents.allSatisfy { event in
            let entries = hooks[event] as? [[String: Any]] ?? []
            return entries.contains { entry in
                let entryHooks = entry["hooks"] as? [[String: Any]] ?? []
                return entryHooks.contains { hook in
                    scriptName(of: hook["command"] as? String ?? "") == hookScriptName
                }
            }
        }
    }

    nonisolated static func writeConfig(_ data: Data, to url: URL, fileManager: FileManager = .default) throws {
        try HookFile.writeConfig(data, to: url, fileManager: fileManager)
    }

    nonisolated private static func isManagedCommand(_ command: String) -> Bool {
        [hookScriptName, legacyClaudeHookScriptName].contains(scriptName(of: command))
    }

    nonisolated private static func scriptName(of command: String) -> String {
        let path = command.trimmingCharacters(in: CharacterSet(charactersIn: "\"'").union(.whitespaces))
        return (path as NSString).lastPathComponent
    }
}
