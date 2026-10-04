import Foundation

enum ClaudeSessionNameReader {
    // `claude -n` leaves nameSource unset, so skip generated sources instead of requiring "user".
    private nonisolated static let generatedNameSources: Set<String> = ["derived", "auto", "collision"]

    nonisolated static func name(forProcessId processId: Int, sessionId: String) -> String? {
        name(
            forProcessId: processId,
            sessionId: sessionId,
            in: ClaudeConfigDirectoryResolver.resolve().directoryURL
        )
    }

    nonisolated static func name(forProcessId processId: Int, sessionId: String, in configDirectory: URL) -> String? {
        let url = configDirectory
            .appendingPathComponent("sessions")
            .appendingPathComponent("\(processId).json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["sessionId"] as? String == sessionId,
              !generatedNameSources.contains(json["nameSource"] as? String ?? "") else {
            return nil
        }
        return json["name"] as? String
    }
}
