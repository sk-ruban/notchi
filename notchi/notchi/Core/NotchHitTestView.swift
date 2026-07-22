import AppKit

final class NotchHitTestView: NSView {
    weak var panelManager: NotchPanelManager?
    private var collapsedHoverTrackingArea: NSTrackingArea?
    private var expandedPanelTrackingArea: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let window, let manager = panelManager else { return nil }
        let screenPoint = window.convertPoint(toScreen: convert(point, to: nil))
        let activeRect = manager.isExpanded ? manager.panelRect : manager.activeCollapsedRect
        guard activeRect.contains(screenPoint) else { return nil }
        return super.hitTest(point)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateCollapsedHoverTrackingArea()
        updateExpandedPanelTrackingArea()
    }

    private func updateCollapsedHoverTrackingArea() {
        if let collapsedHoverTrackingArea {
            removeTrackingArea(collapsedHoverTrackingArea)
            self.collapsedHoverTrackingArea = nil
        }

        guard let window, let manager = panelManager else { return }
        guard manager.notchSize != .zero else { return }
        let screenRect = manager.collapsedTrackingRect
        guard !screenRect.isEmpty else { return }

        let viewRect = convert(window.convertFromScreen(screenRect), from: nil)
        let trackingArea = NSTrackingArea(
            rect: viewRect,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .enabledDuringMouseDrag],
            owner: self
        )
        addTrackingArea(trackingArea)
        collapsedHoverTrackingArea = trackingArea
    }

    private func updateExpandedPanelTrackingArea() {
        if let expandedPanelTrackingArea {
            removeTrackingArea(expandedPanelTrackingArea)
            self.expandedPanelTrackingArea = nil
        }

        guard let window, let manager = panelManager else { return }
        guard manager.isExpanded, AppSettings.expandOnHover else { return }
        let screenRect = manager.panelRect
        guard !screenRect.isEmpty else { return }

        let viewRect = convert(window.convertFromScreen(screenRect), from: nil)
        let trackingArea = NSTrackingArea(
            rect: viewRect,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        )
        addTrackingArea(trackingArea)
        expandedPanelTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea === expandedPanelTrackingArea {
            panelManager?.handleExpandedPanelHoverEntered()
            return
        }
        forwardMouseLocation(event)
    }

    override func mouseMoved(with event: NSEvent) {
        forwardMouseLocation(event)
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea === expandedPanelTrackingArea {
            panelManager?.handleExpandedPanelHoverExited()
            return
        }
        panelManager?.handleCollapsedHoverExited()
    }

    private func forwardMouseLocation(_ event: NSEvent) {
        guard let window, let manager = panelManager else { return }
        manager.handleMouseLocationChanged(window.convertPoint(toScreen: event.locationInWindow))
    }
}
