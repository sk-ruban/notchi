import Foundation

struct HookEvent: Decodable, Sendable {
    let sessionId: String
    let cwd: String
    let event: String
    let status: String
    let pid: Int?
    let tty: String?
    let tool: String?
    let toolInput: [String: AnyCodable]?
    let toolUseId: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd, event, status, pid, tty, tool
        case toolInput = "tool_input"
        case toolUseId = "tool_use_id"
    }
}

struct AnyCodable: Decodable, @unchecked Sendable {
    nonisolated(unsafe) let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot decode value"
            )
        }
    }
}
