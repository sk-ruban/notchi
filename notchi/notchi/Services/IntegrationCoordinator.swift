import Foundation
import os.log

nonisolated private let integrationLogger = Logger(subsystem: "com.ruban.notchi", category: "IntegrationCoordinator")

// WHY: This service coordinates provider plumbing, not UI state. Its mutable
// delivery state is serialized on eventDeliveryQueue, so it should not inherit
// the app's default MainActor isolation.
nonisolated final class IntegrationCoordinator: @unchecked Sendable {
    static let shared = IntegrationCoordinator()

    private let eventSource: any AgentHookEventSource
    private let adaptersByProvider: [AgentProvider: any AgentProviderAdapter]
    // Socket callbacks arrive from SocketServer's concurrent client queue, so we
    // serialize delivery before handing events to the shared UI/state pipeline.
    private let eventDeliveryQueue = DispatchQueue(
        label: "com.ruban.notchi.integration.delivery",
        qos: .userInitiated
    )
    private var eventContinuation: AsyncStream<HookEvent>.Continuation?
    private var eventDeliveryTask: Task<Void, Never>?

    private let hooksEnabledPreference: @Sendable (AgentProvider) -> Bool
    private let setHooksEnabledPreference: @Sendable (Bool, AgentProvider) -> Void

    init(
        eventSource: any AgentHookEventSource = SocketServer.shared,
        adapters: [any AgentProviderAdapter] = [ClaudeProviderAdapter(), CodexProviderAdapter(), DevinProviderAdapter()],
        hooksEnabledPreference: @escaping @Sendable (AgentProvider) -> Bool = { AppSettings.areHooksEnabled(for: $0) },
        setHooksEnabledPreference: @escaping @Sendable (Bool, AgentProvider) -> Void = { AppSettings.setHooksEnabled($0, for: $1) }
    ) {
        self.eventSource = eventSource
        self.adaptersByProvider = Dictionary(uniqueKeysWithValues: adapters.map { ($0.provider, $0) })
        self.hooksEnabledPreference = hooksEnabledPreference
        self.setHooksEnabledPreference = setHooksEnabledPreference
    }

    func prepareForLaunch() {
        for provider in AgentProvider.allCases {
            adaptersByProvider[provider]?.configureForLaunch()
        }
    }

    func installHooksIfNeeded() {
        for provider in AgentProvider.allCases where hooksEnabledPreference(provider) {
            _ = adaptersByProvider[provider]?.installIfNeededStatus()
        }
    }

    @discardableResult
    func installHooksIfNeededStatus(for provider: AgentProvider) -> AgentHookInstallStatus {
        adaptersByProvider[provider]?.installIfNeededStatus() ?? .providerUnavailable
    }

    func installStatus(for provider: AgentProvider) -> AgentHookInstallStatus {
        guard let adapter = adaptersByProvider[provider], adapter.isProviderAvailable() else {
            return .providerUnavailable
        }
        guard hooksEnabledPreference(provider) else {
            return .disabled
        }
        return adapter.installStatus()
    }

    // WHY: The enabled preference is only persisted when enabling actually
    // installs the hooks. Otherwise a failed enable (provider missing, write
    // error) would leave the stored preference claiming hooks are on while
    // nothing is installed.
    @discardableResult
    func setHooksEnabled(_ enabled: Bool, for provider: AgentProvider) -> AgentHookInstallStatus {
        guard enabled else {
            setHooksEnabledPreference(false, provider)
            adaptersByProvider[provider]?.uninstall()
            return installStatus(for: provider)
        }

        let status = installHooksIfNeededStatus(for: provider)
        setHooksEnabledPreference(status == .installed, provider)
        return status
    }

    func isInstalled(for provider: AgentProvider) -> Bool {
        adaptersByProvider[provider]?.isInstalled() ?? false
    }

    func isProviderAvailable(for provider: AgentProvider) -> Bool {
        adaptersByProvider[provider]?.isProviderAvailable() ?? false
    }

    func hasAnyInstalledHooks() -> Bool {
        AgentProvider.allCases.contains { isInstalled(for: $0) }
    }

    func start(onEvent: @escaping @MainActor (HookEvent) -> Void) {
        startEventDeliveryIfNeeded(onEvent: onEvent)

        eventSource.start { [weak self] envelope in
            guard let self else { return nil }
            guard let event = self.normalize(envelope) else {
                integrationLogger.warning(
                    "Dropped unsupported \(envelope.provider.rawValue, privacy: .public) hook event: \(envelope.event, privacy: .public)"
                )
                return nil
            }

            self.enqueue(event)
            guard let requestId = event.interactionRequestId else { return nil }
            return HookInteractionResponseBroker.shared.waitForResponse(
                requestId: requestId,
                timeout: HookInteractionRequest.responseWaitTimeout
            )
        }
    }

    func stop() {
        eventSource.stop()
        stopEventDelivery()
    }

    private func normalize(_ envelope: AgentHookEnvelope) -> HookEvent? {
        adaptersByProvider[envelope.provider]?.normalize(envelope)
    }

    private func startEventDeliveryIfNeeded(onEvent: @escaping @MainActor (HookEvent) -> Void) {
        eventDeliveryQueue.sync {
            precondition(
                eventDeliveryTask == nil,
                "IntegrationCoordinator.start() called twice without stop()"
            )

            let eventStreamComponents = AsyncStream.makeStream(of: HookEvent.self)
            let eventStream = eventStreamComponents.stream
            eventContinuation = eventStreamComponents.continuation
            eventDeliveryTask = Task { [eventStream] in
                for await event in eventStream {
                    await MainActor.run {
                        onEvent(event)
                    }
                }
            }
        }
    }

    private func enqueue(_ event: HookEvent) {
        eventDeliveryQueue.async {
            self.eventContinuation?.yield(event)
        }
    }

    private func stopEventDelivery() {
        eventDeliveryQueue.sync {
            eventContinuation?.finish()
            eventContinuation = nil
            eventDeliveryTask?.cancel()
            eventDeliveryTask = nil
        }
    }
}
