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

    func testWorkingTextAppendsElapsedTimeBeforeDots() {
        let text = WorkingIndicatorPresentation.text(for: .working, workingVerb: "Clanking", dots: "..", elapsed: "34s")
        XCTAssertEqual(text, "Clanking for 34s..")
    }

    func testWaitingTextIgnoresElapsedTime() {
        let text = WorkingIndicatorPresentation.text(for: .waiting, workingVerb: "Clanking", dots: ".", elapsed: "34s")
        XCTAssertEqual(text, "Waiting.")
    }

    func testElapsedDisplayFormatsSecondsMinutesAndHours() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        func display(after seconds: TimeInterval) -> String? {
            WorkingIndicatorPresentation.elapsedDisplay(
                since: start,
                now: start.addingTimeInterval(seconds),
                locale: Locale(identifier: "en_US")
            )
        }
        XCTAssertNil(display(after: 0.4))
        XCTAssertEqual(display(after: 34), "34s")
        XCTAssertEqual(display(after: 59), "59s")
        XCTAssertEqual(display(after: 94), "1m 34s")
        XCTAssertEqual(display(after: 3720), "1h 2m")
        XCTAssertEqual(display(after: 7170), "1h 59m", "dropped seconds must not round the counter into the future")
    }

    func testElapsedDisplayLocalizesUnitsForJapanese() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let display = WorkingIndicatorPresentation.elapsedDisplay(
            since: start,
            now: start.addingTimeInterval(94),
            locale: Locale(identifier: "ja_JP")
        )
        XCTAssertEqual(display, "1分34秒")
    }
}
