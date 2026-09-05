import Carbon.HIToolbox
import XCTest
@testable import notchi

@MainActor
final class AppSettingsDictationTests: XCTestCase {
    private let keys = [
        "dictationEnabled", "dictationPushToTalkShortcut",
        "dictationModelId", "dictationLanguage",
    ]

    override func setUp() {
        super.setUp()
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    func testDefaultsMatchSpec() {
        XCTAssertFalse(AppSettings.dictationEnabled)
        XCTAssertEqual(AppSettings.dictationModelId, "base.en")
        XCTAssertEqual(AppSettings.dictationLanguage, "en")
        XCTAssertEqual(
            AppSettings.dictationPushToTalkShortcut,
            GlobalShortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(cmdKey | optionKey | shiftKey))
        )
    }

    func testRoundTrips() {
        AppSettings.dictationEnabled = true
        AppSettings.dictationModelId = "small"
        AppSettings.dictationLanguage = "auto"
        let shortcut = GlobalShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey))
        AppSettings.dictationPushToTalkShortcut = shortcut

        XCTAssertTrue(AppSettings.dictationEnabled)
        XCTAssertEqual(AppSettings.dictationModelId, "small")
        XCTAssertEqual(AppSettings.dictationLanguage, "auto")
        XCTAssertEqual(AppSettings.dictationPushToTalkShortcut, shortcut)
    }
}
