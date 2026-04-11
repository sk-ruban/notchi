import AppKit

@MainActor
@Observable
final class NotchPanelManager {
    enum CollapsedMode: Equatable {
        case normalCollapsed
        case compactIdle
    }

    static let shared = NotchPanelManager()
    // Reference hover growth reads wider than taller, so keep the hover expansion biased horizontally.
    static let collapsedHoverHorizontalInset: CGFloat = 7.5
    static let collapsedHoverBottomInset: CGFloat = 5

    private static let compactNotchPaddingTotal: CGFloat = 16
    private static func makeCompactNotchRect(notchSize: CGSize, notchRect: CGRect) -> CGRect {
        CGRect(
            x: notchRect.midX - ((notchSize.width + compactNotchPaddingTotal) / 2),
            y: notchRect.minY,
            width: notchSize.width + compactNotchPaddingTotal,
            height: notchRect.height
        )
    }
    private static func makeCollapsedHoverRect(baseRect: CGRect) -> CGRect {
        CGRect(
            x: baseRect.minX - collapsedHoverHorizontalInset,
            y: baseRect.minY - collapsedHoverBottomInset,
            width: baseRect.width + (collapsedHoverHorizontalInset * 2),
            height: baseRect.height + collapsedHoverBottomInset
        )
    }

    private let notificationCenter: NotificationCenter
    private let userDefaults: UserDefaults
    private let hoverExitDelay: Duration
    private let activeSessionCountProvider: @MainActor () -> Int
    private let mouseLocationProvider: @MainActor () -> CGPoint
    private let collapsedHoverEnterFeedback: @MainActor () -> Void
    private let pinToggleFeedback: @MainActor () -> Void

    private var observerTokens: [NSObjectProtocol] = []
    private var cachedShouldUseCompactIdle = false
    private var pendingHoverExitTask: Task<Void, Never>?
    private var mouseDownMonitor: EventMonitor?
    private var mouseMoveMonitor: EventMonitor?

    private(set) var isExpanded = false
    private(set) var isPinned = false
    private(set) var isCollapsedHovered = false
    private(set) var collapsedMode: CollapsedMode = .normalCollapsed
    private(set) var notchSize: CGSize = .zero
    private(set) var notchRect: CGRect = .zero
    private(set) var compactNotchRect: CGRect = .zero
    private(set) var panelRect: CGRect = .zero
    /// The exact notch shape from the system bezel path, or nil if unavailable
    private(set) var systemNotchPath: CGPath?

    private var collapsedBaseRect: CGRect {
        collapsedMode == .compactIdle ? compactNotchRect : notchRect
    }

    var activeCollapsedRect: CGRect {
        isCollapsedHovered ? Self.makeCollapsedHoverRect(baseRect: collapsedBaseRect) : collapsedBaseRect
    }

    init(
        notificationCenter: NotificationCenter = .default,
        userDefaults: UserDefaults = .standard,
        hoverExitDelay: Duration = .zero,
        activeSessionCountProvider: @escaping @MainActor () -> Int = { SessionStore.shared.activeSessionCount },
        mouseLocationProvider: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation },
        collapsedHoverEnterFeedback: @escaping @MainActor () -> Void = { HapticService.shared.playHoverClick() },
        pinToggleFeedback: @escaping @MainActor () -> Void = { HapticService.shared.playToggle() },
        startEventMonitors: Bool = true,
        observeExternalState: Bool = true
    ) {
        self.notificationCenter = notificationCenter
        self.userDefaults = userDefaults
        self.hoverExitDelay = hoverExitDelay
        self.activeSessionCountProvider = activeSessionCountProvider
        self.mouseLocationProvider = mouseLocationProvider
        self.collapsedHoverEnterFeedback = collapsedHoverEnterFeedback
        self.pinToggleFeedback = pinToggleFeedback

        if startEventMonitors {
            setupEventMonitors()
        }
        if observeExternalState {
            setupObservers()
        }

        refreshIdleMode()
    }

    deinit {
        MainActor.assumeIsolated {
            observerTokens.forEach { notificationCenter.removeObserver($0) }
            pendingHoverExitTask?.cancel()
        }
    }

    func updateGeometry(for screen: NSScreen) {
        let newNotchSize = screen.notchSize
        let screenFrame = screen.frame

        notchSize = newNotchSize
        systemNotchPath = screen.notchPath

        let notchCenterX = screenFrame.origin.x + screenFrame.width / 2
        let sideWidth = max(0, newNotchSize.height - 12) + 24
        let notchTotalWidth = newNotchSize.width + sideWidth

        notchRect = CGRect(
            x: notchCenterX - notchTotalWidth / 2,
            y: screenFrame.maxY - newNotchSize.height,
            width: notchTotalWidth,
            height: newNotchSize.height
        )

        compactNotchRect = Self.makeCompactNotchRect(notchSize: newNotchSize, notchRect: notchRect)

        let panelSize = NotchConstants.expandedPanelSize
        let panelWidth = panelSize.width + NotchConstants.expandedPanelHorizontalPadding
        panelRect = CGRect(
            x: notchCenterX - panelWidth / 2,
            y: screenFrame.maxY - panelSize.height,
            width: panelWidth,
            height: panelSize.height
        )

        refreshIdleMode()
    }

#if DEBUG
    func setGeometryForTesting(
        notchSize: CGSize,
        notchRect: CGRect,
        panelRect: CGRect = .zero,
        systemNotchPath: CGPath? = nil
    ) {
        self.notchSize = notchSize
        self.notchRect = notchRect
        self.panelRect = panelRect
        self.systemNotchPath = systemNotchPath

        compactNotchRect = Self.makeCompactNotchRect(notchSize: notchSize, notchRect: notchRect)

        refreshIdleMode()
    }
#endif

    func expand() {
        guard !isExpanded else { return }
        cancelPendingHoverExitTask()
        setCollapsedHovered(false)
        isExpanded = true
        refreshIdleMode()
    }

    func collapse() {
        guard isExpanded else { return }
        cancelPendingHoverExitTask()
        isExpanded = false
        isPinned = false
        setCollapsedHovered(false)
        refreshIdleMode()
    }

    func toggle() {
        if isExpanded {
            collapse()
        } else {
            expand()
        }
    }

    func togglePin() {
        isPinned.toggle()
        pinToggleFeedback()
    }

    private func handleCollapsedHoverEntered() {
        cancelPendingHoverExitTask()
        guard !isExpanded else { return }
        setCollapsedHovered(true)
    }

    private func handleCollapsedHoverExited() {
        guard !isExpanded, isCollapsedHovered else { return }
        scheduleHoverExit()
    }

    func handleMouseLocationChanged(_ location: CGPoint) {
        guard !isExpanded else { return }

        let trackingRect = isCollapsedHovered ? activeCollapsedRect : collapsedBaseRect
        if trackingRect.contains(location) {
            handleCollapsedHoverEntered()
        } else {
            handleCollapsedHoverExited()
        }
    }

    func refreshIdleMode() {
        cachedShouldUseCompactIdle = userDefaults.bool(forKey: AppSettings.hideSpriteWhenIdleKey)
            && activeSessionCountProvider() == 0

        if !cachedShouldUseCompactIdle {
            cancelPendingHoverExitTask()
            setCollapsedMode(.normalCollapsed)
            resyncCollapsedHoverIfNeeded()
            return
        }

        if isExpanded {
            cancelPendingHoverExitTask()
            setCollapsedMode(.compactIdle)
            return
        }

        setCollapsedMode(.compactIdle)
        resyncCollapsedHoverIfNeeded()
    }

    private func setupObservers() {
        observerTokens.append(
            notificationCenter.addObserver(
                forName: .sessionStoreActiveSessionCountDidChange,
                object: SessionStore.shared,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshIdleMode()
                }
            }
        )

        observerTokens.append(
            notificationCenter.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshIdleMode()
                }
            }
        )
    }

    private func setupEventMonitors() {
        mouseDownMonitor = EventMonitor(mask: .leftMouseDown) { [weak self] event in
            let location = Self.screenLocation(from: event)
            Task { @MainActor in
                self?.handleMouseDown(at: location)
            }
        }
        mouseDownMonitor?.start()

        mouseMoveMonitor = EventMonitor(mask: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleMouseLocationChanged(self.mouseLocationProvider())
            }
        }
        mouseMoveMonitor?.start()
    }

    private static func screenLocation(from event: NSEvent) -> CGPoint {
        if let window = event.window {
            return window.convertPoint(toScreen: event.locationInWindow)
        }
        if let cgEvent = event.cgEvent {
            return cgEvent.unflippedLocation
        }
        return NSEvent.mouseLocation
    }

    private func handleMouseDown(at location: CGPoint) {
        if isExpanded {
            if !isPinned && !panelRect.contains(location) {
                collapse()
            }
        } else if activeCollapsedRect.contains(location) {
            expand()
        }
    }

#if DEBUG
    func handleMouseDownForTesting(at location: CGPoint) {
        handleMouseDown(at: location)
    }
#endif

    private func scheduleHoverExit() {
        cancelPendingHoverExitTask()
        if hoverExitDelay == .zero {
            setCollapsedHovered(false)
            return
        }

        pendingHoverExitTask = Task { [weak self, hoverExitDelay] in
            try? await Task.sleep(for: hoverExitDelay)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self else { return }
                guard !self.isExpanded else { return }
                self.setCollapsedHovered(false)
            }
        }
    }

    private func cancelPendingHoverExitTask() {
        pendingHoverExitTask?.cancel()
        pendingHoverExitTask = nil
    }

    private func resyncCollapsedHoverIfNeeded() {
        guard isCollapsedHovered, !isExpanded else { return }
        handleMouseLocationChanged(mouseLocationProvider())
    }

    private func setCollapsedMode(_ newMode: CollapsedMode) {
        guard collapsedMode != newMode else { return }
        collapsedMode = newMode
    }

    private func setCollapsedHovered(_ newValue: Bool) {
        guard isCollapsedHovered != newValue else { return }
        isCollapsedHovered = newValue

        if newValue {
            collapsedHoverEnterFeedback()
        }
    }
}
