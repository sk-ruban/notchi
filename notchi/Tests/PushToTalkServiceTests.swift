import Carbon.HIToolbox
import XCTest
@testable import notchi

@MainActor
final class PushToTalkServiceTests: XCTestCase {
    private final class FakeMonitor: HoldKeyMonitoring {
        var handler: ((PushToTalkService.HoldKeyEvent) -> Void)?
        func begin(_ handler: @escaping (PushToTalkService.HoldKeyEvent) -> Void) { self.handler = handler }
        func end() { handler = nil }
    }

    private let shortcut = GlobalShortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(cmdKey | optionKey | shiftKey))

    func testMatchesRequiresKeyCodeAndModifiers() {
        let match = PushToTalkService.HoldKeyEvent(kind: .down, keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(cmdKey | optionKey | shiftKey))
        let wrongMods = PushToTalkService.HoldKeyEvent(kind: .down, keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(cmdKey))
        XCTAssertTrue(PushToTalkService.matches(match, shortcut: shortcut))
        XCTAssertFalse(PushToTalkService.matches(wrongMods, shortcut: shortcut))
    }

    func testDownThenUpFiresStartThenStopOnce() {
        var starts = 0, stops = 0
        let monitor = FakeMonitor()
        let service = PushToTalkService(
            shortcut: { self.shortcut },
            onStart: { starts += 1 },
            onStop: { stops += 1 },
            eventSource: monitor
        )
        service.start()

        let down = PushToTalkService.HoldKeyEvent(kind: .down, keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(cmdKey | optionKey | shiftKey))
        let up = PushToTalkService.HoldKeyEvent(kind: .up, keyCode: UInt32(kVK_ANSI_D), modifiers: 0)

        monitor.handler?(down)
        monitor.handler?(down) // key repeat must not re-fire start
        monitor.handler?(up)

        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 1)
    }

    func testKeyUpWithoutActiveHoldDoesNotFireStop() {
        var stops = 0
        let monitor = FakeMonitor()
        let service = PushToTalkService(shortcut: { self.shortcut }, onStart: {}, onStop: { stops += 1 }, eventSource: monitor)
        service.start()
        monitor.handler?(PushToTalkService.HoldKeyEvent(kind: .up, keyCode: UInt32(kVK_ANSI_D), modifiers: 0))
        XCTAssertEqual(stops, 0)
    }
}
