import XCTest
@testable import notchi

// On macOS 15 a main-actor class without a nonisolated deinit aborts in the
// isolated-deinit back-deploy shim when freed. AppKit subclasses are freed
// through Objective-C dealloc and don't hit it.
@MainActor
final class MainActorDeinitTests: XCTestCase {
    func testSoundSelectorIsFreedWhenItsPickerGoesAway() {
        weak var freed: SoundSelector?
        autoreleasepool {
            let selector = SoundSelector()
            freed = selector
        }
        XCTAssertNil(freed)
    }
}
