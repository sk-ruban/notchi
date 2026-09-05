import AppKit
import Carbon.HIToolbox

@MainActor
final class PushToTalkService {
    struct HoldKeyEvent: Equatable {
        enum Kind { case down, up }
        let kind: Kind
        let keyCode: UInt32
        let modifiers: UInt32
    }

    private let shortcut: @MainActor () -> GlobalShortcut
    private let onStart: @MainActor () -> Void
    private let onStop: @MainActor () -> Void
    private let eventSource: HoldKeyMonitoring
    private var isHolding = false

    init(
        shortcut: @escaping @MainActor () -> GlobalShortcut = { AppSettings.dictationPushToTalkShortcut },
        onStart: @escaping @MainActor () -> Void,
        onStop: @escaping @MainActor () -> Void,
        eventSource: HoldKeyMonitoring = NSEventHoldKeyMonitor()
    ) {
        self.shortcut = shortcut
        self.onStart = onStart
        self.onStop = onStop
        self.eventSource = eventSource
    }

    func start() {
        eventSource.begin { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    func stop() {
        eventSource.end()
        isHolding = false
    }

    func handle(_ event: HoldKeyEvent) {
        switch event.kind {
        case .down:
            guard Self.matches(event, shortcut: shortcut()), !isHolding else { return }
            isHolding = true
            onStart()
        case .up:
            guard isHolding, event.keyCode == shortcut().keyCode else { return }
            isHolding = false
            onStop()
        }
    }

    nonisolated static func matches(_ event: HoldKeyEvent, shortcut: GlobalShortcut) -> Bool {
        event.keyCode == shortcut.keyCode && event.modifiers == shortcut.modifiers
    }
}

@MainActor
protocol HoldKeyMonitoring: AnyObject {
    func begin(_ handler: @escaping (PushToTalkService.HoldKeyEvent) -> Void)
    func end()
}

// Not unit-tested: requires Accessibility and a live event stream.
@MainActor
final class NSEventHoldKeyMonitor: HoldKeyMonitoring {
    private var globalMonitor: Any?
    private var localMonitor: Any?

    // Explicit nonisolated init so this type can be constructed as a default
    // argument value (default-argument expressions evaluate in a nonisolated
    // context even for a @MainActor initializer's parameter list).
    nonisolated init() {}

    func begin(_ handler: @escaping (PushToTalkService.HoldKeyEvent) -> Void) {
        let convert: (NSEvent) -> PushToTalkService.HoldKeyEvent = { event in
            PushToTalkService.HoldKeyEvent(
                kind: event.type == .keyDown ? .down : .up,
                keyCode: UInt32(event.keyCode),
                modifiers: GlobalShortcut.carbonModifiers(from: event.modifierFlags)
            )
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { handler(convert($0)) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            handler(convert(event)); return event
        }
    }

    func end() {
        [globalMonitor, localMonitor].forEach { monitor in
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        globalMonitor = nil; localMonitor = nil
    }
}
