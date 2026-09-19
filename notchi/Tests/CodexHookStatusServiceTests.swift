import Foundation
import XCTest
@testable import notchi

final class CodexHookStatusServiceTests: XCTestCase {
    private let command = "/Users/test/.codex/hooks/notchi-codex-hook.sh"

    func testInstalledAndEnabledHooksStillRequireTrust() throws {
        let response = try response(trust: ["untrusted", "untrusted", "untrusted"])
        XCTAssertEqual(CodexHookStatusService.readiness(from: response, command: command), .needsApproval)
    }

    func testEveryHookMustBeApproved() throws {
        for index in 0..<3 {
            var trust = ["trusted", "trusted", "trusted"]
            trust[index] = "untrusted"
            XCTAssertEqual(CodexHookStatusService.readiness(from: try response(trust: trust), command: command), .needsApproval)
        }
    }

    func testModifiedDefinitionNeedsApprovalAgain() throws {
        XCTAssertEqual(
            CodexHookStatusService.readiness(from: try response(trust: ["trusted", "modified", "trusted"]), command: command),
            .needsApproval
        )
    }

    func testTrustedAndManagedHooksAreApproved() throws {
        XCTAssertEqual(
            CodexHookStatusService.readiness(from: try response(trust: ["trusted", "managed", "trusted"]), command: command),
            .approved
        )
    }

    func testDisabledHookIsNotApproved() throws {
        XCTAssertEqual(CodexHookStatusService.readiness(from: try response(enabled: false), command: command), .disabled)
    }

    func testMissingHookIsNotApproved() throws {
        XCTAssertEqual(CodexHookStatusService.readiness(from: try response(count: 2), command: command), .notRegistered)
    }

    func testUnrelatedCommandWithSameFilenameDoesNotCount() throws {
        XCTAssertEqual(
            CodexHookStatusService.readiness(from: try response(), command: "/another/notchi-codex-hook.sh"),
            .notRegistered
        )
    }

    func testUnknownTrustAndUnsupportedProtocolRemainUnverified() throws {
        XCTAssertEqual(
            CodexHookStatusService.readiness(from: try response(trust: ["trusted", "newStatus", "trusted"]), command: command),
            .unverified
        )
        for json in ["not JSON", "{}", #"{"id":2,"error":{"code":-32601,"message":"Unknown method"}}"#] {
            XCTAssertEqual(CodexHookStatusService.readiness(from: Data(json.utf8), command: command), .unverified)
        }
    }

    func testConfigurationWarningsAndErrorsAreNotReportedAsApproved() throws {
        XCTAssertEqual(CodexHookStatusService.readiness(from: try response(warnings: ["policy restriction"]), command: command), .unverified)
        XCTAssertEqual(CodexHookStatusService.readiness(from: try response(errors: [["message": "invalid configuration"]]), command: command), .unverified)
    }

    func testDesktopExecutableIsPreferredWithoutPATH() {
        let home = URL(fileURLWithPath: "/Users/test")
        let candidates = CodexHookStatusService.executableCandidates(home: home, path: "")
        let available: Set<String> = ["/Applications/ChatGPT.app/Contents/Resources/codex", "/opt/homebrew/bin/codex"]
        XCTAssertEqual(
            CodexHookStatusService.resolveExecutable(candidates: candidates, isExecutable: available.contains)?.path,
            "/Applications/ChatGPT.app/Contents/Resources/codex"
        )
        XCTAssertNil(CodexHookStatusService.resolveExecutable(candidates: candidates, isExecutable: { _ in false }))
    }

    func testMovedApplicationAndCLIOnlyInstallationsAreFound() {
        let moved = URL(fileURLWithPath: "/Volumes/Apps/Codex.app")
        let candidates = CodexHookStatusService.executableCandidates(applicationURLs: [moved], path: "/custom/bin:relative/bin")
        XCTAssertEqual(candidates.first, moved.appendingPathComponent("Contents/Resources/codex"))
        XCTAssertEqual(
            CodexHookStatusService.resolveExecutable(candidates: candidates, isExecutable: { $0 == "/custom/bin/codex" })?.path,
            "/custom/bin/codex"
        )
        XCTAssertFalse(candidates.contains { $0.path.contains("relative/bin") })
    }

    func testLaunchCommandQuotesPathsAndDoesNotBypassTrust() {
        let executable = URL(fileURLWithPath: "/Users/Pat's Apps/$(touch nope)/codex")
        let setup = CodexHookSetup(executableURL: executable, readiness: .needsApproval)
        XCTAssertEqual(setup.launchCommand, "'/Users/Pat'\\''s Apps/$(touch nope)/codex'")
        let script = CodexHookStatusService.launcherContents(executable: executable, home: URL(fileURLWithPath: "/Users/Pat Test"))
        XCTAssertTrue(script.contains("cd '/Users/Pat Test' || exit 1"))
        XCTAssertTrue(script.contains("exec '/Users/Pat'\\''s Apps/$(touch nope)/codex'"))
        XCTAssertFalse(script.contains("bypass"))
    }

    func testStatusQueryCompletesHandshakeWithoutStartingAThread() throws {
        let executable = try fixture("""
        import json, sys
        initialize = json.loads(sys.stdin.readline())
        assert initialize['method'] == 'initialize'
        print(json.dumps({'id': initialize['id'], 'result': {}}), flush=True)
        assert json.loads(sys.stdin.readline())['method'] == 'initialized'
        query = json.loads(sys.stdin.readline())
        assert query['method'] == 'hooks/list'
        print(json.dumps({'method': 'unrelated/notification'}), flush=True)
        print(json.dumps({'id': query['id'], 'result': {'data': []}}), flush=True)
        sys.stdin.read()
        """)
        let data = try XCTUnwrap(CodexHookStatusService.queryHooks(executable: executable, timeout: 2))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["id"] as? Int, 2)
        XCTAssertNotNil(object["result"])
    }

    func testHungStatusQueryHasBoundedTimeout() throws {
        let executable = try fixture("import time\ntime.sleep(30)")
        let started = Date()
        XCTAssertNil(CodexHookStatusService.queryHooks(executable: executable, timeout: 0.1))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testFailedInitializationReturnsNoApproval() throws {
        let executable = try fixture("""
        import json, sys
        sys.stdin.readline()
        print(json.dumps({'id': 1, 'error': {'message': 'unsupported'}}), flush=True)
        """)
        XCTAssertNil(CodexHookStatusService.queryHooks(executable: executable, timeout: 2))
    }

    func testRuntimeExitingBeforeReadingInputDoesNotCrashTheApp() throws {
        let executable = try fixture("import sys\nsys.exit(1)")
        XCTAssertNil(CodexHookStatusService.queryHooks(executable: executable, timeout: 2))
    }

    private func fixture(_ source: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("codex")
        try ("#!/usr/bin/python3\n" + source + "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    private func response(
        trust: [String] = ["trusted", "trusted", "trusted"],
        enabled: Bool = true,
        count: Int = 3,
        warnings: [String] = [],
        errors: [[String: String]] = []
    ) throws -> Data {
        let events = ["sessionStart", "userPromptSubmit", "stop"]
        let hooks: [[String: Any]] = (0..<count).map {
            ["eventName": events[$0], "command": command, "enabled": enabled, "trustStatus": trust[$0]]
        }
        return try JSONSerialization.data(withJSONObject: [
            "id": 2,
            "result": ["data": [["hooks": hooks, "warnings": warnings, "errors": errors]]],
        ])
    }
}
