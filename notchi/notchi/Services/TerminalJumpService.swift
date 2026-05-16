import AppKit

@MainActor
struct TerminalJumpService {
    static let shared = TerminalJumpService()

    private let openURL: (URL) -> Bool

    init(openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.openURL = openURL
    }

    @discardableResult
    func jump(to session: SessionData) -> Bool {
        guard let url = Self.codexDesktopThreadURL(for: session) else {
            return false
        }

        return openURL(url)
    }

    static func codexDesktopThreadURL(for session: SessionData) -> URL? {
        guard session.provider == .codex, session.codexOrigin == .desktop else {
            return nil
        }

        return codexDesktopThreadURL(threadId: session.rawSessionId)
    }

    nonisolated static func codexDesktopThreadURL(threadId: String) -> URL? {
        let trimmedThreadId = threadId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedThreadId.isEmpty,
              let encodedThreadId = trimmedThreadId.addingPercentEncoding(withAllowedCharacters: threadIDAllowedCharacters) else {
            return nil
        }

        return URL(string: "codex://threads/\(encodedThreadId)")
    }

    private nonisolated static let threadIDAllowedCharacters: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#[]@!$&'()*+,;=")
        return allowed
    }()
}
