import Foundation
import os.log

/// The `hooks` object the Claude, Codex and Devin configs share:
/// `{"hooks": {"<event>": [{"matcher": …, "hooks": [{"type": "command", "command": …}]}]}}`.
/// `isManaged` tells whether a hook command is notchi's.
nonisolated enum HookConfigJSON {
    /// The config to edit: empty for a missing or blank file, nil when it isn't a JSON object.
    static func editableObject(from existingData: Data?) -> [String: Any]? {
        guard let existingData, !HookFile.isBlank(existingData) else { return [:] }
        return try? JSONSerialization.jsonObject(with: existingData) as? [String: Any]
    }

    static func serialize(_ json: [String: Any], options: JSONSerialization.WritingOptions) -> Data? {
        try? JSONSerialization.data(withJSONObject: json, options: options)
    }

    static func containsManagedHook(in data: Data?, isManaged: (String) -> Bool) -> Bool {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }

        return hooks.values.contains { value in
            guard let entries = value as? [[String: Any]] else { return false }
            return entries.contains { entry in
                guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return false }
                return entryHooks.contains { hook in
                    (hook["command"] as? String).map(isManaged) == true
                }
            }
        }
    }

    // WHY: Prune only notchi's hook commands instead of dropping the whole
    // matcher entry, so an unrelated hook a user added to the same entry
    // survives toggling notchi off.
    static func pruneManagedHooks(from entries: [[String: Any]], isManaged: (String) -> Bool) -> [[String: Any]] {
        entries.compactMap { entry in
            guard let entryHooks = entry["hooks"] as? [[String: Any]] else {
                return entry
            }

            let filteredHooks = entryHooks.filter { hook in
                !isManaged(hook["command"] as? String ?? "")
            }

            guard !filteredHooks.isEmpty else {
                return nil
            }

            var updatedEntry = entry
            updatedEntry["hooks"] = filteredHooks
            return updatedEntry
        }
    }

    /// Nil when the config isn't a JSON object with a `hooks` object.
    static func removeManagedHooks(
        from existingData: Data?,
        isManaged: (String) -> Bool,
        options: JSONSerialization.WritingOptions
    ) -> Data? {
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

            let prunedEntries = pruneManagedHooks(from: entries, isManaged: isManaged)
            if !prunedEntries.isEmpty {
                updatedHooks[event] = prunedEntries
            }
        }

        if updatedHooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = updatedHooks
        }

        return serialize(json, options: options)
    }

    /// Uninstall: removes notchi's hooks from the config at `url`, leaving a file that isn't valid JSON as it is.
    static func pruneManagedHooks(
        inConfigAt url: URL,
        fileDescription: String,
        isManaged: (String) -> Bool,
        options: JSONSerialization.WritingOptions,
        logger: Logger
    ) {
        let existingData = try? Data(contentsOf: url)
        guard let data = removeManagedHooks(from: existingData, isManaged: isManaged, options: options) else {
            if let existingData, !HookFile.isBlank(existingData),
               (try? JSONSerialization.jsonObject(with: existingData)) == nil {
                logger.error("Skipped pruning \(fileDescription, privacy: .public) on uninstall: file is not valid JSON; stale hook references may remain")
            }
            return
        }

        do {
            try HookFile.writeConfig(data, to: url)
        } catch {
            logger.error("Failed to write \(fileDescription, privacy: .public) on uninstall: \(error.localizedDescription)")
        }
    }
}
