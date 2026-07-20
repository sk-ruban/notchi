import XCTest
@testable import notchi

@MainActor
final class GrassSpriteMotionTests: XCTestCase {
    func testReduceMotionZeroesAllMotionAndPausesTheClock() {
        for task in [NotchiTask.idle, .working, .waiting] {
            let motion = GrassSpriteMotion(state: NotchiState(task: task), reduceMotion: true)

            XCTAssertEqual(motion.bobAmplitude, 0, task.rawValue)
            XCTAssertEqual(motion.swayAmplitude, 0, task.rawValue)
            XCTAssertEqual(motion.trembleAmplitude, 0, task.rawValue)
            XCTAssertFalse(motion.isAnimating, task.rawValue)
        }
    }

    func testMotionClockRunsAtFullCadenceForAllTasks() {
        for task in [NotchiTask.idle, .working, .waiting, .sleeping] {
            let motion = GrassSpriteMotion(state: NotchiState(task: task), reduceMotion: false)

            XCTAssertEqual(motion.frameInterval, 1.0 / 30.0, accuracy: 0.0001, task.rawValue)
        }
    }

    func testAmplitudesMatchLegacyGrassValuesWithoutReduceMotion() {
        let idle = GrassSpriteMotion(state: NotchiState(task: .idle), reduceMotion: false)
        let working = GrassSpriteMotion(state: NotchiState(task: .working), reduceMotion: false)
        let sleeping = GrassSpriteMotion(state: NotchiState(task: .sleeping), reduceMotion: false)

        XCTAssertEqual(idle.bobAmplitude, 1)
        XCTAssertEqual(working.bobAmplitude, 1.5)
        XCTAssertEqual(working.bobDuration, 1.0)
        XCTAssertEqual(idle.bobDuration, 1.5)
        XCTAssertEqual(sleeping.bobAmplitude, 0)
        XCTAssertEqual(sleeping.swayAmplitude, 0)
        XCTAssertFalse(sleeping.isAnimating)
        XCTAssertTrue(idle.isAnimating)
    }

    func testSobTremblesAtFullCadenceUnlessReduceMotion() {
        var sobState = NotchiState(task: .working)
        sobState.emotion = .sob
        let sob = GrassSpriteMotion(state: sobState, reduceMotion: false)
        let calmedSob = GrassSpriteMotion(state: sobState, reduceMotion: true)

        XCTAssertEqual(sob.trembleAmplitude, 0.3)
        XCTAssertTrue(sob.isAnimating)
        XCTAssertEqual(calmedSob.trembleAmplitude, 0)
        XCTAssertFalse(calmedSob.isAnimating)
    }
}
