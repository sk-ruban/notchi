import Foundation

enum NormalizedAgentEvent: String, CaseIterable, Codable, Sendable {
    case userPromptSubmitted = "UserPromptSubmit"
    case sessionStarted = "SessionStart"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case permissionRequest = "PermissionRequest"
    case preCompact = "PreCompact"
    case stop = "Stop"
    case subagentStop = "SubagentStop"
    case sessionEnded = "SessionEnd"

    nonisolated static func claudeEvent(named rawValue: String) -> Self? {
        Self(rawValue: rawValue)
    }

    nonisolated static func codexEvent(named rawValue: String) -> Self? {
        switch rawValue {
        case "SessionStart":
            .sessionStarted
        case "UserPromptSubmit":
            .userPromptSubmitted
        case "Stop":
            .stop
        default:
            nil
        }
    }
}

enum CodexOrigin: String, Codable, Sendable {
    case cli
    case desktop
}

struct AgentHookEnvelope: Decodable, Sendable {
    let provider: AgentProvider
    let sessionId: String
    let transcriptPath: String?
    let cwd: String
    let event: String
    let status: String
    let tool: String?
    let toolInput: [String: AnyCodable]?
    let toolUseId: String?
    let userPrompt: String?
    let permissionMode: String?
    let interactive: Bool?
    let claudeProcessId: Int?
    let codexProcessId: Int?
    let codexOrigin: CodexOrigin?
    let hasAttachments: Bool?

    enum CodingKeys: String, CodingKey {
        case provider
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd, event, status, tool
        case toolInput = "tool_input"
        case toolUseId = "tool_use_id"
        case userPrompt = "user_prompt"
        case permissionMode = "permission_mode"
        case interactive
        case claudeProcessId = "claude_process_id"
        case codexProcessId = "codex_process_id"
        case codexOrigin = "codex_origin"
        case hasAttachments = "has_attachments"
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        provider = try container.decodeIfPresent(AgentProvider.self, forKey: .provider) ?? .claude
        sessionId = try container.decode(String.self, forKey: .sessionId)
        transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
        cwd = try container.decode(String.self, forKey: .cwd)
        event = try container.decode(String.self, forKey: .event)
        status = try container.decode(String.self, forKey: .status)
        tool = try container.decodeIfPresent(String.self, forKey: .tool)
        toolInput = try container.decodeIfPresent([String: AnyCodable].self, forKey: .toolInput)
        toolUseId = try container.decodeIfPresent(String.self, forKey: .toolUseId)
        userPrompt = try container.decodeIfPresent(String.self, forKey: .userPrompt)
        permissionMode = try container.decodeIfPresent(String.self, forKey: .permissionMode)
        interactive = try container.decodeIfPresent(Bool.self, forKey: .interactive)
        claudeProcessId = try container.decodeIfPresent(Int.self, forKey: .claudeProcessId)
        codexProcessId = try container.decodeIfPresent(Int.self, forKey: .codexProcessId)
        codexOrigin = try container.decodeIfPresent(CodexOrigin.self, forKey: .codexOrigin)
        hasAttachments = try container.decodeIfPresent(Bool.self, forKey: .hasAttachments)
    }
}

struct HookEvent: Sendable {
    let provider: AgentProvider
    let sessionKey: ProviderSessionKey
    let transcriptPath: String?
    let cwd: String
    let event: NormalizedAgentEvent
    let status: String
    let tool: String?
    let toolInput: [String: AnyCodable]?
    let toolUseId: String?
    let userPrompt: String?
    let userPromptHasAttachments: Bool
    let permissionMode: String?
    let interactive: Bool?
    let claudeProcessId: Int?
    let codexProcessId: Int?
    let codexOrigin: CodexOrigin?

    nonisolated var sessionId: String {
        sessionKey.stableId
    }

    nonisolated var rawSessionId: String {
        sessionKey.rawSessionId
    }

    nonisolated init(
        provider: AgentProvider = .claude,
        rawSessionId: String,
        transcriptPath: String?,
        cwd: String,
        event: NormalizedAgentEvent,
        status: String,
        tool: String? = nil,
        toolInput: [String: AnyCodable]? = nil,
        toolUseId: String? = nil,
        userPrompt: String? = nil,
        userPromptHasAttachments: Bool = false,
        permissionMode: String? = nil,
        interactive: Bool? = nil,
        claudeProcessId: Int? = nil,
        codexProcessId: Int? = nil,
        codexOrigin: CodexOrigin? = nil
    ) {
        self.provider = provider
        self.sessionKey = ProviderSessionKey(provider: provider, rawSessionId: rawSessionId)
        self.transcriptPath = transcriptPath
        self.cwd = cwd
        self.event = event
        self.status = status
        self.tool = tool
        self.toolInput = toolInput
        self.toolUseId = toolUseId
        self.userPrompt = userPrompt
        self.userPromptHasAttachments = userPromptHasAttachments
        self.permissionMode = permissionMode
        self.interactive = interactive
        self.claudeProcessId = claudeProcessId
        self.codexProcessId = codexProcessId
        self.codexOrigin = codexOrigin
    }
}

nonisolated struct AnyCodable: Decodable, @unchecked Sendable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

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
