import Foundation
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "HookInstaller")

struct HookInstaller {
    static let hookCommand = "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/notchi-hook.sh"

    @discardableResult
    static func installIfNeeded() -> Bool {
        let claudeConfig = ClaudeConfigDirectoryResolver.resolve()
        let claudeDir = claudeConfig.directoryURL

        guard FileManager.default.fileExists(atPath: claudeDir.path) else {
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
                try bundledData.write(to: hookScript, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: hookScript.path
                )
                logger.info("Installed hook script to \(hookScript.path, privacy: .public)")
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

    static func upsertHookSettings(from existingData: Data?, command: String) -> Data? {
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

    private static func updateSettings(at settingsURL: URL, command: String) -> Bool {
        let existingData = try? Data(contentsOf: settingsURL)

        guard let data = upsertHookSettings(from: existingData, command: command) else {
            logger.error("Failed to serialize settings JSON")
            return false
        }

        do {
            try data.write(to: settingsURL)
            logger.info("Updated settings.json with Notchi hooks")
            return true
        } catch {
            logger.error("Failed to write settings.json: \(error.localizedDescription)")
            return false
        }
    }

    static func isHookInstalled(in settingsData: Data?) -> Bool {
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

    static func isInstalled() -> Bool {
        let settings = ClaudeConfigDirectoryResolver.resolve().settingsURL

        return isHookInstalled(in: try? Data(contentsOf: settings))
    }

    static func uninstall() {
        let claudeConfig = ClaudeConfigDirectoryResolver.resolve()
        let hookScript = claudeConfig.hookScriptURL
        let settings = claudeConfig.settingsURL

        try? FileManager.default.removeItem(at: hookScript)

        guard let data = try? Data(contentsOf: settings),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = json["hooks"] as? [String: Any] else {
            return
        }

        for (event, value) in hooks {
            if var entries = value as? [[String: Any]] {
                entries.removeAll { entry in
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        return entryHooks.contains { hook in
                            let cmd = hook["command"] as? String ?? ""
                            return cmd.contains("notchi-hook.sh")
                        }
                    }
                    return false
                }

                if entries.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = entries
                }
            }
        }

        if hooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = hooks
        }

        if let data = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: settings)
        }

        logger.info("Uninstalled Notchi hooks")
    }
}
