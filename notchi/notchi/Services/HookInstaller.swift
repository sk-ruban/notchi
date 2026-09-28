import Foundation
import os.log

nonisolated private let logger = Logger(subsystem: "com.ruban.notchi", category: "HookInstaller")

struct HookInstaller {
    nonisolated static let hookCommand = "\"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/notchi-hook.sh\""

    @discardableResult
    nonisolated static func installIfNeeded() -> Bool {
        let claudeConfig = ClaudeConfigDirectoryResolver.resolve()
        let claudeDir = claudeConfig.directoryURL

        guard claudeConfigDirectoryExists(resolution: claudeConfig) else {
            logger.warning("Claude Code not installed (config dir not found at \(claudeDir.path, privacy: .public))")
            return false
        }

        let hooksDir = claudeConfig.hooksDirectoryURL
        let hookScript = claudeConfig.hookScriptURL
        let settings = claudeConfig.settingsURL

        do {
            try FileManager.default.createDirectory(
                at: hooksDir,
                withIntermediateDirectories: true
            )
        } catch {
            logger.error("Failed to create hooks directory: \(error.localizedDescription)")
            return false
        }

        if let bundled = Bundle.main.url(forResource: "notchi-hook", withExtension: "sh") {
            do {
                let bundledData = try Data(contentsOf: bundled)
                try HookFile.writeScriptIfNeeded(HookFile.installableScript(from: bundledData), to: hookScript)
            } catch {
                logger.error("Failed to install hook script: \(error.localizedDescription)")
                return false
            }
        } else {
            logger.error("Hook script not found in bundle")
            return false
        }

        return updateSettings(
            at: settings,
            command: hookCommand
        )
    }

    nonisolated static func upsertHookSettings(from existingData: Data?, command: String) -> Data? {
        var json: [String: Any] = [:]
        if let existingData,
           let existing = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
            json = existing
        }

        let hookEntry: [[String: Any]] = [["type": "command", "command": command]]
        let withMatcher: [[String: Any]] = [["matcher": "*", "hooks": hookEntry]]
        let withoutMatcher: [[String: Any]] = [["hooks": hookEntry]]
        let preCompactConfig: [[String: Any]] = [
            ["matcher": "auto", "hooks": hookEntry],
            ["matcher": "manual", "hooks": hookEntry]
        ]

        var hooks = json["hooks"] as? [String: Any] ?? [:]

        let hookEvents: [(String, [[String: Any]])] = [
            ("UserPromptSubmit", withoutMatcher),
            ("SessionStart", withoutMatcher),
            ("PreToolUse", withMatcher),
            ("PostToolUse", withMatcher),
            ("PermissionRequest", withMatcher),
            ("PreCompact", preCompactConfig),
            ("Stop", withoutMatcher),
            ("SubagentStop", withoutMatcher),
            ("SessionEnd", withoutMatcher),
        ]

        for (event, config) in hookEvents {
            if var existingEvent = hooks[event] as? [[String: Any]] {
                var foundExistingHook = false

                for index in existingEvent.indices {
                    guard var entryHooks = existingEvent[index]["hooks"] as? [[String: Any]] else { continue }

                    var didUpdateEntry = false
                    for hookIndex in entryHooks.indices {
                        let cmd = entryHooks[hookIndex]["command"] as? String ?? ""
                        guard cmd.contains("notchi-hook.sh") else { continue }

                        foundExistingHook = true
                        didUpdateEntry = true

                        if cmd != command {
                            entryHooks[hookIndex]["command"] = command
                        }
                    }

                    if didUpdateEntry {
                        existingEvent[index]["hooks"] = entryHooks
                    }
                }

                if !foundExistingHook {
                    existingEvent.append(contentsOf: config)
                }

                hooks[event] = existingEvent
            } else {
                hooks[event] = config
            }
        }

        json["hooks"] = hooks

        return try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    nonisolated private static func updateSettings(at settingsURL: URL, command: String) -> Bool {
        let existingData = try? Data(contentsOf: settingsURL)

        guard let data = upsertHookSettings(from: existingData, command: command) else {
            logger.error("Failed to serialize settings JSON")
            return false
        }

        guard data != existingData else { return true }

        do {
            try data.write(to: settingsURL)
            return true
        } catch {
            logger.error("Failed to write settings.json: \(error.localizedDescription)")
            return false
        }
    }

    nonisolated static func isHookInstalled(in settingsData: Data?) -> Bool {
        guard let settingsData,
              let json = try? JSONSerialization.jsonObject(with: settingsData) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }

        return hooks.values.contains { value in
            guard let entries = value as? [[String: Any]] else { return false }
            return entries.contains { entry in
                guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return false }
                return entryHooks.contains { hook in
                    (hook["command"] as? String)?.contains("notchi-hook.sh") == true
                }
            }
        }
    }

    nonisolated static func isInstalled() -> Bool {
        let settings = ClaudeConfigDirectoryResolver.resolve().settingsURL

        return isHookInstalled(in: try? Data(contentsOf: settings))
    }

    nonisolated static func claudeConfigDirectoryExists(
        resolution: ClaudeConfigDirectoryResolution = ClaudeConfigDirectoryResolver.resolve(),
        fileManager: FileManager = .default
    ) -> Bool {
        fileManager.fileExists(atPath: resolution.directoryURL.path)
    }

    nonisolated static func uninstall() {
        let claudeConfig = ClaudeConfigDirectoryResolver.resolve()
        let hookScript = claudeConfig.hookScriptURL
        let settings = claudeConfig.settingsURL

        try? FileManager.default.removeItem(at: hookScript)

        let existingData = try? Data(contentsOf: settings)
        guard let data = removeManagedHookSettings(from: existingData) else {
            if let existingData, !existingData.isEmpty,
               (try? JSONSerialization.jsonObject(with: existingData)) == nil {
                logger.error("Skipped pruning Claude settings.json on uninstall: file is not valid JSON; stale hook references may remain")
            }
            return
        }

        try? data.write(to: settings)
    }

    // WHY: Prune only Notchi-managed hook commands instead of dropping the whole
    // matcher entry, so an unrelated hook a user added to the same event entry
    // survives toggling Notchi off. Mirrors CodexHookInstaller's prune behavior.
    nonisolated static func removeManagedHookSettings(from existingData: Data?) -> Data? {
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

    nonisolated private static func pruneManagedHooks(from entries: [[String: Any]]) -> [[String: Any]] {
        entries.compactMap { entry in
            guard let entryHooks = entry["hooks"] as? [[String: Any]] else {
                return entry
            }

            let filteredHooks = entryHooks.filter { hook in
                let command = hook["command"] as? String ?? ""
                return !command.contains("notchi-hook.sh")
            }

            guard !filteredHooks.isEmpty else {
                return nil
            }

            var updatedEntry = entry
            updatedEntry["hooks"] = filteredHooks
            return updatedEntry
        }
    }
}
