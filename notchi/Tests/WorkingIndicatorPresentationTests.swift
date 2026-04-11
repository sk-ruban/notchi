import XCTest
@testable import notchi

final class WorkingIndicatorPresentationTests: XCTestCase {
    func testWaitingStateUsesStaticSymbolAndAnimatedDots() {
        XCTAssertEqual(
            WorkingIndicatorPresentation.symbol(for: .waiting, phase: 4),
            WorkingIndicatorPresentation.waitingSymbol
        )
        XCTAssertEqual(
            WorkingIndicatorPresentation.text(for: .waiting, workingVerb: "Clanking", dots: ".."),
            "Waiting.."
        )
    }

    func testWorkingStateStillUsesAnimatedSymbolAndDots() {
        XCTAssertEqual(
            WorkingIndicatorPresentation.symbol(for: .working, phase: 2),
            WorkingIndicatorPresentation.animatedSymbols[2]
        )
        XCTAssertEqual(
            WorkingIndicatorPresentation.text(for: .working, workingVerb: "Clanking", dots: ".."),
            "Clanking.."
        )
    }
}
