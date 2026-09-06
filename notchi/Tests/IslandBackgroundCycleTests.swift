import XCTest
@testable import notchi

final class IslandBackgroundCycleTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    func testEveryStartingTerrainLastsThirtyMinutesThenCyclesThroughAllThree() {
        for (index, terrain) in IslandBackground.terrains.enumerated() {
            let cycle = IslandBackgroundCycle(startedAt: start, startingBackground: terrain)
            XCTAssertEqual(cycle.background(at: start), terrain)
            XCTAssertEqual(cycle.background(at: start.addingTimeInterval(1_799.99)), terrain)
            XCTAssertEqual(
                cycle.background(at: start.addingTimeInterval(1_800)),
                IslandBackground.terrains[(index + 1) % 3]
            )
            XCTAssertEqual(
                cycle.background(at: start.addingTimeInterval(3_600)),
                IslandBackground.terrains[(index + 2) % 3]
            )
            XCTAssertEqual(cycle.background(at: start.addingTimeInterval(5_400)), terrain)
        }
    }

    func testElapsedTimeCatchesUpAfterPanelDismissalOrSleep() {
        let cycle = IslandBackgroundCycle(startedAt: start, startingBackground: .water)
        XCTAssertEqual(cycle.background(at: start.addingTimeInterval(8 * 1_800 + 20)), .grassland)
        XCTAssertEqual(cycle.background(at: start.addingTimeInterval(9 * 1_800)), .water)
    }

    func testClockMovingBackwardsKeepsStartingTerrain() {
        let cycle = IslandBackgroundCycle(startedAt: start, startingBackground: .ground)
        XCTAssertEqual(cycle.background(at: start.addingTimeInterval(-3_600)), .ground)
    }

    func testAutomaticCannotBecomeARecursiveCycleEntry() {
        let cycle = IslandBackgroundCycle(startedAt: start, startingBackground: .automatic)
        XCTAssertEqual(cycle.background(at: start), .grassland)
        XCTAssertEqual(IslandBackground.allCases.first, .automatic)
        XCTAssertFalse(IslandBackground.terrains.contains(.automatic))
    }
}
