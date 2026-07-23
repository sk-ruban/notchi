import XCTest
@testable import notchi

@MainActor
final class PendingQuestionTests: XCTestCase {
    private let koreanSentinel = "무언가 입력"

    func testRawEnglishLabelIsRecognizedWhenLocalizedSentinelDiffers() {
        XCTAssertTrue(PendingQuestion.isFreeTextOptionLabel("Type something", localizedLabel: koreanSentinel))
    }

    func testLocalizedSentinelLabelIsRecognized() {
        XCTAssertTrue(PendingQuestion.isFreeTextOptionLabel("무언가 입력. ", localizedLabel: koreanSentinel))
    }

    func testRegularOptionLabelIsNotRecognized() {
        XCTAssertFalse(PendingQuestion.isFreeTextOptionLabel("Fast", localizedLabel: koreanSentinel))
    }
}
