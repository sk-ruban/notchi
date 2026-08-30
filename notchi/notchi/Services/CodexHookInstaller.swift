import Foundation
import os.log

nonisolated private let codexHookLogger = Logger(subsystem: "com.ruban.notchi", category: "CodexHookInstaller")

struct CodexHookInstaller {
    nonisolated private static let hookScriptName = "notchi-codex-hook.sh"

    nonisolated static var codexDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    nonisolated static var hooksJSONURL: URL {
        codexDirectoryURL.appendingPathComponent("hooks.json")
    }

    nonisolated static var configURL: URL {
        codexDirectoryURL.appendingPathComponent("config.toml")
    }

    nonisolated static var hooksDirectoryURL: URL {
        codexDirectoryURL.appendingPathComponent("hooks", isDirectory: true)
    }

    nonisolated static var hookScriptURL: URL {
        hooksDirectoryURL.appendingPathComponent(hookScriptName)
    }

    nonisolated static var hookCommand: String {
        hookScriptURL.path
    }

    @discardableResult
    nonisolated static func installIfNeeded() -> Bool {
        let fileManager = FileManager.default

        guard codexDirectoryExists(fileManager: fileManager, directoryURL: codexDirectoryURL) else {
            codexHookLogger.warning("Codex not installed (config dir not found at \(codexDirectoryURL.path, privacy: .public))")
            return false
        }

        do {
            try fileManager.createDirectory(at: hooksDirectoryURL, withIntermediateDirectories: true)
        } catch {
            codexHookLogger.error("Failed to create Codex hook directories: \(error.localizedDescription)")
            return false
        }

        guard let bundled = Bundle.main.url(forResource: "notchi-codex-hook", withExtension: "sh") else {
            codexHookLogger.error("Codex hook script not found in bundle")
            return false
        }

        do {
            let bundledData = try Data(contentsOf: bundled)
            try HookFile.writeScriptIfNeeded(bundledData, to: hookScriptURL, fileManager: fileManager)
        } catch {
            codexHookLogger.error("Failed to install Codex hook script: \(error.localizedDescription)")
            return false
        }

        let hooksWritten = updateHooksJSON(at: hooksJSONURL, command: hookCommand)
        let featureEnabled = updateConfig(at: configURL)
        return hooksWritten && featureEnabled
    }

    nonisolated static func uninstall() {
        try? FileManager.default.removeItem(at: hookScriptURL)

        let existingData = try? Data(contentsOf: hooksJSONURL)
        guard let data = removeManagedHooksJSON(from: existingData) else {
            if let existingData, !existingData.isEmpty,
               (try? JSONSerialization.jsonObject(with: existingData)) == nil {
                codexHookLogger.error("Skipped pruning Codex hooks.json on uninstall: file is not valid JSON; stale hook references may remain")
            }
            return
        }

        do {
            try data.write(to: hooksJSONURL)
        } catch {
            codexHookLogger.error("Failed to write Codex hooks.json on uninstall: \(error.localizedDescription)")
        }
    }

    nonisolated static func removeManagedHooksJSON(from existingData: Data?) -> Data? {
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

        return try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    nonisolated static func upsertHooksJSON(from existingData: Data?, command: String) -> Data? {
        var json: [String: Any] = [:]
        if let existingData,
           let existing = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
            json = existing
        }

        var hooks = json["hooks"] as? [String: Any] ?? [:]

        let desiredHookEvents: [String: [[String: Any]]] = [
            "SessionStart": [makeHookGroup(matcher: "startup|resume", command: command)],
            "UserPromptSubmit": [makeHookGroup(matcher: nil, command: command)],
            "Stop": [makeHookGroup(matcher: nil, command: command, timeout: 30)],
        ]

        for (event, desiredEntries) in desiredHookEvents {
            let existingEntries = hooks[event] as? [[String: Any]] ?? []
            hooks[event] = pruneManagedHooks(from: existingEntries) + desiredEntries
        }

        json["hooks"] = hooks

        return try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    nonisolated private static func pruneManagedHooks(from entries: [[String: Any]]) -> [[String: Any]] {
        entries.compactMap { entry in
            guard let entryHooks = entry["hooks"] as? [[String: Any]] else {
                return entry
            }

            let filteredHooks = entryHooks.filter { hook in
                let existingCommand = hook["command"] as? String ?? ""
                return !existingCommand.contains(hookScriptName)
            }

            guard !filteredHooks.isEmpty else {
                return nil
            }

            var updatedEntry = entry
            updatedEntry["hooks"] = filteredHooks
            return updatedEntry
        }
    }

    private nonisolated static let featureLine = "hooks = true"
    private nonisolated static let hooksKeyPattern = #"(?m)^[ \t]*hooks[ \t]*=[^\r\n]*"#
    private nonisolated static let legacyKeyPattern = #"(?m)^[ \t]*codex_hooks[ \t]*=[^\r\n]*"#
    private nonisolated static let legacyKeyLinePattern = #"(?m)^[ \t]*codex_hooks[ \t]*=[^\r\n]*\r?\n?"#
    private nonisolated static let featuresHeaderPattern = #"(?m)^\[features\][ \t]*(#[^\r\n]*)?\r?$"#
    private nonisolated static let enabledPattern = #"(?m)^[ \t]*hooks[ \t]*=[ \t]*true[ \t]*(#[^\r\n]*)?\r?$"#

    nonisolated static func upsertFeatureFlag(in existingContents: String?) -> String {
        var text = existingContents ?? ""

        guard let section = featuresSectionBodyRange(in: &text) else {
            if !text.isEmpty && !text.hasSuffix("\n") {
                text += "\n"
            }
            return text + "\n[features]\n\(featureLine)\n"
        }

        var body = String(text[section])
        if let range = body.range(of: hooksKeyPattern, options: .regularExpression) {
            body.replaceSubrange(range, with: featureLine)
            body = body.replacingOccurrences(of: legacyKeyLinePattern, with: "", options: .regularExpression)
        } else if let range = body.range(of: legacyKeyPattern, options: .regularExpression) {
            body.replaceSubrange(range, with: featureLine)
        } else {
            body = "\(featureLine)\n" + body
        }
        text.replaceSubrange(section, with: body)
        return text
    }

    private nonisolated static func featuresSectionBodyRange(in text: inout String) -> Range<String.Index>? {
        guard let header = text.range(of: featuresHeaderPattern, options: .regularExpression) else {
            return nil
        }
        guard let newlineIndex = text[header.upperBound...].utf8.firstIndex(of: UInt8(ascii: "\n")) else {
            text.insert("\n", at: header.upperBound)
            return featuresSectionBodyRange(in: &text)
        }
        let bodyStart = text.utf8.index(after: newlineIndex)
        let bodyEnd = text[bodyStart...].range(of: #"(?m)^[ \t]*\["#, options: .regularExpression)?.lowerBound
            ?? text.endIndex
        return bodyStart..<bodyEnd
    }

    nonisolated static func isHookInstalled(in hooksData: Data?) -> Bool {
        guard let hooksData,
              let json = try? JSONSerialization.jsonObject(with: hooksData) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }

        return hooks.values.contains { value in
            guard let entries = value as? [[String: Any]] else { return false }
            return entries.contains { entry in
                guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return false }
                return entryHooks.contains { hook in
                    (hook["command"] as? String)?.contains(hookScriptName) == true
                }
            }
        }
    }

    nonisolated static func isFeatureEnabled(in configContents: String?) -> Bool {
        guard var text = configContents, let section = featuresSectionBodyRange(in: &text) else { return false }
        return text[section].range(of: enabledPattern, options: .regularExpression) != nil
    }

    nonisolated static func isInstalled() -> Bool {
        let hooksData = try? Data(contentsOf: hooksJSONURL)
        let configContents = try? String(contentsOf: configURL, encoding: .utf8)
        return isHookInstalled(in: hooksData) && isFeatureEnabled(in: configContents)
    }

    nonisolated static func codexDirectoryExists(
        fileManager: FileManager = .default,
        directoryURL: URL = codexDirectoryURL
    ) -> Bool {
        fileManager.fileExists(atPath: directoryURL.path)
    }

    nonisolated private static func makeHookGroup(
        matcher: String?,
        command: String,
        timeout: Int? = nil
    ) -> [String: Any] {
        var hook: [String: Any] = [
            "type": "command",
            "command": command,
        ]
        if let timeout {
            hook["timeout"] = timeout
        }

        var group: [String: Any] = [
            "hooks": [hook]
        ]
        if let matcher, !matcher.isEmpty {
            group["matcher"] = matcher
        }

        return group
    }

    nonisolated private static func updateHooksJSON(at url: URL, command: String) -> Bool {
        let existingData = try? Data(contentsOf: url)

        guard let data = upsertHooksJSON(from: existingData, command: command) else {
            codexHookLogger.error("Failed to serialize Codex hooks.json")
            return false
        }

        guard data != existingData else { return true }

        do {
            try data.write(to: url)
            return true
        } catch {
            codexHookLogger.error("Failed to write Codex hooks.json: \(error.localizedDescription)")
            return false
        }
    }

    nonisolated private static func updateConfig(at url: URL) -> Bool {
        let existingContents = try? String(contentsOf: url, encoding: .utf8)
        let updatedContents = upsertFeatureFlag(in: existingContents)

        guard updatedContents != existingContents else { return true }

        do {
            try updatedContents.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            codexHookLogger.error("Failed to write Codex config.toml: \(error.localizedDescription)")
            return false
        }
    }
}
