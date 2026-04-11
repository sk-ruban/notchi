import XCTest
@testable import notchi

final class AppSettingsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "isEmotionAnalysisEnabled")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "isEmotionAnalysisEnabled")
        super.tearDown()
    }

    func testEmotionAnalysisDefaultsToEnabled() {
        XCTAssertTrue(AppSettings.isEmotionAnalysisEnabled)
    }

    func testEmotionAnalysisPersistsDisabledState() {
        AppSettings.isEmotionAnalysisEnabled = false

        XCTAssertFalse(AppSettings.isEmotionAnalysisEnabled)
    }
}
