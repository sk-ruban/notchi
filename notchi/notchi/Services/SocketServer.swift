import Foundation
import os.log

nonisolated private let logger = Logger(subsystem: "com.ruban.notchi", category: "SocketServer")

typealias AgentHookEnvelopeHandler = @Sendable (AgentHookEnvelope) -> Data?

nonisolated protocol AgentHookEventSource: AnyObject, Sendable {
    nonisolated func start(onEvent: @escaping AgentHookEnvelopeHandler)
    nonisolated func stop()
}

// WHY: SocketServer owns its synchronization via serverQueue/clientQueue rather
// than the main actor, so it should not inherit the project's default UI
// isolation.
nonisolated final class SocketServer: AgentHookEventSource, @unchecked Sendable {
    static let socketPath = resolvedSocketPath(home: FileManager.default.homeDirectoryForCurrentUser.path)
    static let shared = SocketServer(socketPath: socketPath, clientReadTimeout: 0.5)
    private static let socketDirectoryPermissions: mode_t = 0o700
    private static let groupAndOtherPermissions: mode_t = 0o077
    private static let maxSocketPathLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    static func resolvedSocketPath(home: String) -> String {
        let preferred = (home as NSString).appendingPathComponent("Library/Application Support/Notchi/notchi.sock")
        return fitsInSocketAddress(preferred)
            ? preferred
            : (home as NSString).appendingPathComponent(".notchi/notchi.sock")
    }

    private static func fitsInSocketAddress(_ path: String) -> Bool {
        path.utf8.count <= maxSocketPathLength
    }
    private static let startRetryDelay: DispatchTimeInterval = .milliseconds(250)
    private static let maxStartRetryAttempts = 8

    private let socketPath: String
    private let clientReadTimeout: TimeInterval
    private var serverSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var eventHandler: AgentHookEnvelopeHandler?
    private var pendingStartRetry: DispatchWorkItem?
    private let serverQueue = DispatchQueue(label: "com.ruban.notchi.socket.server", qos: .userInitiated)
    private let clientQueue = DispatchQueue(label: "com.ruban.notchi.socket.client", qos: .userInitiated, attributes: .concurrent)

    init(socketPath: String = SocketServer.socketPath, clientReadTimeout: TimeInterval = 0.5) {
        self.socketPath = socketPath
        self.clientReadTimeout = clientReadTimeout
    }

    func start(onEvent: @escaping AgentHookEnvelopeHandler) {
        serverQueue.async { [weak self] in
            self?.startServer(
                onEvent: onEvent,
                retryAttemptsRemaining: Self.maxStartRetryAttempts
            )
        }
    }

    private func startServer(
        onEvent: @escaping AgentHookEnvelopeHandler,
        retryAttemptsRemaining: Int
    ) {
        guard serverSocket < 0 else { return }

        guard Self.fitsInSocketAddress(socketPath) else {
            logger.error("Socket path is \(self.socketPath.utf8.count) bytes, longer than a Unix socket address allows")
            return
        }

        guard prepareSocketDirectory() else { return }

        switch prepareSocketPathForBinding() {
        case .ready:
            // WHY: a previous retry may already be queued when the old listener
            // finally disappears; cancel it once we successfully own the path.
            pendingStartRetry?.cancel()
            pendingStartRetry = nil
            break
        case .alreadyActive:
            scheduleStartRetry(
                onEvent: onEvent,
                retryAttemptsRemaining: retryAttemptsRemaining
            )
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

    private func prepareSocketDirectory() -> Bool {
        let directory = (socketPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: Self.socketDirectoryPermissions]
            )
        } catch {
            logger.error("Failed to create socket directory: \(error.localizedDescription)")
            return false
        }

        var info = stat()
        guard lstat(directory, &info) == 0 else {
            logger.error("Failed to inspect socket directory: \(errno)")
            return false
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            logger.error("Refusing a socket directory that is not a directory owned by this user")
            return false
        }
        if info.st_mode & Self.groupAndOtherPermissions != 0, chmod(directory, Self.socketDirectoryPermissions) != 0 {
            logger.error("Failed to restrict socket directory permissions: \(errno)")
            return false
        }
        return true
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
        pendingStartRetry?.cancel()
        pendingStartRetry = nil

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

        var suppressSigPipe: Int32 = 1
        let suppressSigPipeLength = socklen_t(MemoryLayout.size(ofValue: suppressSigPipe))
        let suppressResult = withUnsafePointer(to: &suppressSigPipe) { pointer in
            setsockopt(
                clientSocket,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                pointer,
                suppressSigPipeLength
            )
        }
        if suppressResult != 0 {
            logger.warning("Failed to suppress SIGPIPE on client socket: \(errno)")
        }
    }

    private func handleClient(_ clientSocket: Int32, eventHandler: AgentHookEnvelopeHandler?) {
        defer { close(clientSocket) }

        guard let allData = readClientPayload(from: clientSocket), !allData.isEmpty else { return }

        guard let event = try? JSONDecoder().decode(AgentHookEnvelope.self, from: allData) else {
            logger.warning("Failed to parse event")
            return
        }

        guard let response = eventHandler?(event), !response.isEmpty else { return }
        writeResponse(response, to: clientSocket)
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

    private func writeResponse(_ response: Data, to clientSocket: Int32) {
        response.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return
            }

            var totalBytesWritten = 0
            while totalBytesWritten < response.count {
                let bytesWritten = write(
                    clientSocket,
                    baseAddress.advanced(by: totalBytesWritten),
                    response.count - totalBytesWritten
                )

                if bytesWritten > 0 {
                    totalBytesWritten += bytesWritten
                    continue
                }

                if bytesWritten < 0, errno == EINTR {
                    continue
                }

                logger.warning("Failed to write client response: \(errno)")
                return
            }
        }
    }

    private func scheduleStartRetry(
        onEvent: @escaping AgentHookEnvelopeHandler,
        retryAttemptsRemaining: Int
    ) {
        guard retryAttemptsRemaining > 0 else {
            logger.error(
                "Socket listener remained busy at \(self.socketPath, privacy: .public); giving up after retries"
            )
            return
        }

        logger.warning(
            "Socket listener already active at \(self.socketPath, privacy: .public); retrying startup (\(retryAttemptsRemaining - 1) attempts left)"
        )

        pendingStartRetry?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.startServer(
                onEvent: onEvent,
                retryAttemptsRemaining: retryAttemptsRemaining - 1
            )
        }
        pendingStartRetry = workItem
        serverQueue.asyncAfter(
            deadline: .now() + Self.startRetryDelay,
            execute: workItem
        )
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
