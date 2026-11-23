import Foundation
import XCTest
@testable import notchi

final class ClaudeAccountSettingsViewTests: XCTestCase {
    func testDisplayPathAbbreviatesHomePrefixWithTilde() {
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude-work")

        XCTAssertEqual(ClaudeAccountSettingsView.displayPath(for: directory), "~/.claude-work")
    }

    func testDisplayPathLeavesHomeNameInsideAnotherPathUnchanged() {
        // A backup volume that mirrors the home folder contains the home path, but not as a prefix.
        let mirroredPath = "/Volumes/Backup" + NSHomeDirectory() + "/.claude"

        XCTAssertEqual(ClaudeAccountSettingsView.displayPath(for: URL(fileURLWithPath: mirroredPath)), mirroredPath)
    }
}
