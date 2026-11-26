import XCTest
@testable import notchi

final class UsageRingViewTests: XCTestCase {
    private static let standardDiameter: CGFloat = 15
    private static let standardLineWidth: CGFloat = 3
    private static let criticalDiameter: CGFloat = 20
    private static let criticalLineWidth: CGFloat = 2

    func testValueLabelIsHiddenBelowNinetyPercent() {
        for percentage in [-5, 0, 49, 80, 89] {
            XCTAssertNil(UsageRingView(content: .percentage(percentage)).valueLabel, "\(percentage)%")
        }
    }

    func testValueLabelShowsThePercentageFromNinetyToNinetyNine() {
        for (percentage, expected) in [(90, "90"), (94, "94"), (99, "99")] {
            XCTAssertEqual(UsageRingView(content: .percentage(percentage)).valueLabel, expected)
        }
    }

    func testValueLabelIsAnExclamationMarkAtOrAboveOneHundredPercent() {
        for percentage in [100, 137] {
            XCTAssertEqual(UsageRingView(content: .percentage(percentage)).valueLabel, "!", "\(percentage)%")
        }
    }

    func testValueLabelIsHiddenForUnlimitedUsage() {
        XCTAssertNil(UsageRingView(content: .unlimited).valueLabel)
    }

    func testRingKeepsItsStandardSizeBelowNinetyPercent() {
        let view = UsageRingView(content: .percentage(89))

        XCTAssertEqual(view.diameter, Self.standardDiameter)
        XCTAssertEqual(view.lineWidth, Self.standardLineWidth)
    }

    func testRingGrowsAndThinsToFitTheValueLabelAtNinetyPercent() {
        let view = UsageRingView(content: .percentage(90))

        XCTAssertEqual(view.diameter, Self.criticalDiameter)
        XCTAssertEqual(view.lineWidth, Self.criticalLineWidth)
    }
}
