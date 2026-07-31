import XCTest
@testable import notchi

final class DictationPresentationTests: XCTestCase {
    func testCTAMapsErrorsToActions() {
        XCTAssertEqual(DictationPresentation.cta(for: .error(.microphoneDenied)), .grantMicrophone)
        XCTAssertEqual(DictationPresentation.cta(for: .error(.accessibilityDenied)), .grantAccessibility)
        XCTAssertEqual(DictationPresentation.cta(for: .error(.modelMissing)), .downloadModel)
        XCTAssertEqual(DictationPresentation.cta(for: .error(.noActiveSession)), .noSession)
        XCTAssertEqual(DictationPresentation.cta(for: .error(.sessionNotInjectable)), .sessionNotInjectable)
        XCTAssertEqual(DictationPresentation.cta(for: .error(.transcriptionFailed)), .retry)
        XCTAssertEqual(DictationPresentation.cta(for: .review("hi")), .none)
    }

    func testOnlyReviewPhaseIsEditable() {
        XCTAssertTrue(DictationPresentation.isEditable(.review("x")))
        XCTAssertFalse(DictationPresentation.isEditable(.recording))
        XCTAssertFalse(DictationPresentation.isEditable(.transcribing))
    }

    func testEditorStaysVisibleDuringReDictationButNotFreshDictation() {
        // Re-dictation: text already present → editor stays mounted through busy phases.
        XCTAssertTrue(DictationPresentation.showsEditor(.recording, hasText: true))
        XCTAssertTrue(DictationPresentation.showsEditor(.transcribing, hasText: true))
        XCTAssertTrue(DictationPresentation.showsEditor(.review("x"), hasText: true))
        // Fresh dictation: no text yet → editor hidden until review.
        XCTAssertFalse(DictationPresentation.showsEditor(.recording, hasText: false))
        XCTAssertFalse(DictationPresentation.showsEditor(.transcribing, hasText: false))
        XCTAssertTrue(DictationPresentation.showsEditor(.review(""), hasText: false))
        XCTAssertFalse(DictationPresentation.showsEditor(.idle, hasText: true))
    }

    func testIsBusyCoversRecordingAndTranscribing() {
        XCTAssertTrue(DictationPresentation.isBusy(.recording))
        XCTAssertTrue(DictationPresentation.isBusy(.transcribing))
        XCTAssertFalse(DictationPresentation.isBusy(.review("x")))
        XCTAssertFalse(DictationPresentation.isBusy(.idle))
        XCTAssertFalse(DictationPresentation.isBusy(.sending))
    }

    func testStatusTextIsNonEmptyForEachPhase() {
        let phases: [DictationPhase] = [.idle, .recording, .transcribing, .review("x"), .sending, .error(.modelMissing)]
        for phase in phases {
            XCTAssertFalse(DictationPresentation.statusText(for: phase).isEmpty)
        }
    }
}
