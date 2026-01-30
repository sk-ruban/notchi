import AppKit

@MainActor
@Observable
final class NotchPanelManager {
    static let shared = NotchPanelManager()

    private(set) var isExpanded = false
    weak var panel: NSPanel?

    private var notchRect: CGRect = .zero
    private var panelRect: CGRect = .zero
    private var screenHeight: CGFloat = 0

    private var mouseDownMonitor: EventMonitor?

    private init() {
        setupEventMonitors()
    }

    func configure(notchRect: CGRect, panelRect: CGRect, screenHeight: CGFloat) {
        self.notchRect = notchRect
        self.panelRect = panelRect
        self.screenHeight = screenHeight
    }

    private func setupEventMonitors() {
        mouseDownMonitor = EventMonitor(mask: .leftMouseDown) { [weak self] _ in
            Task { @MainActor in
                self?.handleMouseDown()
            }
        }
        mouseDownMonitor?.start()
    }

    private func handleMouseDown() {
        let location = NSEvent.mouseLocation

        if isExpanded {
            // Check if click is outside the panel
            if !panelRect.contains(location) {
                collapse()
            }
        } else {
            // Check if click is on the notch area
            if notchRect.contains(location) {
                expand()
            }
        }
    }

    func expand() {
        guard !isExpanded else { return }
        isExpanded = true
        panel?.ignoresMouseEvents = false
    }

    func collapse() {
        guard isExpanded else { return }
        isExpanded = false
        panel?.ignoresMouseEvents = true
    }

    func toggle() {
        if isExpanded {
            collapse()
        } else {
            expand()
        }
    }
}
