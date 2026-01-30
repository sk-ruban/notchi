import Foundation
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "SocketServer")

typealias HookEventHandler = @Sendable (HookEvent) -> Void

final class SocketServer {
    static let shared = SocketServer()
    static let socketPath = "/tmp/notchi.sock"

    private var serverSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var eventHandler: HookEventHandler?
    private let queue = DispatchQueue(label: "com.ruban.notchi.socket", qos: .userInitiated)

    private init() {}

    func start(onEvent: @escaping HookEventHandler) {
        queue.async { [weak self] in
            self?.startServer(onEvent: onEvent)
        }
    }

    private func startServer(onEvent: @escaping HookEventHandler) {
        guard serverSocket < 0 else { return }

        eventHandler = onEvent

        unlink(Self.socketPath)

        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            logger.error("Failed to create socket: \(errno)")
            return
        }

        let flags = fcntl(serverSocket, F_GETFL)
        _ = fcntl(serverSocket, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        Self.socketPath.withCString { ptr in
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

        chmod(Self.socketPath, 0o777)

        guard listen(serverSocket, 10) == 0 else {
            logger.error("Failed to listen: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return
        }

        logger.info("Listening on \(Self.socketPath, privacy: .public)")

        acceptSource = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: queue)
        acceptSource?.setEventHandler { [weak self] in
            self?.acceptConnection()
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
        acceptSource?.cancel()
        acceptSource = nil
        unlink(Self.socketPath)
    }

    private func acceptConnection() {
        let clientSocket = accept(serverSocket, nil, nil)
        guard clientSocket >= 0 else { return }

        var nosigpipe: Int32 = 1
        setsockopt(clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

        handleClient(clientSocket)
    }

    private func handleClient(_ clientSocket: Int32) {
        defer { close(clientSocket) }

        var allData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let bytesRead = read(clientSocket, &buffer, buffer.count)
            if bytesRead > 0 {
                allData.append(contentsOf: buffer[0..<bytesRead])
            } else {
                break
            }
        }

        guard !allData.isEmpty else { return }

        guard let event = try? JSONDecoder().decode(HookEvent.self, from: allData) else {
            logger.warning("Failed to parse event: \(String(data: allData, encoding: .utf8) ?? "?", privacy: .public)")
            return
        }

        logEvent(event)
        eventHandler?(event)
    }

    private func logEvent(_ event: HookEvent) {
        let sessionPrefix = String(event.sessionId.prefix(8))

        switch event.event {
        case "SessionStart":
            logger.info("[Notchi] Session started: \(sessionPrefix, privacy: .public)")
        case "SessionEnd":
            logger.info("[Notchi] Session ended: \(sessionPrefix, privacy: .public)")
        case "PreToolUse":
            let tool = event.tool ?? "unknown"
            logger.info("[Notchi] Tool use: \(tool, privacy: .public)")
        case "PostToolUse":
            let tool = event.tool ?? "unknown"
            let success = event.status != "error"
            logger.info("[Notchi] Tool result: \(success ? "success" : "error", privacy: .public) (\(tool, privacy: .public))")
        default:
            logger.debug("[Notchi] Event: \(event.event, privacy: .public) status: \(event.status, privacy: .public)")
        }
    }
}
