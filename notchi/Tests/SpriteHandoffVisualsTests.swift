import XCTest
@testable import notchi

final class SpriteHandoffVisualsTests: XCTestCase {
    func testSourceVisualsStartSharpAndOpaqueThenFadeOut() {
        XCTAssertEqual(SpriteHandoffVisuals.sourceBlur(for: 0), 0, accuracy: 0.001)
        XCTAssertEqual(SpriteHandoffVisuals.sourceOpacity(for: 0), 1, accuracy: 0.001)

        XCTAssertEqual(SpriteHandoffVisuals.sourceBlur(for: 0.35), 5, accuracy: 0.001)
        XCTAssertEqual(SpriteHandoffVisuals.sourceOpacity(for: 0.35), 0, accuracy: 0.001)
    }

    func testDestinationVisualsStartBlurredAndHiddenThenResolveIn() {
        XCTAssertEqual(SpriteHandoffVisuals.destinationBlur(for: 0), 5, accuracy: 0.001)
        XCTAssertEqual(SpriteHandoffVisuals.destinationOpacity(for: 0), 0, accuracy: 0.001)
        XCTAssertEqual(SpriteHandoffVisuals.destinationOpacity(for: 0.35), 0, accuracy: 0.001)

        XCTAssertEqual(SpriteHandoffVisuals.destinationBlur(for: 0.7), 0, accuracy: 0.001)
        XCTAssertEqual(SpriteHandoffVisuals.destinationOpacity(for: 0.7), 1, accuracy: 0.001)
    }

    func testSourceAndDestinationDoNotOverlapVisibly() {
        XCTAssertEqual(
            SpriteHandoffVisuals.sourceOpacity(for: 0.35),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            SpriteHandoffVisuals.destinationOpacity(for: 0.35),
            0,
            accuracy: 0.001
        )
    }

    func testInteractivityTracksVisibleOpacityThreshold() {
        XCTAssertTrue(SpriteHandoffVisuals.isInteractive(for: 0, isCollapsing: true))
        XCTAssertFalse(SpriteHandoffVisuals.isInteractive(for: 0.35, isCollapsing: true))

        XCTAssertFalse(SpriteHandoffVisuals.isInteractive(for: 0, isCollapsing: false))
        XCTAssertFalse(SpriteHandoffVisuals.isInteractive(for: 0.35, isCollapsing: false))
        XCTAssertFalse(SpriteHandoffVisuals.isInteractive(for: 0.5, isCollapsing: false))
        XCTAssertTrue(SpriteHandoffVisuals.isInteractive(for: 0.53, isCollapsing: false))
    }

    func testSourceVisualsClampOutsideExpectedProgressRange() {
        XCTAssertEqual(SpriteHandoffVisuals.sourceBlur(for: -0.2), 0, accuracy: 0.001)
        XCTAssertEqual(SpriteHandoffVisuals.sourceOpacity(for: -0.2), 1, accuracy: 0.001)

        XCTAssertEqual(SpriteHandoffVisuals.sourceBlur(for: 2), 5, accuracy: 0.001)
        XCTAssertEqual(SpriteHandoffVisuals.sourceOpacity(for: 2), 0, accuracy: 0.001)
    }

    func testDestinationVisualsClampOutsideExpectedProgressRange() {
        XCTAssertEqual(SpriteHandoffVisuals.destinationBlur(for: -0.2), 5, accuracy: 0.001)
        XCTAssertEqual(SpriteHandoffVisuals.destinationOpacity(for: -0.2), 0, accuracy: 0.001)

        XCTAssertEqual(SpriteHandoffVisuals.destinationBlur(for: 2), 0, accuracy: 0.001)
        XCTAssertEqual(SpriteHandoffVisuals.destinationOpacity(for: 2), 1, accuracy: 0.001)
    }
}
