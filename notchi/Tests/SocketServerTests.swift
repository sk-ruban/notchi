import Foundation
import XCTest
@testable import notchi

actor EventRecorder {
    private var events: [HookEvent] = []

    func record(_ event: HookEvent) {
        events.append(event)
    }

    func snapshot() -> [HookEvent] {
        events
    }
}

final class SocketServerTests: XCTestCase {
    private var activeServers: [(server: SocketServer, path: String)] = []
    private var activeClients: [UnixSocketClient] = []

    override func tearDown() async throws {
        activeClients.forEach { $0.closeConnection() }
        activeClients.removeAll()

        for entry in activeServers {
            entry.server.stop()
            _ = await waitUntil(timeout: 1) {
                !FileManager.default.fileExists(atPath: entry.path)
            }
            unlink(entry.path)
        }
        activeServers.removeAll()

        try await super.tearDown()
    }

    func testStalledClientDoesNotBlockLaterConnections() async throws {
        let recorder = EventRecorder()
        let (_, path) = try await makeServer(clientReadTimeout: 1.0, recorder: recorder)

        let stalledClient = try connectClient(to: path)
        let validClient = try connectClient(to: path)

        try validClient.send(makeEventPayload(sessionId: "second"))
        validClient.closeConnection()

        let deliveredPromptly = await waitUntil(timeout: 0.3) {
            await recorder.snapshot().map(\.sessionId) == ["second"]
        }

        XCTAssertTrue(deliveredPromptly, "Later client should be processed before the stalled client times out")
        XCTAssertTrue(stalledClient.isOpen)
    }

    func testAcceptBacklogProcessesAllQueuedClients() async throws {
        let recorder = EventRecorder()
        let eventCount = 5
        let (_, path) = try await makeServer(clientReadTimeout: 0.5, recorder: recorder)

        let clients = try (0..<eventCount).map { _ in
            try connectClient(to: path)
        }

        for (index, client) in clients.enumerated() {
            try client.send(makeEventPayload(sessionId: "queued-\(index)"))
            client.closeConnection()
        }

        let receivedAllEvents = await waitUntil(timeout: 1) {
            await recorder.snapshot().count == eventCount
        }

        XCTAssertTrue(receivedAllEvents, "All queued client events should be processed")
        let receivedSessionIds = Set(await recorder.snapshot().map(\.sessionId))
        let expectedSessionIds = Set((0..<eventCount).map { "queued-\($0)" })
        XCTAssertEqual(receivedSessionIds, expectedSessionIds)
    }

    func testSilentClientTimesOutAndServerStillAcceptsNextEvent() async throws {
        let recorder = EventRecorder()
        let (_, path) = try await makeServer(clientReadTimeout: 0.15, recorder: recorder)

        let silentClient = try connectClient(to: path)

        try await Task.sleep(nanoseconds: 300_000_000)
        let noEventsAfterTimeout = await recorder.snapshot().isEmpty
        XCTAssertTrue(noEventsAfterTimeout)

        let validClient = try connectClient(to: path)
        try validClient.send(makeEventPayload(sessionId: "after-timeout"))
        validClient.closeConnection()

        let validEventDelivered = await waitUntil(timeout: 0.5) {
            await recorder.snapshot().map(\.sessionId) == ["after-timeout"]
        }

        XCTAssertTrue(validEventDelivered, "Server should continue accepting clients after timing out a silent one")
        silentClient.closeConnection()
    }

    func testPartialPayloadCloseDoesNotBreakNextClient() async throws {
        let recorder = EventRecorder()
        let (_, path) = try await makeServer(clientReadTimeout: 0.2, recorder: recorder)

        let malformedClient = try connectClient(to: path)
        try malformedClient.send(Data("{\"session_id\":\"bad\"".utf8))
        malformedClient.closeConnection()

        try await Task.sleep(nanoseconds: 100_000_000)
        let noEventsAfterMalformedPayload = await recorder.snapshot().isEmpty
        XCTAssertTrue(noEventsAfterMalformedPayload)

        let validClient = try connectClient(to: path)
        try validClient.send(makeEventPayload(sessionId: "after-malformed"))
        validClient.closeConnection()

        let validEventDelivered = await waitUntil(timeout: 0.5) {
            await recorder.snapshot().map(\.sessionId) == ["after-malformed"]
        }

        XCTAssertTrue(validEventDelivered, "Malformed payload should not prevent the next client from being processed")
    }

    func testDuplicateServerStartPreservesExistingListener() async throws {
        let firstRecorder = EventRecorder()
        let secondRecorder = EventRecorder()
        let path = uniqueSocketPath()
        let (_, listeningPath) = try await makeServer(
            at: path,
            clientReadTimeout: 0.5,
            recorder: firstRecorder
        )

        let duplicateServer = SocketServer(socketPath: listeningPath, clientReadTimeout: 0.5)
        activeServers.append((duplicateServer, listeningPath))
        duplicateServer.start { event in
            Task {
                await secondRecorder.record(event)
            }
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        let client = try connectClient(to: listeningPath)
        try client.send(makeEventPayload(sessionId: "still-connected"))
        client.closeConnection()

        let originalServerReceivedEvent = await waitUntil(timeout: 0.5) {
            await firstRecorder.snapshot().map(\.sessionId) == ["still-connected"]
        }
        let duplicateSnapshot = await secondRecorder.snapshot()

        XCTAssertTrue(originalServerReceivedEvent, "Existing listener should remain connected after duplicate startup")
        XCTAssertTrue(duplicateSnapshot.isEmpty, "Duplicate server should not steal the socket path")
    }

    private func makeServer(
        at path: String? = nil,
        clientReadTimeout: TimeInterval,
        recorder: EventRecorder
    ) async throws -> (SocketServer, String) {
        let path = path ?? uniqueSocketPath()
        let server = SocketServer(socketPath: path, clientReadTimeout: clientReadTimeout)
        activeServers.append((server, path))

        server.start { event in
            Task {
                await recorder.record(event)
            }
        }

        let didStart = await waitUntil(timeout: 1) {
            FileManager.default.fileExists(atPath: path)
        }
        XCTAssertTrue(didStart, "Socket server did not start listening at \(path)")

        return (server, path)
    }

    private func connectClient(to path: String) throws -> UnixSocketClient {
        let client = try UnixSocketClient(path: path)
        activeClients.append(client)
        return client
    }

    private func uniqueSocketPath() -> String {
        "/tmp/notchi-tests-\(UUID().uuidString).sock"
    }

    private func makeEventPayload(sessionId: String) throws -> Data {
        let payload: [String: Any] = [
            "session_id": sessionId,
            "transcript_path": "/tmp/\(sessionId).jsonl",
            "cwd": "/tmp",
            "event": "SessionStart",
            "status": "waiting_for_input",
            "pid": NSNull(),
            "tty": NSNull(),
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func waitUntil(
        timeout: TimeInterval,
        pollIntervalNanoseconds: UInt64 = 10_000_000,
        condition: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if await condition() {
                return true
            }

            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        return await condition()
    }
}

private final class UnixSocketClient {
    private(set) var fileDescriptor: Int32

    var isOpen: Bool {
        fileDescriptor >= 0
    }

    init(path: String) throws {
        fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw posixError(code: errno, message: "Failed to create client socket")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBufferPtr = UnsafeMutableRawPointer(pathPtr)
                    .assumingMemoryBound(to: CChar.self)
                strcpy(pathBufferPtr, ptr)
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(fileDescriptor, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard connectResult == 0 else {
            let connectError = errno
            closeConnection()
            throw posixError(code: connectError, message: "Failed to connect to \(path)")
        }
    }

    deinit {
        closeConnection()
    }

    func send(_ data: Data) throws {
        var totalBytesWritten = 0

        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return
            }

            while totalBytesWritten < data.count {
                let bytesWritten = write(fileDescriptor, baseAddress.advanced(by: totalBytesWritten), data.count - totalBytesWritten)
                if bytesWritten > 0 {
                    totalBytesWritten += bytesWritten
                    continue
                }

                if bytesWritten < 0 && errno == EINTR {
                    continue
                }

                throw posixError(code: errno, message: "Failed to send test payload")
            }
        }
    }

    func closeConnection() {
        guard fileDescriptor >= 0 else { return }
        close(fileDescriptor)
        fileDescriptor = -1
    }

    private func posixError(code: Int32, message: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
            NSLocalizedDescriptionKey: "\(message) (\(code))",
        ])
    }
}
