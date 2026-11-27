import XCTest
@testable import notchi

final class EmotionAnalysisSettingsViewTests: XCTestCase {
    private static let storedKey = "sk-ant-stored"

    func testEmptyFieldThatLoadedEmptyIsNotAnEdit() {
        // A locked Keychain loads an empty field; leaving it must not delete the stored key.
        XCTAssertFalse(EmotionAnalysisSettingsView.isApiKeyEdited(input: "", loaded: ""))
    }

    func testClearingALoadedKeyIsAnEdit() {
        XCTAssertTrue(EmotionAnalysisSettingsView.isApiKeyEdited(input: "", loaded: Self.storedKey))
    }

    func testTypingAKeyIntoAnEmptyFieldIsAnEdit() {
        XCTAssertTrue(EmotionAnalysisSettingsView.isApiKeyEdited(input: Self.storedKey, loaded: ""))
    }

    func testOnlyAddingSurroundingWhitespaceIsNotAnEdit() {
        XCTAssertFalse(EmotionAnalysisSettingsView.isApiKeyEdited(input: " \(Self.storedKey)\n", loaded: Self.storedKey))
    }
}
