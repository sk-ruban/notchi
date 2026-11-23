import Combine
import os.log
import Sparkle

nonisolated private let logger = Logger(subsystem: "com.ruban.notchi", category: "UpdateManager")

struct UpdateFailurePresentation: Equatable {
    let label: String

    init(label: String = String(localized: "Try again", comment: "Badge on Check for Updates after a failed check.")) {
        self.label = label
    }
}

/// Update state published to UI
enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case updateAvailable(version: String)
    case downloading(progress: Double)
    case readyToInstall(version: String)
    case error(UpdateFailurePresentation)
}

@MainActor
protocol UpdateChecking: AnyObject {
    var canCheckForUpdates: Bool { get }
    var sessionInProgress: Bool { get }
    func checkForUpdates()
}

extension SPUUpdater: UpdateChecking {}

/// Observable update manager that mirrors Sparkle state into SwiftUI.
/// The real install/relaunch flow is handled by Sparkle's standard UI.
@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()
    static let noUpdateErrorCode = 1001
    static let installationCanceledErrorCode = 4007

    @Published var state: UpdateState = .idle
    @Published var hasPendingUpdate: Bool = false

    var checkTimeout: TimeInterval = 60

    private var resetTask: Task<Void, Never>?
    private var cancelActiveCheck: (() -> Void)?

    private var updater: UpdateChecking?

    private init() {}

    func setUpdater(_ updater: UpdateChecking) {
        self.updater = updater
    }

    // MARK: - Public (UI actions)

    func checkForUpdates() {
        guard let updater else {
            logger.warning("Update check requested before the updater was available")
            return
        }

        guard updater.canCheckForUpdates else {
            logger.warning(
                "Update check skipped: canCheckForUpdates=false sessionInProgress=\(updater.sessionInProgress, privacy: .public)"
            )
            return
        }

        logger.notice(
            "Update check requested: sessionInProgress=\(updater.sessionInProgress, privacy: .public)"
        )
        updater.checkForUpdates()
    }

    func beginChecking(cancellation: (() -> Void)? = nil) {
        logger.notice("Update check started by Sparkle")
        cancelActiveCheck = cancellation
        state = .checking
        scheduleCheckTimeout()
    }

    func updateFound(version: String) {
        endCheckSession()
        hasPendingUpdate = true

        if case .downloading = state {
            return
        }

        state = .updateAvailable(version: version)
    }

    func userMadeChoice(_ choice: SPUUserUpdateChoice, stage: SPUUserUpdateStage, version: String) {
        switch choice {
        case .skip:
            clearPendingUpdate()
        case .dismiss:
            hasPendingUpdate = true
            state = stage == .notDownloaded
                ? .updateAvailable(version: version)
                : .readyToInstall(version: version)
        case .install:
            hasPendingUpdate = true
            if stage == .notDownloaded {
                state = .downloading(progress: 0)
            } else {
                state = .readyToInstall(version: version)
            }
        @unknown default:
            break
        }
    }

    func downloadStarted() {
        endCheckSession()
        hasPendingUpdate = true
        state = .downloading(progress: 0)
    }

    func readyToInstall(version: String) {
        endCheckSession()
        hasPendingUpdate = true
        state = .readyToInstall(version: version)
    }

    func noUpdateFound() {
        endCheckSession()
        clearPendingUpdate(showIdleImmediately: false)
        state = .upToDate
    }

    func updateError() {
        endCheckSession()
        state = .error(UpdateFailurePresentation())
    }

    func finishUpdateSession() {
        endCheckSession()

        if case .checking = state {
            state = .idle
        }
    }

    func timeOutChecking() {
        guard case .checking = state else { return }

        logger.error(
            "Update check never reported an outcome within \(self.checkTimeout, privacy: .public)s; resetting to idle"
        )

        let cancellation = cancelActiveCheck
        endCheckSession()
        cancellation?()
        state = .idle
    }

    func clearTransientStatus() {
        guard state.isTransientInlineStatus else { return }
        state = .idle
    }

    var shouldHandleUpdaterErrorInline: Bool {
        if case .checking = state {
            return true
        }

        return false
    }

    static func shouldIgnoreAbortError(_ error: NSError) -> Bool {
        error.domain == SUSparkleErrorDomain &&
            (error.code == noUpdateErrorCode || error.code == installationCanceledErrorCode)
    }

    private func scheduleCheckTimeout() {
        resetTask?.cancel()

        let timeout = checkTimeout
        resetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.timeOutChecking()
        }
    }

    private func endCheckSession() {
        resetTask?.cancel()
        resetTask = nil
        cancelActiveCheck = nil
    }

    private func clearPendingUpdate(showIdleImmediately: Bool = true) {
        hasPendingUpdate = false

        if showIdleImmediately {
            state = .idle
        }
    }
}

private extension UpdateState {
    var isTransientInlineStatus: Bool {
        switch self {
        case .upToDate, .error(_):
            return true
        default:
            return false
        }
    }
}
