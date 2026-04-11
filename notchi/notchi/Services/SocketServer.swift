import Foundation
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "SocketServer")

typealias HookEventHandler = @Sendable (HookEvent) -> Void

final class SocketServer {
    static let socketPath = "/tmp/notchi.sock"
    static let shared = SocketServer(socketPath: socketPath, clientReadTimeout: 0.5)

    private let socketPath: String
    private let clientReadTimeout: TimeInterval
    private var serverSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var eventHandler: HookEventHandler?
    private let serverQueue = DispatchQueue(label: "com.ruban.notchi.socket.server", qos: .userInitiated)
    private let clientQueue = DispatchQueue(label: "com.ruban.notchi.socket.client", qos: .userInitiated, attributes: .concurrent)

    init(socketPath: String = SocketServer.socketPath, clientReadTimeout: TimeInterval = 0.5) {
        self.socketPath = socketPath
        self.clientReadTimeout = clientReadTimeout
    }

    func start(onEvent: @escaping HookEventHandler) {
        serverQueue.async { [weak self] in
            self?.startServer(onEvent: onEvent)
        }
    }

    private func startServer(onEvent: @escaping HookEventHandler) {
        guard serverSocket < 0 else { return }

        switch prepareSocketPathForBinding() {
        case .ready:
            break
        case .alreadyActive:
            logger.warning("Socket listener already active at \(self.socketPath, privacy: .public); skipping duplicate startup")
            return
        case .failed(let errorCode):
            logger.error("Failed to prepare socket path: \(errorCode)")
            return
        }

        eventHandler = onEvent

        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            logger.error("Failed to create socket: \(errno)")
            return
        }

        let flags = fcntl(serverSocket, F_GETFL)
        _ = fcntl(serverSocket, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBufferPtr = UnsafeMutableRawPointer(pathPtr)
                    .assumingMemoryBound(to: CChar.self)
                strcpy(pathBufferPtr, ptr)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            logger.error("Failed to bind socket: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return
        }

        if chmod(socketPath, 0o600) != 0 {
            logger.warning("Failed to restrict socket permissions: \(errno)")
        }

        guard listen(serverSocket, 10) == 0 else {
            logger.error("Failed to listen: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return
        }

        logger.info("Listening on \(self.socketPath, privacy: .public)")

        acceptSource = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: serverQueue)
        acceptSource?.setEventHandler { [weak self] in
            self?.acceptConnections()
        }
        acceptSource?.setCancelHandler { [weak self] in
            if let fd = self?.serverSocket, fd >= 0 {
                close(fd)
                self?.serverSocket = -1
            }
        }
        acceptSource?.resume()
    }

    func stop() {
        serverQueue.async { [weak self] in
            self?.stopServer()
        }
    }

    private func prepareSocketPathForBinding() -> SocketPathPreparation {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            return .ready
        }

        switch existingSocketState(at: socketPath) {
        case .activeListener:
            return .alreadyActive
        case .stale, .missing:
            let unlinkResult = unlink(socketPath)
            if unlinkResult == 0 || errno == ENOENT {
                return .ready
            }
            return .failed(errno)
        case .failed(let errorCode):
            return .failed(errorCode)
        }
    }

    private func existingSocketState(at path: String) -> ExistingSocketState {
        let probeSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probeSocket >= 0 else {
            return .failed(errno)
        }
        defer { close(probeSocket) }

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
                connect(probeSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if connectResult == 0 {
            return .activeListener
        }

        switch errno {
        case ENOENT:
            return .missing
        case ECONNREFUSED:
            return .stale
        default:
            return .failed(errno)
        }
    }

    private func stopServer() {
        if let acceptSource {
            acceptSource.cancel()
            self.acceptSource = nil
        } else if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }

        unlink(socketPath)
    }

    private func acceptConnections() {
        while true {
            let clientSocket = accept(serverSocket, nil, nil)
            guard clientSocket >= 0 else {
                let acceptError = errno

                if acceptError == EINTR {
                    continue
                }

                if acceptError == EAGAIN || acceptError == EWOULDBLOCK {
                    return
                }

                logger.error("Failed to accept connection: \(acceptError)")
                return
            }

            configureClientSocket(clientSocket)
            let eventHandler = self.eventHandler
            clientQueue.async { [weak self] in
                guard let self else {
                    close(clientSocket)
                    return
                }

                self.handleClient(clientSocket, eventHandler: eventHandler)
            }
        }
    }

    private func configureClientSocket(_ clientSocket: Int32) {
        let clientFlags = fcntl(clientSocket, F_GETFL)
        if clientFlags >= 0, fcntl(clientSocket, F_SETFL, clientFlags & ~O_NONBLOCK) != 0 {
            logger.warning("Failed to clear O_NONBLOCK on client socket: \(errno)")
        }
    }

    private func handleClient(_ clientSocket: Int32, eventHandler: HookEventHandler?) {
        defer { close(clientSocket) }

        guard let allData = readClientPayload(from: clientSocket), !allData.isEmpty else { return }

        guard let event = try? JSONDecoder().decode(HookEvent.self, from: allData) else {
            logger.warning("Failed to parse event")
            return
        }

        logEvent(event)
        eventHandler?(event)
    }

    private func readClientPayload(from clientSocket: Int32) -> Data? {
        var allData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let timeoutMilliseconds = Self.timeoutMilliseconds(for: clientReadTimeout)

        while true {
            switch waitForReadableClientSocket(clientSocket, timeoutMilliseconds: timeoutMilliseconds) {
            case .ready:
                break
            case .timedOut:
                logger.warning("Dropped idle client connection after read timeout")
                return nil
            case .failed(let errorCode):
                logger.warning("Failed waiting for client socket readability: \(errorCode)")
                return nil
            }

            let bytesRead = read(clientSocket, &buffer, buffer.count)

            if bytesRead > 0 {
                allData.append(contentsOf: buffer[0..<bytesRead])
                continue
            }

            if bytesRead == 0 {
                return allData
            }

            let readError = errno
            if readError == EINTR {
                continue
            }

            logger.warning("Failed to read client socket: \(readError)")
            return nil
        }
    }

    private func waitForReadableClientSocket(_ clientSocket: Int32, timeoutMilliseconds: Int32) -> SocketReadiness {
        var descriptor = pollfd(fd: clientSocket, events: Int16(POLLIN), revents: 0)

        while true {
            let pollResult = poll(&descriptor, 1, timeoutMilliseconds)

            if pollResult > 0 {
                if descriptor.revents & Int16(POLLNVAL) != 0 {
                    return .failed(EBADF)
                }

                if descriptor.revents & Int16(POLLERR) != 0 {
                    return .failed(EIO)
                }

                return .ready
            }

            if pollResult == 0 {
                return .timedOut
            }

            let pollError = errno
            if pollError == EINTR {
                continue
            }

            return .failed(pollError)
        }
    }

    private static func timeoutMilliseconds(for timeout: TimeInterval) -> Int32 {
        let clampedTimeout = max(timeout, 0)
        let milliseconds = Int((clampedTimeout * 1000).rounded(.up))
        return Int32(min(milliseconds, Int(Int32.max)))
    }

    private func logEvent(_ event: HookEvent) {
        switch event.event {
        case "SessionStart":
            logger.info("Session started")
        case "SessionEnd":
            logger.info("Session ended")
        case "PreToolUse":
            let tool = event.tool ?? "unknown"
            logger.info("Tool: \(tool, privacy: .public)")
        case "PostToolUse":
            let tool = event.tool ?? "unknown"
            let success = event.status != "error"
            logger.info("Result: \(success ? "✓" : "✗", privacy: .public) \(tool, privacy: .public)")
        case "Stop", "SubagentStop":
            logger.info("Done")
        default:
            break
        }
    }
}

private enum SocketReadiness {
    case ready
    case timedOut
    case failed(Int32)
}

private enum SocketPathPreparation {
    case ready
    case alreadyActive
    case failed(Int32)
}

private enum ExistingSocketState {
    case activeListener
    case stale
    case missing
    case failed(Int32)
}
