//
//  ConversationParser.swift
//  notchi
//
//  Parses Claude JSONL conversation files to extract assistant text messages.
//  Uses incremental parsing to only read new lines since last sync.
//

import Foundation

struct ParseResult {
    let messages: [AssistantMessage]
    let interrupted: Bool
}

actor ConversationParser {
    static let shared = ConversationParser()
    static let defaultProjectsRootPath = "\(NSHomeDirectory())/.claude/projects"
    static var projectsRootPath = defaultProjectsRootPath

    private var lastFileOffset: [String: UInt64] = [:]
    private var seenMessageIds: [String: Set<String>] = [:]

    private static let emptyResult = ParseResult(messages: [], interrupted: false)

    @MainActor
    static func configureProjectsRootPath(using claudeConfig: ClaudeConfigDirectoryResolution) {
        projectsRootPath = claudeConfig.projectsDirectoryURL.path
    }

    static func resolvedTranscriptPath(sessionId: String, cwd: String, transcriptPath: String?) -> String {
        if let trimmedPath = transcriptPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmedPath.isEmpty {
            return trimmedPath
        }

        return derivedTranscriptPath(sessionId: sessionId, cwd: cwd)
    }

    /// Parse only NEW assistant text messages since last call
    func parseIncremental(sessionId: String, transcriptPath: String) -> ParseResult {
        guard FileManager.default.fileExists(atPath: transcriptPath) else {
            return Self.emptyResult
        }

        guard let fileHandle = FileHandle(forReadingAtPath: transcriptPath) else {
            return Self.emptyResult
        }
        defer { try? fileHandle.close() }

        let fileSize: UInt64
        do {
            fileSize = try fileHandle.seekToEnd()
        } catch {
            return Self.emptyResult
        }

        var currentOffset = lastFileOffset[sessionId] ?? 0

        // File was truncated or reset - start fresh
        if fileSize < currentOffset {
            currentOffset = 0
            seenMessageIds[sessionId] = []
        }

        // No new content
        if fileSize == currentOffset {
            return Self.emptyResult
        }

        do {
            try fileHandle.seek(toOffset: currentOffset)
        } catch {
            return Self.emptyResult
        }

        guard let newData = try? fileHandle.readToEnd(),
              let newContent = String(data: newData, encoding: .utf8) else {
            return Self.emptyResult
        }

        var messages: [AssistantMessage] = []
        var interrupted = false
        var seen = seenMessageIds[sessionId] ?? []
        let lines = newContent.components(separatedBy: "\n")

        for line in lines where !line.isEmpty {
            if !interrupted && line.contains("\"type\":\"user\"") && line.contains("\"text\":\"[Request interrupted by user") {
                interrupted = true
            }

            // Skip non-assistant messages (interrupt detection above still runs)
            guard line.contains("\"type\":\"assistant\"") else { continue }

            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String,
                  type == "assistant",
                  let uuid = json["uuid"] as? String else {
                continue
            }

            // Skip if already seen
            if seen.contains(uuid) { continue }

            // Skip meta messages
            if json["isMeta"] as? Bool == true { continue }

            guard let messageDict = json["message"] as? [String: Any] else { continue }

            // Skip CLI-generated transcript entries that are not real model replies.
            if messageDict["model"] as? String == "<synthetic>" { continue }

            // Parse timestamp
            let timestamp: Date
            if let timestampStr = json["timestamp"] as? String {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                timestamp = formatter.date(from: timestampStr) ?? Date()
            } else {
                timestamp = Date()
            }

            // Extract text content
            var textParts: [String] = []

            if let content = messageDict["content"] as? String {
                // Skip system-like messages
                if !content.hasPrefix("<command-name>") &&
                   !content.hasPrefix("[Request interrupted") {
                    textParts.append(content)
                }
            } else if let contentArray = messageDict["content"] as? [[String: Any]] {
                for block in contentArray {
                    guard let blockType = block["type"] as? String else { continue }

                    if blockType == "text", let text = block["text"] as? String {
                        // Skip system-like messages
                        if !text.hasPrefix("[Request interrupted") {
                            textParts.append(text)
                        }
                    }
                    // Skip tool_use and thinking blocks - we only want text
                }
            }

            // Only add if we have non-empty text content
            let fullText = textParts.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fullText.isEmpty else { continue }

            // Only mark as seen AFTER passing all filters
            seen.insert(uuid)
            messages.append(AssistantMessage(
                id: uuid,
                text: fullText,
                timestamp: timestamp
            ))
        }

        lastFileOffset[sessionId] = fileSize
        seenMessageIds[sessionId] = seen

        return ParseResult(messages: messages, interrupted: interrupted)
    }

    /// Reset parsing state for a session
    func resetState(for sessionId: String) {
        lastFileOffset.removeValue(forKey: sessionId)
        seenMessageIds.removeValue(forKey: sessionId)
    }

    /// Mark current file position as "already processed"
    /// Call this when a new prompt is submitted to ignore previous content
    func markCurrentPosition(sessionId: String, transcriptPath: String) {
        guard let fileHandle = FileHandle(forReadingAtPath: transcriptPath) else {
            lastFileOffset[sessionId] = 0
            seenMessageIds[sessionId] = []
            return
        }
        defer { try? fileHandle.close() }

        let fileSize = (try? fileHandle.seekToEnd()) ?? 0
        lastFileOffset[sessionId] = fileSize
        seenMessageIds[sessionId] = []
    }

    private static func derivedTranscriptPath(sessionId: String, cwd: String) -> String {
        let projectDir = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        return "\(projectsRootPath)/\(projectDir)/\(sessionId).jsonl"
    }
}
