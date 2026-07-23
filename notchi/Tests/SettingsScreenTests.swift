import XCTest
@testable import notchi

final class SettingsScreenTests: XCTestCase {
    func testBackActionPopsWhenSubScreenIsPushed() {
        XCTAssertEqual(SettingsScreen.backAction(for: [.general]), .popScreen)
        XCTAssertEqual(SettingsScreen.backAction(for: [.emotionAnalysis]), .popScreen)
    }

    func testBackActionExitsSettingsWhenOnMainPage() {
        XCTAssertEqual(SettingsScreen.backAction(for: []), .exitSettings)
    }
}
