import XCTest
@testable import notchi

final class SpinnerVerbsTests: XCTestCase {
    func testSpinnerVerbsIncludeExpandedReferenceListAndClanking() {
        XCTAssertGreaterThanOrEqual(SpinnerVerbs.all.count, 100)
        XCTAssertTrue(SpinnerVerbs.all.contains("Clanking"))
    }

    func testNextWorkingVerbDoesNotRepeatCurrentVerbWhenAlternativesExist() {
        let next = SpinnerVerbs.nextWorkingVerb(after: "Clanking")

        XCTAssertNotEqual(next, "Clanking")
        XCTAssertTrue(SpinnerVerbs.all.contains(next))
    }
}
