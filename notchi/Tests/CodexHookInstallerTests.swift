import Foundation
import XCTest
@testable import notchi

final class CodexHookInstallerTests: XCTestCase {
    func testCodexDirectoryExistsReturnsFalseWhenConfigDirectoryIsMissing() {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        XCTAssertFalse(CodexHookInstaller.codexDirectoryExists(directoryURL: tempRoot))
    }

    func testCodexDirectoryExistsReturnsTrueWhenConfigDirectoryExists() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        XCTAssertTrue(CodexHookInstaller.codexDirectoryExists(directoryURL: tempRoot))
    }

    func testUpsertHooksJSONAddsConfiguredHookCommand() throws {
        let data = CodexHookInstaller.upsertHooksJSON(from: nil, command: "/tmp/notchi-codex-hook.sh")

        XCTAssertTrue(CodexHookInstaller.isHookInstalled(in: data))

        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["SessionStart"])
        XCTAssertNotNil(hooks["UserPromptSubmit"])
        XCTAssertNotNil(hooks["Stop"])
        XCTAssertNil(hooks["PreToolUse"])
        XCTAssertNil(hooks["PostToolUse"])
        let sessionStart = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        let hookEntries = try XCTUnwrap(sessionStart.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(hookEntries.first?["command"] as? String, "/tmp/notchi-codex-hook.sh")
    }

    func testUpsertHooksJSONPreservesExistingEntriesAndAvoidsDuplicates() throws {
        let existing = try JSONSerialization.data(withJSONObject: [
            "hooks": [
                "Stop": [
                    [
                        "hooks": [
                            ["type": "command", "command": "/tmp/notchi-codex-hook.sh"],
                        ],
                    ],
                    [
                        "hooks": [
                            ["type": "command", "command": "echo other"],
                        ],
                    ],
                ],
            ],
        ])

        let updated = try XCTUnwrap(CodexHookInstaller.upsertHooksJSON(from: existing, command: "/tmp/notchi-codex-hook.sh"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: updated) as? [String: Any])
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        let stopHooks = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])

        XCTAssertEqual(stopHooks.count, 2)
        XCTAssertTrue(CodexHookInstaller.isHookInstalled(in: updated))
    }

    func testUpsertFeatureFlagEnablesCodexHooksInExistingFeaturesSection() {
        let updated = CodexHookInstaller.upsertFeatureFlag(in: """
        model = "gpt-5.4"

        [features]
        some_other_flag = true
        """)

        XCTAssertTrue(CodexHookInstaller.isFeatureEnabled(in: updated))
        XCTAssertTrue(updated.contains("some_other_flag = true"))
    }

    func testUpsertFeatureFlagAppendsFeaturesSectionWhenMissing() {
        let updated = CodexHookInstaller.upsertFeatureFlag(in: """
        model = "gpt-5.4"
        """)

        XCTAssertTrue(updated.contains("[features]"))
        XCTAssertTrue(updated.contains("hooks = true"))
        XCTAssertFalse(updated.contains("codex_hooks"))
    }

    func testUpsertFeatureFlagMigratesLegacyCodexHooksKeyInPlace() {
        let updated = CodexHookInstaller.upsertFeatureFlag(in: """
        model = "gpt-5.4"

        [features]
        codex_hooks = true
        js_repl = false
        """)

        XCTAssertEqual(updated, """
        model = "gpt-5.4"

        [features]
        hooks = true
        js_repl = false
        """)
    }

    func testUpsertFeatureFlagDropsLegacyKeyWhenNewKeyAlreadyPresent() {
        let updated = CodexHookInstaller.upsertFeatureFlag(in: """
        [features]
        hooks = false
        codex_hooks = true
        """)

        XCTAssertEqual(updated, """
        [features]
        hooks = true

        """)
    }

    func testUpsertFeatureFlagLeavesTopLevelInlineHooksTableAlone() {
        let updated = CodexHookInstaller.upsertFeatureFlag(in: """
        hooks = { state = { "/Users/me/.codex/hooks.json:stop:0:0" = { disabled = true } } }

        [features]
        codex_hooks = true
        """)

        XCTAssertEqual(updated, """
        hooks = { state = { "/Users/me/.codex/hooks.json:stop:0:0" = { disabled = true } } }

        [features]
        hooks = true
        """)
    }

    func testUpsertFeatureFlagDoesNotTouchHooksKeysInOtherSections() {
        let updated = CodexHookInstaller.upsertFeatureFlag(in: """
        [features]
        js_repl = false

        [plugins.demo]
        hooks = false
        """)

        XCTAssertEqual(updated, """
        [features]
        hooks = true
        js_repl = false

        [plugins.demo]
        hooks = false
        """)
    }

    func testUpsertFeatureFlagHandlesFeaturesHeaderAtEndOfFile() {
        let updated = CodexHookInstaller.upsertFeatureFlag(in: "model = \"gpt-5.4\"\n[features]")

        XCTAssertEqual(updated, "model = \"gpt-5.4\"\n[features]\nhooks = true\n")
    }

    func testIsFeatureEnabledOnlyConsidersFeaturesSection() {
        XCTAssertFalse(CodexHookInstaller.isFeatureEnabled(in: "hooks = true\n\n[features]\njs_repl = false\n"))
        XCTAssertTrue(CodexHookInstaller.isFeatureEnabled(in: "[features]\nhooks = true\n\n[plugins.demo]\nhooks = false\n"))
        XCTAssertFalse(CodexHookInstaller.isFeatureEnabled(in: "[plugins.demo]\nhooks = true\n"))
    }

    func testUpsertFeatureFlagMigratesCRLFConfigWithoutDuplicatingFeaturesTable() {
        let updated = CodexHookInstaller.upsertFeatureFlag(in: "model = \"gpt-5.4\"\r\n\r\n[features]\r\ncodex_hooks = true\r\njs_repl = false\r\n")

        XCTAssertEqual(updated, "model = \"gpt-5.4\"\r\n\r\n[features]\r\nhooks = true\r\njs_repl = false\r\n")
        XCTAssertEqual(updated.components(separatedBy: "[features]").count - 1, 1)
        XCTAssertTrue(CodexHookInstaller.isFeatureEnabled(in: updated))
    }

    func testUpsertFeatureFlagRecognisesFeaturesHeaderWithTrailingComment() {
        let updated = CodexHookInstaller.upsertFeatureFlag(in: """
        [features] # managed by notchi
        js_repl = false
        """)

        XCTAssertEqual(updated, """
        [features] # managed by notchi
        hooks = true
        js_repl = false
        """)
        XCTAssertTrue(CodexHookInstaller.isFeatureEnabled(in: updated))
    }

    func testIsFeatureEnabledAcceptsTrailingCommentAndCRLF() {
        XCTAssertTrue(CodexHookInstaller.isFeatureEnabled(in: "[features]\nhooks = true # keep\n"))
        XCTAssertTrue(CodexHookInstaller.isFeatureEnabled(in: "[features]\r\nhooks = true\r\n"))
        XCTAssertFalse(CodexHookInstaller.isFeatureEnabled(in: "[features]\nhooks = truely\n"))
    }

    func testIsFeatureEnabledIgnoresLegacyKey() {
        XCTAssertFalse(CodexHookInstaller.isFeatureEnabled(in: "[features]\ncodex_hooks = true\n"))
        XCTAssertTrue(CodexHookInstaller.isFeatureEnabled(in: "[features]\nhooks = true\n"))
        XCTAssertFalse(CodexHookInstaller.isFeatureEnabled(in: "[features]\nhooks = false\n"))
    }

    func testUpsertHooksJSONIsIdempotentSoReinstallSkipsRewrite() throws {
        let command = "/tmp/notchi-codex-hook.sh"
        let first = try XCTUnwrap(CodexHookInstaller.upsertHooksJSON(from: nil, command: command))
        let second = try XCTUnwrap(CodexHookInstaller.upsertHooksJSON(from: first, command: command))

        XCTAssertEqual(first, second)
    }

    func testUpsertFeatureFlagIsIdempotentSoReinstallSkipsRewrite() {
        let first = CodexHookInstaller.upsertFeatureFlag(in: nil)
        let second = CodexHookInstaller.upsertFeatureFlag(in: first)

        XCTAssertEqual(first, second)
    }

    func testRemoveManagedHooksJSONKeepsSiblingHookInSameEntry() throws {
        let existing = try JSONSerialization.data(withJSONObject: [
            "hooks": [
                "SessionStart": [
                    [
                        "hooks": [
                            ["type": "command", "command": "/tmp/notchi-codex-hook.sh"],
                            ["type": "command", "command": "echo other"],
                        ],
                    ],
                ],
            ],
        ])

        let updated = try XCTUnwrap(CodexHookInstaller.removeManagedHooksJSON(from: existing))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: updated) as? [String: Any])
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        let sessionStart = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        let entryHooks = try XCTUnwrap(sessionStart.first?["hooks"] as? [[String: Any]])

        XCTAssertEqual(sessionStart.count, 1)
        XCTAssertEqual(entryHooks.count, 1)
        XCTAssertEqual(entryHooks.first?["command"] as? String, "echo other")
        XCTAssertFalse(CodexHookInstaller.isHookInstalled(in: updated))
    }

    func testRemoveManagedHooksJSONDropsHooksKeyWhenOnlyNotchiHooksExist() throws {
        let existing = try XCTUnwrap(CodexHookInstaller.upsertHooksJSON(from: nil, command: "/tmp/notchi-codex-hook.sh"))

        let updated = try XCTUnwrap(CodexHookInstaller.removeManagedHooksJSON(from: existing))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: updated) as? [String: Any])

        XCTAssertNil(json["hooks"])
        XCTAssertFalse(CodexHookInstaller.isHookInstalled(in: updated))
    }

    func testRemoveManagedHooksJSONReturnsNilWhenNoHooksPresent() throws {
        let existing = try JSONSerialization.data(withJSONObject: ["someOtherKey": "value"])

        XCTAssertNil(CodexHookInstaller.removeManagedHooksJSON(from: existing))
    }
}
