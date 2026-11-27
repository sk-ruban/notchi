import Foundation
import os.log

nonisolated private let codexHookLogger = Logger(subsystem: "com.ruban.notchi", category: "CodexHookInstaller")

struct CodexHookInstaller {
    nonisolated private static let hookScriptName = "notchi-codex-hook.sh"
    nonisolated private static let hooksJSONWritingOptions: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]

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

        guard HookFile.installBundledScript(
            named: "notchi-codex-hook",
            to: hookScriptURL,
            agentName: "Codex",
            logger: codexHookLogger
        ) else { return false }

        return updateHookConfigs(hooksJSONAt: hooksJSONURL, configAt: configURL, command: hookCommand)
    }

    nonisolated static func updateHookConfigs(hooksJSONAt hooksURL: URL, configAt configURL: URL, command: String) -> Bool {
        // Enabling hooks while hooks.json is unreadable would have Codex load the broken file.
        guard updateHooksJSON(at: hooksURL, command: command) else { return false }
        return updateConfig(at: configURL)
    }

    nonisolated static func uninstall() {
        try? FileManager.default.removeItem(at: hookScriptURL)

        HookConfigJSON.pruneManagedHooks(
            inConfigAt: hooksJSONURL,
            fileDescription: "Codex hooks.json",
            isManaged: isManagedCommand,
            options: hooksJSONWritingOptions,
            logger: codexHookLogger
        )
    }

    nonisolated static func removeManagedHooksJSON(from existingData: Data?) -> Data? {
        HookConfigJSON.removeManagedHooks(from: existingData, isManaged: isManagedCommand, options: hooksJSONWritingOptions)
    }

    nonisolated static func upsertHooksJSON(from existingData: Data?, command: String) -> Data? {
        guard var json = HookConfigJSON.editableObject(from: existingData) else { return nil }

        var hooks = json["hooks"] as? [String: Any] ?? [:]

        let desiredHookEvents: [String: [[String: Any]]] = [
            "SessionStart": [makeHookGroup(matcher: "startup|resume", command: command)],
            "UserPromptSubmit": [makeHookGroup(matcher: nil, command: command)],
            "Stop": [makeHookGroup(matcher: nil, command: command, timeout: 30)],
        ]

        for (event, desiredEntries) in desiredHookEvents {
            let existingEntries = hooks[event] as? [[String: Any]] ?? []
            hooks[event] = HookConfigJSON.pruneManagedHooks(from: existingEntries, isManaged: isManagedCommand) + desiredEntries
        }

        json["hooks"] = hooks

        return HookConfigJSON.serialize(json, options: hooksJSONWritingOptions)
    }

    nonisolated private static func isManagedCommand(_ command: String) -> Bool {
        command.contains(hookScriptName)
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
        HookConfigJSON.containsManagedHook(in: hooksData, isManaged: isManagedCommand)
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

    nonisolated static func updateHooksJSON(at url: URL, command: String) -> Bool {
        let existingData = try? Data(contentsOf: url)

        guard let data = upsertHooksJSON(from: existingData, command: command) else {
            codexHookLogger.error("Skipped updating Codex hooks.json: existing file is not valid JSON")
            return false
        }

        guard data != existingData else { return true }

        do {
            try HookFile.writeConfig(data, to: url)
            return true
        } catch {
            codexHookLogger.error("Failed to write Codex hooks.json: \(error.localizedDescription)")
            return false
        }
    }

    nonisolated static func updateConfig(at url: URL) -> Bool {
        let existingContents = try? String(contentsOf: url, encoding: .utf8)
        let updatedContents = upsertFeatureFlag(in: existingContents)

        guard updatedContents != existingContents else { return true }

        do {
            try HookFile.writeConfig(Data(updatedContents.utf8), to: url)
            return true
        } catch {
            codexHookLogger.error("Failed to write Codex config.toml: \(error.localizedDescription)")
            return false
        }
    }
}
