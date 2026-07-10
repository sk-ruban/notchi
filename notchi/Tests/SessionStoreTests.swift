import XCTest
@testable import notchi

@MainActor
final class SessionStoreTests: XCTestCase {
    override func tearDown() async throws {
        let sessionKeys = Array(SessionStore.shared.sessions.keys)
        sessionKeys.forEach { SessionStore.shared.dismissSession($0) }
        SessionStore.shared.resetTestingHooks()
        try await super.tearDown()
    }

    func testUserPromptSubmitClearsPreviousTurnToolEventsAndAssistantMessages() {
        let sessionId = "turn-reset-\(UUID().uuidString)"
        let store = SessionStore.shared

        let session = store.process(makeEvent(
            sessionId: sessionId,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "first"
        ))

        _ = store.process(makeEvent(
            sessionId: sessionId,
            event: .preToolUse,
            status: "processing",
            tool: "Read",
            toolUseId: "tool-1"
        ))
        session.recordAssistantMessages([
            AssistantMessage(id: UUID().uuidString, text: "Old reply", timestamp: Date())
        ])

        XCTAssertEqual(session.recentEvents.count, 1)
        XCTAssertEqual(session.recentAssistantMessages.count, 1)

        _ = store.process(makeEvent(
            sessionId: sessionId,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "second"
        ))

        XCTAssertTrue(session.recentEvents.isEmpty)
        XCTAssertTrue(session.recentAssistantMessages.isEmpty)
        XCTAssertEqual(session.lastUserPrompt, "second")
        XCTAssertFalse(session.lastUserPromptHasAttachments)
    }

    func testUserPromptSubmitTracksAttachmentStateSeparatelyFromPromptText() {
        let sessionId = "attached-prompt-\(UUID().uuidString)"
        let store = SessionStore.shared

        let session = store.process(makeEvent(
            sessionId: sessionId,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "testing",
            userPromptHasAttachments: true
        ))

        XCTAssertEqual(session.lastUserPrompt, "testing")
        XCTAssertTrue(session.lastUserPromptHasAttachments)

        _ = store.process(makeEvent(
            sessionId: sessionId,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "plain",
            userPromptHasAttachments: false
        ))

        XCTAssertEqual(session.lastUserPrompt, "plain")
        XCTAssertFalse(session.lastUserPromptHasAttachments)
    }

    func testAttachmentOnlyUserPromptStillRecordsPromptSubmission() {
        let store = SessionStore.shared

        let session = store.process(makeEvent(
            sessionId: "attachment-only-\(UUID().uuidString)",
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: nil,
            userPromptHasAttachments: true
        ))

        XCTAssertNil(session.lastUserPrompt)
        XCTAssertTrue(session.lastUserPromptHasAttachments)
        XCTAssertNotNil(session.promptSubmitTime)
    }

    func testPermissionRequestForAskUserQuestionUsesProvidedOptions() {
        let store = SessionStore.shared
        let session = store.process(makeEvent(
            sessionId: "ask-user-question-permission-\(UUID().uuidString)",
            event: .permissionRequest,
            status: "waiting_for_input",
            tool: "AskUserQuestion",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "question": "What do you mean by \"toll permissions prompt\"?",
                        "header": "Intent",
                        "options": [
                            [
                                "label": "Trigger a tool permission prompt",
                                "description": "Run a command that requires your approval",
                            ],
                            [
                                "label": "Configure tool permissions",
                                "description": "Edit Claude settings",
                            ],
                            [
                                "label": "Chat about this",
                            ],
                        ],
                    ],
                ]),
            ]
        ))

        XCTAssertEqual(session.task, .waiting)
        XCTAssertEqual(session.pendingQuestions.count, 1)
        XCTAssertEqual(session.pendingQuestions[0].header, "Intent")
        XCTAssertEqual(
            session.pendingQuestions[0].question,
            "What do you mean by \"toll permissions prompt\"?"
        )
        XCTAssertEqual(
            session.pendingQuestions[0].options.map(\.label),
            [
                "Trigger a tool permission prompt",
                "Configure tool permissions",
                "Chat about this",
                "Type something",
            ]
        )
        XCTAssertEqual(
            session.pendingQuestions[0].options.map(\.description),
            [
                "Run a command that requires your approval",
                "Edit Claude settings",
                nil,
                nil,
            ]
        )
    }

    func testPreToolUseForAskUserQuestionUsesProvidedOptionsAndFreeTextChoice() {
        let store = SessionStore.shared
        let session = store.process(makeEvent(
            sessionId: "ask-user-question-pretool-\(UUID().uuidString)",
            event: .preToolUse,
            status: "running_tool",
            tool: "AskUserQuestion",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "question": "Which path?",
                        "header": "Path",
                        "options": [
                            ["label": "Fast"],
                            ["label": "Careful"],
                        ],
                    ],
                ]),
            ]
        ))

        XCTAssertEqual(session.task, .waiting)
        XCTAssertEqual(session.pendingQuestions.count, 1)
        XCTAssertEqual(
            session.pendingQuestions[0].options.map(\.label),
            ["Fast", "Careful", PendingQuestion.freeTextOptionLabel]
        )
    }

    func testAskUserQuestionDoesNotDuplicateProvidedFreeTextOption() {
        let store = SessionStore.shared
        let session = store.process(makeEvent(
            sessionId: "ask-user-question-free-text-dedupe-\(UUID().uuidString)",
            event: .preToolUse,
            status: "running_tool",
            tool: "AskUserQuestion",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "question": "Which path?",
                        "options": [
                            ["label": "Fast"],
                            ["label": "Type something"],
                        ],
                    ],
                ]),
            ]
        ))

        XCTAssertEqual(
            session.pendingQuestions[0].options.map(\.label),
            ["Fast", "Type something"]
        )
    }

    func testAnswerPendingQuestionSubmitsClaudePreToolUseResponse() async throws {
        let store = SessionStore.shared
        let sessionId = "ask-user-question-answer-\(UUID().uuidString)"
        let requestId = HookInteractionRequest.id(
            provider: .claude,
            rawSessionId: sessionId,
            hookEventName: NormalizedAgentEvent.preToolUse.rawValue,
            toolUseId: "tool-ask"
        )
        let session = store.process(makeEvent(
            sessionId: sessionId,
            event: .preToolUse,
            status: "running_tool",
            tool: "AskUserQuestion",
            toolUseId: "tool-ask",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "question": "Which path?",
                        "options": [
                            ["label": "Fast"],
                            ["label": "Careful"],
                        ],
                    ],
                ]),
            ],
            interactionRequestId: requestId
        ))
        let responseTask = Task.detached {
            HookInteractionResponseBroker.shared.waitForResponse(
                requestId: requestId,
                timeout: 1
            )
        }
        let responseWaiterRegistered = await waitUntil(timeout: 1) {
            HookInteractionResponseBroker.shared.isWaitingForResponse(requestId: requestId)
        }
        XCTAssertTrue(responseWaiterRegistered)

        XCTAssertTrue(store.answerPendingQuestions(
            in: session.sessionKey,
            selectedOptionIndexesByQuestion: [0: 1]
        ))

        let maybeResponseData = await responseTask.value
        let responseData = try XCTUnwrap(maybeResponseData)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let hookOutput = try XCTUnwrap(response["hookSpecificOutput"] as? [String: Any])
        let updatedInput = try XCTUnwrap(hookOutput["updatedInput"] as? [String: Any])
        let answers = try XCTUnwrap(updatedInput["answers"] as? [String: String])
        let questions = try XCTUnwrap(updatedInput["questions"] as? [[String: Any]])

        XCTAssertEqual(hookOutput["hookEventName"] as? String, "PreToolUse")
        XCTAssertEqual(hookOutput["permissionDecision"] as? String, "allow")
        XCTAssertEqual(answers, ["Which path?": "Careful"])
        XCTAssertEqual(questions.first?["question"] as? String, "Which path?")
        XCTAssertEqual((questions.first?["options"] as? [[String: Any]])?.count, 2)
        XCTAssertTrue(session.pendingQuestions.isEmpty)
    }

    func testAnswerPendingQuestionsSubmitsAllAnswersTogether() async throws {
        let store = SessionStore.shared
        let sessionId = "ask-user-question-multi-answer-\(UUID().uuidString)"
        let requestId = HookInteractionRequest.id(
            provider: .claude,
            rawSessionId: sessionId,
            hookEventName: NormalizedAgentEvent.preToolUse.rawValue,
            toolUseId: "tool-ask"
        )
        let session = store.process(makeEvent(
            sessionId: sessionId,
            event: .preToolUse,
            status: "running_tool",
            tool: "AskUserQuestion",
            toolUseId: "tool-ask",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "question": "Which path?",
                        "options": [
                            ["label": "Fast"],
                            ["label": "Careful"],
                        ],
                    ],
                    [
                        "question": "Which target?",
                        "options": [
                            ["label": "Production"],
                            ["label": "Staging"],
                        ],
                    ],
                ]),
            ],
            interactionRequestId: requestId
        ))
        let responseTask = Task.detached {
            HookInteractionResponseBroker.shared.waitForResponse(
                requestId: requestId,
                timeout: 1
            )
        }
        let responseWaiterRegistered = await waitUntil(timeout: 1) {
            HookInteractionResponseBroker.shared.isWaitingForResponse(requestId: requestId)
        }
        XCTAssertTrue(responseWaiterRegistered)

        XCTAssertFalse(store.answerPendingQuestions(
            in: session.sessionKey,
            selectedOptionIndexesByQuestion: [0: 1]
        ))
        XCTAssertFalse(session.pendingQuestions.isEmpty)

        XCTAssertTrue(store.answerPendingQuestions(
            in: session.sessionKey,
            selectedOptionIndexesByQuestion: [0: 1, 1: 0]
        ))

        let maybeResponseData = await responseTask.value
        let responseData = try XCTUnwrap(maybeResponseData)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let hookOutput = try XCTUnwrap(response["hookSpecificOutput"] as? [String: Any])
        let updatedInput = try XCTUnwrap(hookOutput["updatedInput"] as? [String: Any])
        let answers = try XCTUnwrap(updatedInput["answers"] as? [String: String])
        let questions = try XCTUnwrap(updatedInput["questions"] as? [[String: Any]])

        XCTAssertEqual(hookOutput["hookEventName"] as? String, "PreToolUse")
        XCTAssertEqual(hookOutput["permissionDecision"] as? String, "allow")
        XCTAssertEqual(answers, [
            "Which path?": "Careful",
            "Which target?": "Production",
        ])
        XCTAssertEqual(questions.count, 2)
        XCTAssertTrue(session.pendingQuestions.isEmpty)
    }

    func testAnswerPendingQuestionsSubmitsCustomTextAnswers() async throws {
        let store = SessionStore.shared
        let sessionId = "ask-user-question-custom-answer-\(UUID().uuidString)"
        let requestId = HookInteractionRequest.id(
            provider: .claude,
            rawSessionId: sessionId,
            hookEventName: NormalizedAgentEvent.preToolUse.rawValue,
            toolUseId: "tool-ask"
        )
        let session = store.process(makeEvent(
            sessionId: sessionId,
            event: .preToolUse,
            status: "running_tool",
            tool: "AskUserQuestion",
            toolUseId: "tool-ask",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "question": "Which path?",
                        "options": [
                            ["label": "Fast"],
                            ["label": "Careful"],
                        ],
                    ],
                    [
                        "question": "Which target?",
                        "options": [
                            ["label": "Production"],
                            ["label": "Staging"],
                        ],
                    ],
                ]),
            ],
            interactionRequestId: requestId
        ))
        let responseTask = Task.detached {
            HookInteractionResponseBroker.shared.waitForResponse(
                requestId: requestId,
                timeout: 1
            )
        }
        let responseWaiterRegistered = await waitUntil(timeout: 1) {
            HookInteractionResponseBroker.shared.isWaitingForResponse(requestId: requestId)
        }
        XCTAssertTrue(responseWaiterRegistered)

        XCTAssertTrue(store.answerPendingQuestions(
            in: session.sessionKey,
            selectedOptionIndexesByQuestion: [0: 1],
            customAnswersByQuestion: [1: "  Local sandbox  "]
        ))

        let maybeResponseData = await responseTask.value
        let responseData = try XCTUnwrap(maybeResponseData)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let hookOutput = try XCTUnwrap(response["hookSpecificOutput"] as? [String: Any])
        let updatedInput = try XCTUnwrap(hookOutput["updatedInput"] as? [String: Any])
        let answers = try XCTUnwrap(updatedInput["answers"] as? [String: String])

        XCTAssertEqual(answers, [
            "Which path?": "Careful",
            "Which target?": "Local sandbox",
        ])
        XCTAssertTrue(session.pendingQuestions.isEmpty)
    }

    func testCancelPendingQuestionSubmitsClaudePreToolUseDenyResponse() async throws {
        let store = SessionStore.shared
        let sessionId = "ask-user-question-cancel-\(UUID().uuidString)"
        let requestId = HookInteractionRequest.id(
            provider: .claude,
            rawSessionId: sessionId,
            hookEventName: NormalizedAgentEvent.preToolUse.rawValue,
            toolUseId: "tool-ask"
        )
        let session = store.process(makeEvent(
            sessionId: sessionId,
            event: .preToolUse,
            status: "running_tool",
            tool: "AskUserQuestion",
            toolUseId: "tool-ask",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "question": "Which path?",
                        "options": [
                            ["label": "Fast"],
                        ],
                    ],
                ]),
            ],
            interactionRequestId: requestId
        ))
        let responseTask = Task.detached {
            HookInteractionResponseBroker.shared.waitForResponse(
                requestId: requestId,
                timeout: 1
            )
        }
        let responseWaiterRegistered = await waitUntil(timeout: 1) {
            HookInteractionResponseBroker.shared.isWaitingForResponse(requestId: requestId)
        }
        XCTAssertTrue(responseWaiterRegistered)

        XCTAssertTrue(store.cancelPendingQuestion(in: session.sessionKey))

        let maybeResponseData = await responseTask.value
        let responseData = try XCTUnwrap(maybeResponseData)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let hookOutput = try XCTUnwrap(response["hookSpecificOutput"] as? [String: Any])

        XCTAssertEqual(hookOutput["hookEventName"] as? String, "PreToolUse")
        XCTAssertEqual(hookOutput["permissionDecision"] as? String, "deny")
        XCTAssertEqual(hookOutput["permissionDecisionReason"] as? String, "Question canceled by user.")
        XCTAssertNil(hookOutput["updatedInput"])
        XCTAssertTrue(session.pendingQuestions.isEmpty)
    }

    func testCancelPendingQuestionWithoutResponseContextClearsLocalQuestion() {
        let store = SessionStore.shared
        let session = store.process(makeEvent(
            sessionId: "permission-question-cancel-\(UUID().uuidString)",
            event: .permissionRequest,
            status: "waiting_for_input",
            tool: "Bash",
            toolInput: [
                "command": AnyCodable("sysctl -n hw.ncpu"),
                "description": AnyCodable("Print CPU core count"),
            ]
        ))

        XCTAssertFalse(session.pendingQuestions.isEmpty)
        XCTAssertTrue(store.cancelPendingQuestion(in: session.sessionKey))
        XCTAssertTrue(session.pendingQuestions.isEmpty)
        XCTAssertEqual(session.task, .idle)
    }

    func testCodexPermissionRequestUsesJustificationAsQuestionText() {
        let store = SessionStore.shared
        let session = store.process(makeEvent(
            sessionId: "codex-permission-question-\(UUID().uuidString)",
            provider: .codex,
            event: .permissionRequest,
            status: "waiting_for_input",
            tool: "Bash",
            toolInput: [
                "command": AnyCodable("psd"),
                "justification": AnyCodable("Do you want to allow a permission-request test command for `psd` in the current workspace?"),
            ]
        ))

        XCTAssertEqual(
            session.pendingQuestions.first?.question,
            "Do you want to allow a permission-request test command for `psd` in the current workspace?"
        )
        XCTAssertEqual(session.pendingQuestions.first?.options.map(\.label), ["Yes", "No"])
        XCTAssertNil(session.pendingQuestionResponseContext)
    }

    func testAnswerPermissionRequestSubmitsAllowResponse() async throws {
        let store = SessionStore.shared
        let sessionId = "permission-request-allow-\(UUID().uuidString)"
        let requestId = HookInteractionRequest.id(
            provider: .claude,
            rawSessionId: sessionId,
            hookEventName: NormalizedAgentEvent.permissionRequest.rawValue,
            toolUseId: "permission-\(UUID().uuidString)"
        )
        let session = store.process(makeEvent(
            sessionId: sessionId,
            event: .permissionRequest,
            status: "waiting_for_input",
            tool: "Bash",
            toolInput: [
                "command": AnyCodable("npm test"),
                "description": AnyCodable("Run tests"),
            ],
            interactionRequestId: requestId
        ))
        XCTAssertEqual(session.pendingQuestions.first?.options.map(\.label), ["Yes", "No"])

        let responseTask = Task.detached {
            HookInteractionResponseBroker.shared.waitForResponse(
                requestId: requestId,
                timeout: 1
            )
        }
        let responseWaiterRegistered = await waitUntil(timeout: 1) {
            HookInteractionResponseBroker.shared.isWaitingForResponse(requestId: requestId)
        }
        XCTAssertTrue(responseWaiterRegistered)

        XCTAssertTrue(store.answerPendingQuestions(
            in: session.sessionKey,
            selectedOptionIndexesByQuestion: [0: 0]
        ))

        let awaitedResponseData = await responseTask.value
        let responseData = try XCTUnwrap(awaitedResponseData)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let hookOutput = try XCTUnwrap(response["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hookOutput["decision"] as? [String: Any])
        let updatedInput = try XCTUnwrap(decision["updatedInput"] as? [String: Any])

        XCTAssertEqual(hookOutput["hookEventName"] as? String, "PermissionRequest")
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        XCTAssertEqual(updatedInput["command"] as? String, "npm test")
        XCTAssertNil(decision["updatedPermissions"])
        XCTAssertTrue(session.pendingQuestions.isEmpty)
        XCTAssertEqual(session.task, .working)
    }

    func testAnswerPermissionRequestCanSubmitRememberedAllowResponse() async throws {
        let store = SessionStore.shared
        let sessionId = "permission-request-remember-\(UUID().uuidString)"
        let requestId = HookInteractionRequest.id(
            provider: .claude,
            rawSessionId: sessionId,
            hookEventName: NormalizedAgentEvent.permissionRequest.rawValue,
            toolUseId: "permission-\(UUID().uuidString)"
        )
        let session = store.process(makeEvent(
            sessionId: sessionId,
            event: .permissionRequest,
            status: "waiting_for_input",
            tool: "Bash",
            toolInput: [
                "command": AnyCodable("npm test"),
            ],
            permissionSuggestions: [
                AnyCodable([
                    "type": "addRules",
                    "rules": [["toolName": "Bash", "ruleContent": "npm test"]],
                    "behavior": "allow",
                    "destination": "localSettings",
                ]),
            ],
            interactionRequestId: requestId
        ))
        XCTAssertEqual(
            session.pendingQuestions.first?.options.map(\.label),
            ["Yes", "Yes, and don't ask again", "No"]
        )

        let responseTask = Task.detached {
            HookInteractionResponseBroker.shared.waitForResponse(
                requestId: requestId,
                timeout: 1
            )
        }
        let responseWaiterRegistered = await waitUntil(timeout: 1) {
            HookInteractionResponseBroker.shared.isWaitingForResponse(requestId: requestId)
        }
        XCTAssertTrue(responseWaiterRegistered)

        XCTAssertTrue(store.answerPendingQuestions(
            in: session.sessionKey,
            selectedOptionIndexesByQuestion: [0: 1]
        ))

        let awaitedResponseData = await responseTask.value
        let responseData = try XCTUnwrap(awaitedResponseData)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let hookOutput = try XCTUnwrap(response["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hookOutput["decision"] as? [String: Any])
        let updatedPermissions = try XCTUnwrap(decision["updatedPermissions"] as? [[String: Any]])
        let permissionUpdate = try XCTUnwrap(updatedPermissions.first)
        let rules = try XCTUnwrap(permissionUpdate["rules"] as? [[String: Any]])

        XCTAssertEqual(decision["behavior"] as? String, "allow")
        XCTAssertEqual(permissionUpdate["destination"] as? String, "localSettings")
        XCTAssertEqual(rules.first?["toolName"] as? String, "Bash")
        XCTAssertEqual(rules.first?["ruleContent"] as? String, "npm test")
        XCTAssertTrue(session.pendingQuestions.isEmpty)
    }

    func testAnswerPermissionRequestSubmitsDenyResponse() async throws {
        let store = SessionStore.shared
        let sessionId = "permission-request-deny-\(UUID().uuidString)"
        let requestId = HookInteractionRequest.id(
            provider: .claude,
            rawSessionId: sessionId,
            hookEventName: NormalizedAgentEvent.permissionRequest.rawValue,
            toolUseId: "permission-\(UUID().uuidString)"
        )
        let session = store.process(makeEvent(
            sessionId: sessionId,
            event: .permissionRequest,
            status: "waiting_for_input",
            tool: "Bash",
            toolInput: [
                "command": AnyCodable("rm -rf node_modules"),
            ],
            interactionRequestId: requestId
        ))
        let responseTask = Task.detached {
            HookInteractionResponseBroker.shared.waitForResponse(
                requestId: requestId,
                timeout: 1
            )
        }
        let responseWaiterRegistered = await waitUntil(timeout: 1) {
            HookInteractionResponseBroker.shared.isWaitingForResponse(requestId: requestId)
        }
        XCTAssertTrue(responseWaiterRegistered)

        XCTAssertTrue(store.answerPendingQuestions(
            in: session.sessionKey,
            selectedOptionIndexesByQuestion: [0: 1]
        ))

        let awaitedResponseData = await responseTask.value
        let responseData = try XCTUnwrap(awaitedResponseData)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let hookOutput = try XCTUnwrap(response["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hookOutput["decision"] as? [String: Any])

        XCTAssertEqual(decision["behavior"] as? String, "deny")
        XCTAssertEqual(decision["message"] as? String, "User denied this action.")
        XCTAssertEqual(decision["interrupt"] as? Bool, false)
        XCTAssertTrue(session.pendingQuestions.isEmpty)
    }

    func testCancelPendingPermissionRequestSubmitsDenyResponse() async throws {
        let store = SessionStore.shared
        let sessionId = "permission-request-cancel-\(UUID().uuidString)"
        let requestId = HookInteractionRequest.id(
            provider: .claude,
            rawSessionId: sessionId,
            hookEventName: NormalizedAgentEvent.permissionRequest.rawValue,
            toolUseId: "permission-\(UUID().uuidString)"
        )
        let session = store.process(makeEvent(
            sessionId: sessionId,
            event: .permissionRequest,
            status: "waiting_for_input",
            tool: "Bash",
            toolInput: [
                "command": AnyCodable("npm test"),
            ],
            interactionRequestId: requestId
        ))
        let responseTask = Task.detached {
            HookInteractionResponseBroker.shared.waitForResponse(
                requestId: requestId,
                timeout: 1
            )
        }
        let responseWaiterRegistered = await waitUntil(timeout: 1) {
            HookInteractionResponseBroker.shared.isWaitingForResponse(requestId: requestId)
        }
        XCTAssertTrue(responseWaiterRegistered)

        XCTAssertTrue(store.cancelPendingQuestion(in: session.sessionKey))

        let awaitedResponseData = await responseTask.value
        let responseData = try XCTUnwrap(awaitedResponseData)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let hookOutput = try XCTUnwrap(response["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hookOutput["decision"] as? [String: Any])

        XCTAssertEqual(decision["behavior"] as? String, "deny")
        XCTAssertEqual(decision["message"] as? String, "User denied this action.")
        XCTAssertEqual(decision["interrupt"] as? Bool, false)
        XCTAssertTrue(session.pendingQuestions.isEmpty)
        XCTAssertEqual(session.task, .working)
    }

    func testRememberedPermissionResponseRequiresPermissionSuggestion() {
        XCTAssertNil(HookInteractionResponse.makePermissionRequestResponse(
            decision: .allowAndRemember,
            hookEventName: NormalizedAgentEvent.permissionRequest.rawValue,
            toolInput: nil,
            permissionSuggestions: nil
        ))
    }

    func testAskUserQuestionPermissionRequestResponseUsesDecisionShapeAndPreservesNulls() throws {
        let responseData = try XCTUnwrap(HookInteractionResponse.makeAskUserQuestionResponse(
            hookEventName: NormalizedAgentEvent.permissionRequest.rawValue,
            toolInput: [
                "metadata": AnyCodable([
                    "nullValue": NSNull(),
                    "list": [NSNull(), "kept"],
                ]),
            ],
            answers: ["Which path?": "Careful"]
        ))
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let hookOutput = try XCTUnwrap(response["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hookOutput["decision"] as? [String: Any])
        let updatedInput = try XCTUnwrap(decision["updatedInput"] as? [String: Any])
        let answers = try XCTUnwrap(updatedInput["answers"] as? [String: String])
        let metadata = try XCTUnwrap(updatedInput["metadata"] as? [String: Any])
        let list = try XCTUnwrap(metadata["list"] as? [Any])

        XCTAssertEqual(hookOutput["hookEventName"] as? String, "PermissionRequest")
        XCTAssertNil(hookOutput["permissionDecision"])
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        XCTAssertEqual(answers, ["Which path?": "Careful"])
        XCTAssertTrue(metadata["nullValue"] is NSNull)
        XCTAssertTrue(list.first is NSNull)
        XCTAssertEqual(list.last as? String, "kept")
    }

    func testAskUserQuestionPermissionRequestCancellationUsesDecisionDenyShape() throws {
        let responseData = try XCTUnwrap(HookInteractionResponse.makeAskUserQuestionCancellationResponse(
            hookEventName: NormalizedAgentEvent.permissionRequest.rawValue
        ))
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let hookOutput = try XCTUnwrap(response["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hookOutput["decision"] as? [String: Any])

        XCTAssertEqual(hookOutput["hookEventName"] as? String, "PermissionRequest")
        XCTAssertNil(hookOutput["permissionDecision"])
        XCTAssertEqual(decision["behavior"] as? String, "deny")
        XCTAssertEqual(decision["message"] as? String, "Question canceled by user.")
        XCTAssertEqual(decision["interrupt"] as? Bool, false)
    }

    func testAnswerPendingQuestionClearsStaleQuestionWhenBrokerAlreadyTimedOut() {
        let store = SessionStore.shared
        let sessionId = "ask-user-question-stale-\(UUID().uuidString)"
        let session = store.process(makeEvent(
            sessionId: sessionId,
            event: .preToolUse,
            status: "running_tool",
            tool: "AskUserQuestion",
            toolUseId: "tool-ask",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "question": "Which path?",
                        "options": [
                            ["label": "Fast"],
                        ],
                    ],
                ]),
            ],
            interactionRequestId: HookInteractionRequest.id(
                provider: .claude,
                rawSessionId: sessionId,
                hookEventName: NormalizedAgentEvent.preToolUse.rawValue,
                toolUseId: "tool-ask"
            )
        ))

        XCTAssertFalse(store.answerPendingQuestions(
            in: session.sessionKey,
            selectedOptionIndexesByQuestion: [0: 0]
        ))
        XCTAssertTrue(session.pendingQuestions.isEmpty)
        XCTAssertEqual(session.task, .idle)
    }

    func testFreeTextPendingQuestionOptionDoesNotSubmitResponse() {
        let store = SessionStore.shared
        let sessionId = "ask-user-question-free-text-no-submit-\(UUID().uuidString)"
        let requestId = HookInteractionRequest.id(
            provider: .claude,
            rawSessionId: sessionId,
            hookEventName: NormalizedAgentEvent.preToolUse.rawValue,
            toolUseId: "tool-ask"
        )
        let session = store.process(makeEvent(
            sessionId: sessionId,
            event: .preToolUse,
            status: "running_tool",
            tool: "AskUserQuestion",
            toolUseId: "tool-ask",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "question": "Which path?",
                        "options": [
                            ["label": "Fast"],
                        ],
                    ],
                ]),
            ],
            interactionRequestId: requestId
        ))

        XCTAssertFalse(store.answerPendingQuestions(
            in: session.sessionKey,
            selectedOptionIndexesByQuestion: [0: 1]
        ))
        XCTAssertFalse(session.pendingQuestions.isEmpty)
    }

    func testPreToolUseAskUserQuestionDoesNotProduceInteractionId() throws {
        func envelope(toolUseId: String?) throws -> AgentHookEnvelope {
            var payload: [String: Any] = [
                "provider": "claude",
                "session_id": "ask-user-question-tui-first",
                "cwd": "/tmp",
                "event": "PreToolUse",
                "status": "running_tool",
                "tool": "AskUserQuestion",
                "tool_input": [
                    "questions": [
                        [
                            "question": "Which path?",
                            "options": [["label": "Fast"]],
                        ],
                    ],
                ],
            ]
            if let toolUseId {
                payload["tool_use_id"] = toolUseId
            }
            let data = try JSONSerialization.data(withJSONObject: payload)
            return try JSONDecoder().decode(AgentHookEnvelope.self, from: data)
        }

        XCTAssertNil(HookInteractionRequest.id(for: try envelope(toolUseId: nil)))
        XCTAssertNil(HookInteractionRequest.id(for: try envelope(toolUseId: "toolu_present")))
    }

    func testPermissionRequestInteractionIdDoesNotRequireToolUseId() throws {
        let payload: [String: Any] = [
            "provider": "claude",
            "session_id": "permission-request-id",
            "cwd": "/tmp",
            "event": "PermissionRequest",
            "status": "waiting_for_input",
            "tool": "Bash",
            "tool_input": [
                "command": "npm test",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let envelope = try JSONDecoder().decode(AgentHookEnvelope.self, from: data)

        let requestId = try XCTUnwrap(HookInteractionRequest.id(for: envelope))

        XCTAssertTrue(requestId.hasPrefix("claude:permission-request-id:PermissionRequest:"))
    }

    func testDisplaySessionNumbersRenumberAfterDismissal() {
        let store = SessionStore.shared
        let cwd = "/tmp/notchi"

        let first = store.process(makeEvent(
            sessionId: "renumber-1-\(UUID().uuidString)",
            cwd: cwd,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "one"
        ))
        let second = store.process(makeEvent(
            sessionId: "renumber-2-\(UUID().uuidString)",
            cwd: cwd,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "two"
        ))
        let third = store.process(makeEvent(
            sessionId: "renumber-3-\(UUID().uuidString)",
            cwd: cwd,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "three"
        ))

        XCTAssertEqual(store.displaySessionNumber(for: first), 1)
        XCTAssertEqual(store.displaySessionNumber(for: second), 2)
        XCTAssertEqual(store.displaySessionNumber(for: third), 3)

        store.dismissSession(first.sessionKey)
        store.dismissSession(second.sessionKey)

        XCTAssertEqual(store.displaySessionNumber(for: third), 1)
        XCTAssertEqual(store.displaySessionLabel(for: third), "notchi #1")
        XCTAssertEqual(store.displayTitle(for: third), "notchi #1 - three")
    }

    func testMixedProvidersShareProjectNumberingAndAvoidIdentityCollisions() {
        let store = SessionStore.shared
        let cwd = "/tmp/notchi"

        let claude = store.process(makeEvent(
            sessionId: "shared-session",
            provider: .claude,
            cwd: cwd,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "claude"
        ))
        let codex = store.process(makeEvent(
            sessionId: "shared-session",
            provider: .codex,
            cwd: cwd,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "codex"
        ))

        XCTAssertNotEqual(claude.id, codex.id)
        XCTAssertEqual(store.displaySessionNumber(for: claude), 1)
        XCTAssertEqual(store.displaySessionNumber(for: codex), 2)
        XCTAssertEqual(store.displaySessionLabel(for: claude), "notchi #1")
        XCTAssertEqual(store.displaySessionLabel(for: codex), "notchi #2")
        XCTAssertNotNil(store.sessions[claude.sessionKey])
        XCTAssertNotNil(store.sessions[codex.sessionKey])
    }

    func testCodexDisplayTitlePrefersCodexThreadTitle() {
        let store = SessionStore.shared
        store.setCodexMetadataResolverForTesting { transcriptPath in
            transcriptPath == "/tmp/rollout.jsonl"
                ? CodexThreadMetadata(title: "Review uncommitted changes", archived: false)
                : nil
        }

        let session = store.process(makeEvent(
            sessionId: "codex-title-\(UUID().uuidString)",
            provider: .codex,
            cwd: "/tmp/notchi",
            transcriptPath: "/tmp/rollout.jsonl",
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "raw prompt"
        ))

        XCTAssertEqual(session.codexTranscriptPath, "/tmp/rollout.jsonl")
        XCTAssertFalse(session.codexArchived)
        XCTAssertNil(session.codexTitle)

        _ = store.refreshCodexThreadMetadataForTesting()

        XCTAssertEqual(session.codexTitle, "Review uncommitted changes")
        XCTAssertEqual(store.displayTitle(for: session), "notchi #1 - Review uncommitted changes")
    }

    func testRefreshCodexThreadMetadataReturnsArchivedSessionsAndUpdatesTitle() {
        let store = SessionStore.shared
        let transcriptPath = "/tmp/archived-rollout.jsonl"
        store.setCodexMetadataResolverForTesting { _ in
            CodexThreadMetadata(title: "Initial title", archived: false)
        }

        let session = store.process(makeEvent(
            sessionId: "codex-archived-title-\(UUID().uuidString)",
            provider: .codex,
            cwd: "/tmp/notchi",
            transcriptPath: transcriptPath,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "raw prompt"
        ))

        store.setCodexMetadataResolverForTesting { path in
            path == transcriptPath
                ? CodexThreadMetadata(title: "Archived title", archived: true)
                : nil
        }

        let archivedSessions = store.refreshCodexThreadMetadataForTesting()

        XCTAssertEqual(archivedSessions.map(\.sessionKey), [session.sessionKey])
        XCTAssertEqual(session.codexTitle, "Archived title")
        XCTAssertTrue(session.codexArchived)
    }

    func testCodexThreadMetadataResolverMatchesLiteralRolloutPathFromSQLiteOutput() {
        let separator = "\u{1F}"
        let transcriptPath = "/tmp/notchi'; DROP TABLE threads; --/rollout.jsonl"
        let output = [
            ["other", "/tmp/other.jsonl", "4F74686572", "0"].joined(separator: separator),
            ["thread-1", transcriptPath, "526576696577", "0"].joined(separator: separator),
        ].joined(separator: "\n")

        let metadata = CodexThreadMetadataResolver.metadata(
            fromSQLiteOutput: output,
            matchingTranscriptPath: transcriptPath
        )

        XCTAssertEqual(metadata, CodexThreadMetadata(title: "Review", archived: false))
    }

    func testCodexThreadMetadataResolverFallsBackToThreadIdFromTranscriptFilename() {
        let separator = "\u{1F}"
        let threadId = "123e4567-e89b-12d3-a456-426614174000"
        let transcriptPath = "/tmp/rollout-\(threadId).jsonl"
        let output = [
            threadId,
            "/tmp/renamed-rollout.jsonl",
            "4172636869766564",
            "1",
        ].joined(separator: separator)

        let metadata = CodexThreadMetadataResolver.metadata(
            fromSQLiteOutput: output,
            matchingTranscriptPath: transcriptPath
        )

        XCTAssertEqual(metadata, CodexThreadMetadata(title: "Archived", archived: true))
    }

    func testCodexThreadMetadataResolverQueryFiltersByEscapedRolloutPathAndThreadId() {
        let threadId = "123e4567-e89b-12d3-a456-426614174000"
        let transcriptPath = "/tmp/it's-rollout-\(threadId).jsonl"

        let query = CodexThreadMetadataResolver.threadsQuery(matchingTranscriptPaths: [transcriptPath])

        XCTAssertEqual(
            query,
            "SELECT id, rollout_path, hex(title), archived FROM threads " +
                "WHERE rollout_path IN ('/tmp/it''s-rollout-\(threadId).jsonl') OR id IN ('\(threadId)');"
        )
    }

    func testCodexThreadMetadataResolverQueryWithoutDerivableThreadIdFiltersByPathOnly() {
        let query = CodexThreadMetadataResolver.threadsQuery(matchingTranscriptPaths: ["/tmp/rollout.jsonl"])

        XCTAssertEqual(
            query,
            "SELECT id, rollout_path, hex(title), archived FROM threads " +
                "WHERE rollout_path IN ('/tmp/rollout.jsonl');"
        )
    }

    func testCodexThreadMetadataResolverQueryFiltersAllRequestedPathsInOneStatement() {
        let threadId = "123e4567-e89b-12d3-a456-426614174000"
        let withThreadId = "/tmp/rollout-\(threadId).jsonl"
        let withoutThreadId = "/tmp/plain-rollout.jsonl"

        let query = CodexThreadMetadataResolver.threadsQuery(
            matchingTranscriptPaths: [withThreadId, withoutThreadId]
        )

        XCTAssertEqual(
            query,
            "SELECT id, rollout_path, hex(title), archived FROM threads " +
                "WHERE rollout_path IN ('/tmp/rollout-\(threadId).jsonl', '/tmp/plain-rollout.jsonl') " +
                "OR id IN ('\(threadId)');"
        )
    }

    func testCodexThreadMetadataResolverMatchesMultiplePathsFromSingleSQLiteOutput() {
        let separator = "\u{1F}"
        let reviewPath = "/tmp/review-rollout.jsonl"
        let archivedPath = "/tmp/archived-rollout.jsonl"
        let unmatchedPath = "/tmp/missing-rollout.jsonl"
        let output = [
            ["thread-1", reviewPath, "526576696577", "0"].joined(separator: separator),
            ["thread-2", archivedPath, "4172636869766564", "1"].joined(separator: separator),
        ].joined(separator: "\n")

        let metadataByPath = CodexThreadMetadataResolver.metadata(
            fromSQLiteOutput: output,
            matchingTranscriptPaths: [reviewPath, archivedPath, unmatchedPath]
        )

        XCTAssertEqual(metadataByPath, [
            reviewPath: CodexThreadMetadata(title: "Review", archived: false),
            archivedPath: CodexThreadMetadata(title: "Archived", archived: true),
        ])
    }

    func testRefreshCodexThreadMetadataResolvesAllSessionsInOneBatch() {
        final class BatchRecorder: @unchecked Sendable {
            var batches: [[String]] = []
        }

        let store = SessionStore.shared
        let firstPath = "/tmp/batch-first-rollout.jsonl"
        let secondPath = "/tmp/batch-second-rollout.jsonl"

        let firstSession = store.process(makeEvent(
            sessionId: "codex-batch-first-\(UUID().uuidString)",
            provider: .codex,
            cwd: "/tmp/notchi",
            transcriptPath: firstPath,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "first"
        ))
        let secondSession = store.process(makeEvent(
            sessionId: "codex-batch-second-\(UUID().uuidString)",
            provider: .codex,
            cwd: "/tmp/notchi",
            transcriptPath: secondPath,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "second"
        ))

        let recorder = BatchRecorder()
        store.setCodexMetadataBatchResolverForTesting { transcriptPaths in
            recorder.batches.append(transcriptPaths)
            return [
                firstPath: CodexThreadMetadata(title: "First title", archived: false),
                secondPath: CodexThreadMetadata(title: "Second title", archived: false),
            ]
        }

        _ = store.refreshCodexThreadMetadataForTesting()

        XCTAssertEqual(recorder.batches.count, 1)
        XCTAssertEqual(Set(recorder.batches.first ?? []), [firstPath, secondPath])
        XCTAssertEqual(firstSession.codexTitle, "First title")
        XCTAssertEqual(secondSession.codexTitle, "Second title")
    }

    func testCodexCompactionSignalResolverParsesLatestTokenLimitLogRow() {
        let separator = "\u{1F}"
        let threadId = "11111111-1111-1111-1111-111111111111"
        let timestamp: TimeInterval = 1_775_000_000
        let nanoseconds = 250_000_000
        let body = """
        session_loop{thread_id=thread}:turn:run_turn: post sampling token usage turn_id=turn total_usage_tokens=256300 estimated_token_count=Some(177642) auto_compact_limit=244800 token_limit_reached=true model_needs_follow_up=true has_pending_input=false needs_follow_up=true
        """
        let output = "\(threadId)\(separator)\(Int(timestamp))\(separator)\(nanoseconds)\(separator)\(body)"

        let signal = CodexCompactionSignalResolver.latestSignals(fromSQLiteOutput: output)[threadId]

        XCTAssertEqual(signal?.observedAt, Date(timeIntervalSince1970: timestamp + 0.25))
        XCTAssertEqual(signal?.totalUsageTokens, 256300)
        XCTAssertEqual(signal?.estimatedTokenCount, 177642)
        XCTAssertEqual(signal?.autoCompactLimit, 244800)
        XCTAssertEqual(signal?.tokenLimitReached, true)
    }

    func testCodexCompactionSignalResolverDoesNotMatchPrefixedFields() {
        let separator = "\u{1F}"
        let threadId = "11111111-1111-1111-1111-111111111111"
        let timestamp: TimeInterval = 1_775_000_000
        let body = """
        session_loop{thread_id=thread}:turn:run_turn: post sampling token usage turn_id=turn prefix_total_usage_tokens=1 total_usage_tokens=256300 prefix_auto_compact_limit=2 auto_compact_limit=244800 prefix_token_limit_reached=false token_limit_reached=true
        """
        let output = "\(threadId)\(separator)\(Int(timestamp))\(separator)0\(separator)\(body)"

        let signal = CodexCompactionSignalResolver.latestSignals(fromSQLiteOutput: output)[threadId]

        XCTAssertEqual(signal?.totalUsageTokens, 256_300)
        XCTAssertEqual(signal?.autoCompactLimit, 244_800)
        XCTAssertEqual(signal?.tokenLimitReached, true)
    }

    func testCodexCompactionSignalResolverParsesBatchedThreadRows() {
        let separator = "\u{1F}"
        let firstThreadId = "11111111-1111-1111-1111-111111111111"
        let secondThreadId = "22222222-2222-2222-2222-222222222222"
        let firstBody = """
        session_loop{thread_id=\(firstThreadId)}:turn:run_turn: post sampling token usage turn_id=turn total_usage_tokens=256300 estimated_token_count=Some(177642) auto_compact_limit=244800 token_limit_reached=true
        """
        let secondBody = """
        session_loop{thread_id=\(secondThreadId)}:turn:run_turn: post sampling token usage turn_id=turn total_usage_tokens=20000 estimated_token_count=Some(18000) auto_compact_limit=244800 token_limit_reached=false
        """
        let output = [
            "\(firstThreadId)\(separator)1775000000\(separator)250000000\(separator)\(firstBody)",
            "\(secondThreadId)\(separator)1775000001\(separator)0\(separator)\(secondBody)",
        ].joined(separator: "\n")

        let signals = CodexCompactionSignalResolver.latestSignals(fromSQLiteOutput: output)

        XCTAssertEqual(signals[firstThreadId]?.tokenLimitReached, true)
        XCTAssertEqual(signals[firstThreadId]?.totalUsageTokens, 256_300)
        XCTAssertEqual(signals[secondThreadId]?.tokenLimitReached, false)
        XCTAssertEqual(signals[secondThreadId]?.totalUsageTokens, 20_000)
    }

    func testCodexCompactionSignalResolverIgnoresMalformedThreadIdsFromSQLiteOutput() {
        let separator = "\u{1F}"
        let body = """
        session_loop{thread_id=not-a-uuid}:turn:run_turn: post sampling token usage turn_id=turn total_usage_tokens=256300 estimated_token_count=Some(177642) auto_compact_limit=244800 token_limit_reached=true
        """
        let output = "not-a-uuid\(separator)1775000000\(separator)0\(separator)\(body)"

        let signals = CodexCompactionSignalResolver.latestSignals(fromSQLiteOutput: output)

        XCTAssertTrue(signals.isEmpty)
    }

    func testRefreshCodexCompactionSignalsMarksCurrentProcessingCodexSessionCompacting() {
        let store = SessionStore.shared
        let sessionId = "codex-compact-\(UUID().uuidString)"
        let transcriptPath = "/tmp/compact-rollout.jsonl"
        let session = store.process(makeEvent(
            sessionId: sessionId,
            provider: .codex,
            cwd: "/tmp/notchi",
            transcriptPath: transcriptPath,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "hello"
        ))
        let observedAt = Date()
        store.setCodexCompactionSignalResolverForTesting { threadIds in
            guard threadIds.contains(sessionId) else { return [:] }
            return [
                sessionId: CodexCompactionSignal(
                    observedAt: observedAt,
                    totalUsageTokens: 256_300,
                    estimatedTokenCount: 177_642,
                    autoCompactLimit: 244_800,
                    tokenLimitReached: true
                )
            ]
        }

        store.refreshCodexCompactionSignalsForTesting()

        XCTAssertEqual(session.codexCompactionSignal?.totalUsageTokens, 256_300)
        XCTAssertEqual(session.task, .compacting)
    }

    func testActiveCodexCompactionSignalPreventsWorkingEventFlicker() {
        let store = SessionStore.shared
        let sessionId = "codex-compact-no-flicker-\(UUID().uuidString)"
        let transcriptPath = "/tmp/compact-no-flicker-rollout.jsonl"
        let session = store.process(makeEvent(
            sessionId: sessionId,
            provider: .codex,
            cwd: "/tmp/notchi",
            transcriptPath: transcriptPath,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "hello"
        ))
        let compactingSignal = CodexCompactionSignal(
            observedAt: Date(),
            totalUsageTokens: 256_300,
            estimatedTokenCount: 177_642,
            autoCompactLimit: 244_800,
            tokenLimitReached: true
        )
        store.setCodexCompactionSignalResolverForTesting { threadIds in
            threadIds.contains(sessionId) ? [sessionId: compactingSignal] : [:]
        }

        store.refreshCodexCompactionSignalsForTesting()
        XCTAssertEqual(session.task, .compacting)

        _ = store.process(makeEvent(
            sessionId: sessionId,
            provider: .codex,
            cwd: "/tmp/notchi",
            transcriptPath: transcriptPath,
            event: .postToolUse,
            status: "processing",
            tool: "Bash",
            toolUseId: "tool-1"
        ))

        XCTAssertEqual(session.task, .compacting)
    }

    func testStaleCodexCompactionSignalDoesNotOverrideNewPrompt() {
        let store = SessionStore.shared
        let sessionId = "codex-stale-compact-\(UUID().uuidString)"
        let transcriptPath = "/tmp/stale-compact-rollout.jsonl"
        store.setCodexCompactionSignalResolverForTesting { threadIds in
            guard threadIds.contains(sessionId) else { return [:] }
            return [
                sessionId: CodexCompactionSignal(
                    observedAt: Date(timeIntervalSince1970: 1),
                    totalUsageTokens: 256_300,
                    estimatedTokenCount: nil,
                    autoCompactLimit: 244_800,
                    tokenLimitReached: true
                )
            ]
        }

        let session = store.process(makeEvent(
            sessionId: sessionId,
            provider: .codex,
            cwd: "/tmp/notchi",
            transcriptPath: transcriptPath,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "new prompt"
        ))

        store.refreshCodexCompactionSignalsForTesting()

        XCTAssertNil(session.codexCompactionSignal)
        XCTAssertEqual(session.task, .working)
    }

    func testNewerNonLimitCodexCompactionSignalReturnsCompactingSessionToWorking() {
        let store = SessionStore.shared
        let sessionId = "codex-compact-clears-\(UUID().uuidString)"
        let transcriptPath = "/tmp/compact-clears-rollout.jsonl"
        let session = store.process(makeEvent(
            sessionId: sessionId,
            provider: .codex,
            cwd: "/tmp/notchi",
            transcriptPath: transcriptPath,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "hello"
        ))
        let compactingSignal = CodexCompactionSignal(
            observedAt: Date(),
            totalUsageTokens: 256_300,
            estimatedTokenCount: 177_642,
            autoCompactLimit: 244_800,
            tokenLimitReached: true
        )
        store.setCodexCompactionSignalResolverForTesting { threadIds in
            threadIds.contains(sessionId) ? [sessionId: compactingSignal] : [:]
        }

        store.refreshCodexCompactionSignalsForTesting()
        XCTAssertEqual(session.task, .compacting)

        let workingSignal = CodexCompactionSignal(
            observedAt: Date(),
            totalUsageTokens: 20_000,
            estimatedTokenCount: 18_000,
            autoCompactLimit: 244_800,
            tokenLimitReached: false
        )
        store.setCodexCompactionSignalResolverForTesting { threadIds in
            threadIds.contains(sessionId) ? [sessionId: workingSignal] : [:]
        }

        store.refreshCodexCompactionSignalsForTesting()

        XCTAssertEqual(session.task, .working)
    }

    func testPinnedSessionHoldsWhileOtherSessionsHaveNoNewerActivity() {
        let selected = SessionData(sessionId: "pinned-claude", provider: .claude, cwd: "/tmp/project")
        let selectedAt = Date(timeIntervalSince1970: 1_000)

        let pinned = SessionStore.pinnedSession(
            selected: selected,
            selectedAt: selectedAt,
            otherSessionActivities: [
                Date(timeIntervalSince1970: 900),
                Date(timeIntervalSince1970: 1_000),
            ]
        )

        XCTAssertEqual(pinned?.id, selected.id)
    }

    func testPinnedSessionReleasesWhenAnotherSessionActsAfterSelection() {
        let selected = SessionData(sessionId: "pinned-claude", provider: .claude, cwd: "/tmp/project")

        let pinned = SessionStore.pinnedSession(
            selected: selected,
            selectedAt: Date(timeIntervalSince1970: 1_000),
            otherSessionActivities: [Date(timeIntervalSince1970: 1_001)]
        )

        XCTAssertNil(pinned)
    }

    func testPinnedSessionRequiresBothSelectionAndTimestamp() {
        let session = SessionData(sessionId: "pinned-claude", provider: .claude, cwd: "/tmp/project")

        XCTAssertNil(
            SessionStore.pinnedSession(
                selected: nil,
                selectedAt: Date(timeIntervalSince1970: 1_000),
                otherSessionActivities: []
            )
        )
        XCTAssertNil(
            SessionStore.pinnedSession(
                selected: session,
                selectedAt: nil,
                otherSessionActivities: []
            )
        )
    }

    func testSelectionTimestampFollowsSelectAndClear() {
        let store = SessionStore.shared
        let session = store.process(makeEvent(
            sessionId: "select-stamp-\(UUID().uuidString)",
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "hello"
        ))

        store.selectSession(session.sessionKey)
        XCTAssertNotNil(store.selectedAt)

        store.clearSelectedSession()
        XCTAssertNil(store.selectedAt)
    }

    func testLatestSessionHonorsSelectionPinUntilAnotherSessionActs() {
        let store = SessionStore.shared
        let first = store.process(makeEvent(
            sessionId: "pin-first-\(UUID().uuidString)",
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "first"
        ))
        let secondSessionId = "pin-second-\(UUID().uuidString)"
        let second = store.process(makeEvent(
            sessionId: secondSessionId,
            provider: .codex,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "second"
        ))

        XCTAssertEqual(store.latestSession(excluding: nil)?.id, second.id)

        store.selectSession(first.sessionKey)
        XCTAssertEqual(store.latestSession(excluding: nil)?.id, first.id)

        _ = store.process(makeEvent(
            sessionId: secondSessionId,
            provider: .codex,
            event: .userPromptSubmitted,
            status: "processing",
            userPrompt: "second again"
        ))
        XCTAssertEqual(store.latestSession(excluding: nil)?.id, second.id)
    }

    private func makeEvent(
        sessionId: String,
        provider: AgentProvider = .claude,
        cwd: String = "/tmp",
        transcriptPath: String? = nil,
        event: NormalizedAgentEvent,
        status: String,
        userPrompt: String? = nil,
        userPromptHasAttachments: Bool = false,
        tool: String? = nil,
        toolUseId: String? = nil,
        toolInput: [String: AnyCodable]? = nil,
        permissionSuggestions: [AnyCodable]? = nil,
        interactionRequestId: String? = nil
    ) -> HookEvent {
        HookEvent(
            provider: provider,
            rawSessionId: sessionId,
            transcriptPath: transcriptPath,
            cwd: cwd,
            event: event,
            status: status,
            tool: tool,
            toolInput: toolInput,
            toolUseId: toolUseId,
            userPrompt: userPrompt,
            userPromptHasAttachments: userPromptHasAttachments,
            permissionMode: nil,
            permissionSuggestions: permissionSuggestions,
            interactive: true,
            interactionRequestId: interactionRequestId
        )
    }

    private func waitUntil(
        timeout: TimeInterval,
        pollIntervalNanoseconds: UInt64 = 10_000_000,
        condition: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if condition() {
                return true
            }

            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        return condition()
    }
}
