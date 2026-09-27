import Foundation
import os.log

nonisolated private let devinHookLogger = Logger(subsystem: "com.ruban.notchi", category: "DevinHookInstaller")

struct DevinHookInstaller {
    nonisolated private static let hookScriptName = "notchi-devin-hook.sh"
    nonisolated private static let legacyClaudeHookScriptName = "notchi-hook.sh"
    nonisolated private static let newConfigPermissions: Int16 = 0o600

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

        do {
            try fileManager.createDirectory(at: hooksDirectoryURL, withIntermediateDirectories: true)
        } catch {
            devinHookLogger.error("Failed to create Devin hook directory: \(error.localizedDescription)")
            return false
        }

        guard let bundled = Bundle.main.url(forResource: "notchi-devin-hook", withExtension: "sh") else {
            devinHookLogger.error("Devin hook script not found in bundle")
            return false
        }

        do {
            let bundledData = try Data(contentsOf: bundled)
            try HookFile.writeScriptIfNeeded(bundledData, to: hookScriptURL, fileManager: fileManager)
        } catch {
            devinHookLogger.error("Failed to install Devin hook script: \(error.localizedDescription)")
            return false
        }

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

        let existingData = try? Data(contentsOf: configURL)
        guard let data = removeManagedHooks(from: existingData) else {
            if let existingData, !existingData.isEmpty,
               (try? JSONSerialization.jsonObject(with: existingData)) == nil {
                devinHookLogger.error("Skipped pruning Devin config.json on uninstall: file is not valid JSON; stale hook references may remain")
            }
            return
        }

        do {
            try writeConfig(data, to: configURL)
        } catch {
            devinHookLogger.error("Failed to write Devin config.json on uninstall: \(error.localizedDescription)")
        }
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
        var json: [String: Any] = [:]
        if let existingData, !existingData.isEmpty {
            guard let existing = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] else {
                return nil
            }
            json = existing
        }

        var hooks = json["hooks"] as? [String: Any] ?? [:]
        let hookGroup: [String: Any] = ["hooks": [["type": "command", "command": command]]]

        for event in supportedEvents {
            let existingEntries = hooks[event] as? [[String: Any]] ?? []
            hooks[event] = pruneManagedHooks(from: existingEntries) + [hookGroup]
        }

        json["hooks"] = hooks
        return serialize(json)
    }

    nonisolated static func removeManagedHooks(from existingData: Data?) -> Data? {
        guard let existingData,
              var json = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return nil
        }

        var updatedHooks: [String: Any] = [:]
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else {
                updatedHooks[event] = value
                continue
            }

            let prunedEntries = pruneManagedHooks(from: entries)
            if !prunedEntries.isEmpty {
                updatedHooks[event] = prunedEntries
            }
        }

        if updatedHooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = updatedHooks
        }

        return serialize(json)
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
        let target = url.resolvingSymlinksInPath()
        let existingPermissions = (try? fileManager.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?
            .int16Value
        try data.write(to: target, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: existingPermissions ?? newConfigPermissions],
            ofItemAtPath: target.path
        )
    }

    nonisolated private static func pruneManagedHooks(from entries: [[String: Any]]) -> [[String: Any]] {
        entries.compactMap { entry in
            guard let entryHooks = entry["hooks"] as? [[String: Any]] else {
                return entry
            }

            let filteredHooks = entryHooks.filter { hook in
                !isManagedCommand(hook["command"] as? String ?? "")
            }

            guard !filteredHooks.isEmpty else {
                return nil
            }

            var updatedEntry = entry
            updatedEntry["hooks"] = filteredHooks
            return updatedEntry
        }
    }

    nonisolated private static func isManagedCommand(_ command: String) -> Bool {
        [hookScriptName, legacyClaudeHookScriptName].contains(scriptName(of: command))
    }

    nonisolated private static func scriptName(of command: String) -> String {
        let path = command.trimmingCharacters(in: CharacterSet(charactersIn: "\"'").union(.whitespaces))
        return (path as NSString).lastPathComponent
    }

    nonisolated private static func serialize(_ json: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }
}
