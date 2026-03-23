import Foundation
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "SocketServer")

typealias HookEventHandler = @Sendable (HookEvent) -> Void

final class SocketServer {
    static let shared = SocketServer()
    static let socketPath = "/tmp/notchi.sock"

    /// IPs that have sent events via TCP. Updated on main thread.
    @MainActor private(set) var connectedRemotes: Set<String> = []
    @MainActor private(set) var blockedRemotes: Set<String> = []
    @MainActor private var remoteSessionIds: [String: Set<String>] = [:] // IP -> session IDs

    private var serverSocket: Int32 = -1
    private var tcpSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var tcpAcceptSource: DispatchSourceRead?
    private var eventHandler: HookEventHandler?
    private let queue = DispatchQueue(label: "com.ruban.notchi.socket", qos: .userInitiated)
    private let clientQueue = DispatchQueue(label: "com.ruban.notchi.socket.clients", qos: .userInitiated, attributes: .concurrent)
    private static let maxMessageSize = 65536 // 64KB max per message

    // Tailscale CGNAT range: 100.64.0.0/10
    private static let tailscaleBase: UInt32 = 0x64400000   // 100.64.0.0
    private static let tailscaleMask: UInt32 = 0xFFC00000   // /10

    private init() {}

    func start(onEvent: @escaping HookEventHandler) {
        let tcpEnabled = AppSettings.isRemoteTCPEnabled
        let tcpPort = AppSettings.remoteTCPPort
        queue.async { [weak self] in
            self?.eventHandler = onEvent
            self?.startUnixServer()
            if tcpEnabled {
                self?.startTCPServerInternal(port: tcpPort)
            }
        }
    }

    // MARK: - Unix Socket (local)

    private func startUnixServer() {
        guard serverSocket < 0 else { return }

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

        chmod(Self.socketPath, 0o700)

        guard listen(serverSocket, 10) == 0 else {
            logger.error("Failed to listen: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return
        }

        logger.info("Listening on \(Self.socketPath, privacy: .public)")

        acceptSource = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: queue)
        acceptSource?.setEventHandler { [weak self] in
            self?.drainAcceptQueue(from: self?.serverSocket ?? -1, isTCP: false)
        }
        acceptSource?.setCancelHandler { [weak self] in
            if let fd = self?.serverSocket, fd >= 0 {
                close(fd)
                self?.serverSocket = -1
            }
        }
        acceptSource?.resume()
    }

    // MARK: - TCP Socket (remote)

    func startTCPServer(port: UInt16) {
        queue.async { [weak self] in
            self?.startTCPServerInternal(port: port)
        }
    }

    private func startTCPServerInternal(port: UInt16) {
        stopTCPServerInternal()

        tcpSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard tcpSocket >= 0 else {
            logger.error("Failed to create TCP socket: \(errno)")
            return
        }

        var reuse: Int32 = 1
        setsockopt(tcpSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        let flags = fcntl(tcpSocket, F_GETFL)
        _ = fcntl(tcpSocket, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(tcpSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            logger.error("Failed to bind TCP socket on port \(port): \(errno)")
            close(tcpSocket)
            tcpSocket = -1
            return
        }

        guard listen(tcpSocket, 10) == 0 else {
            logger.error("Failed to listen on TCP: \(errno)")
            close(tcpSocket)
            tcpSocket = -1
            return
        }

        logger.info("TCP listening on port \(port, privacy: .public)")

        tcpAcceptSource = DispatchSource.makeReadSource(fileDescriptor: tcpSocket, queue: queue)
        tcpAcceptSource?.setEventHandler { [weak self] in
            self?.drainAcceptQueue(from: self?.tcpSocket ?? -1, isTCP: true)
        }
        tcpAcceptSource?.setCancelHandler { [weak self] in
            if let fd = self?.tcpSocket, fd >= 0 {
                close(fd)
                self?.tcpSocket = -1
            }
        }
        tcpAcceptSource?.resume()
    }

    func stopTCPServer() {
        queue.async { [weak self] in
            self?.stopTCPServerInternal()
        }
    }

    private func stopTCPServerInternal() {
        tcpAcceptSource?.cancel()
        tcpAcceptSource = nil
        if tcpSocket >= 0 {
            close(tcpSocket)
            tcpSocket = -1
        }
    }

    @MainActor func removeRemote(_ ip: String) {
        connectedRemotes.remove(ip)
        blockedRemotes.insert(ip)
        // End sessions from this remote
        if let sessionIds = remoteSessionIds.removeValue(forKey: ip) {
            let store = NotchiStateMachine.shared.sessionStore
            for sessionId in sessionIds {
                store.dismissSession(sessionId)
            }
        }
    }

    @MainActor func unblockRemote(_ ip: String) {
        blockedRemotes.remove(ip)
    }

    @MainActor func isBlocked(_ ip: String) -> Bool {
        blockedRemotes.contains(ip)
    }

    func stop() {
        queue.async { [weak self] in
            self?.acceptSource?.cancel()
            self?.acceptSource = nil
            unlink(Self.socketPath)
            self?.stopTCPServerInternal()
        }
    }

    // MARK: - Connection Handling

    private static func ipString(from addr: sockaddr_in) -> String? {
        let ip = UInt32(bigEndian: addr.sin_addr.s_addr)
        guard ip != 0 else { return nil }
        let a = (ip >> 24) & 0xFF
        let b = (ip >> 16) & 0xFF
        let c = (ip >> 8) & 0xFF
        let d = ip & 0xFF
        return "\(a).\(b).\(c).\(d)"
    }

    private static func isTailscaleAddress(_ addr: sockaddr_in) -> Bool {
        let ip = UInt32(bigEndian: addr.sin_addr.s_addr)
        return (ip & tailscaleMask) == tailscaleBase
    }

    private static func isAllowedAddress(_ addr: sockaddr_in) -> Bool {
        let ip = UInt32(bigEndian: addr.sin_addr.s_addr)
        // Allow localhost (127.0.0.0/8)
        if (ip & 0xFF000000) == 0x7F000000 { return true }
        // Allow Tailscale CGNAT range (100.64.0.0/10)
        if isTailscaleAddress(addr) { return true }
        // Allow private networks
        if (ip & 0xFFFF0000) == 0xC0A80000 { return true } // 192.168.0.0/16
        if (ip & 0xFF000000) == 0x0A000000 { return true } // 10.0.0.0/8
        if (ip & 0xFFF00000) == 0xAC100000 { return true } // 172.16.0.0/12
        return false
    }

    private func drainAcceptQueue(from listenSocket: Int32, isTCP: Bool) {
        while true {
            var clientStorage = sockaddr_storage()
            var addrLen = socklen_t(MemoryLayout<sockaddr_storage>.size)

            let clientSocket = withUnsafeMutablePointer(to: &clientStorage) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    accept(listenSocket, sockaddrPtr, &addrLen)
                }
            }
            guard clientSocket >= 0 else { break }

            // Extract sockaddr_in for TCP connections
            let clientAddr: sockaddr_in? = isTCP ? withUnsafePointer(to: &clientStorage) { ptr in
                ptr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            } : nil

            // For TCP connections, only allow localhost and private/Tailscale IPs
            if let addr = clientAddr, !Self.isAllowedAddress(addr) {
                logger.warning("Rejected TCP connection from non-Tailscale IP")
                close(clientSocket)
                continue
            }

            var nosigpipe: Int32 = 1
            setsockopt(clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

            // Set read timeout on client socket to prevent blocking
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(clientSocket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            // For TCP: track IP and check blocklist
            if isTCP, let addr = clientAddr, let ip = Self.ipString(from: addr) {
                let server = self
                let handler = eventHandler
                Task { @MainActor in
                    if server.isBlocked(ip) {
                        close(clientSocket)
                        return
                    }
                    server.connectedRemotes.insert(ip)
                    let capturedIP = ip
                    server.clientQueue.async {
                        let event = Self.handleClient(clientSocket, eventHandler: handler)
                        if let sessionId = event?.sessionId {
                            Task { @MainActor in
                                server.remoteSessionIds[capturedIP, default: []].insert(sessionId)
                            }
                        }
                    }
                }
                continue
            }

            // Handle client on concurrent queue to avoid blocking accept loop
            let handler = eventHandler
            clientQueue.async {
                Self.handleClient(clientSocket, eventHandler: handler)
            }
        }
    }

    @discardableResult
    private static func handleClient(_ clientSocket: Int32, eventHandler: HookEventHandler?) -> HookEvent? {
        defer { close(clientSocket) }

        var allData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while allData.count < maxMessageSize {
            let bytesRead = read(clientSocket, &buffer, buffer.count)
            if bytesRead > 0 {
                allData.append(contentsOf: buffer[0..<bytesRead])
            } else {
                break
            }
        }

        guard !allData.isEmpty else { return nil }

        guard let event = try? JSONDecoder().decode(HookEvent.self, from: allData) else {
            logger.warning("Failed to parse event")
            return nil
        }

        logEvent(event)
        eventHandler?(event)
        return event
    }

    private static func logEvent(_ event: HookEvent) {
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
