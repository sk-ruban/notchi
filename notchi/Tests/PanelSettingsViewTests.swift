import XCTest
@testable import notchi

final class PanelSettingsViewTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ClaudeConfigDirectoryResolver.resetTestingHooks()
    }

    override func tearDown() {
        ClaudeConfigDirectoryResolver.resetTestingHooks()
        super.tearDown()
    }

    func testPanelSettingsViewExposesResolvedClaudeConfigPathAndSource() {
        ClaudeConfigDirectoryResolver.testHooks = .init(
            environment: { ["CLAUDE_CONFIG_DIR": "/tmp/custom-claude"] },
            isExecutableFile: { _ in false },
            runProcess: { _, _, _ in nil }
        )

        let view = PanelSettingsView()

        XCTAssertEqual(view.claudeConfigDisplayPath, "/tmp/custom-claude")
        XCTAssertEqual(view.claudeConfigSourceLabel, "env")
    }
}
