//
//  ProjectedUIStateStore.swift
//  ClaudeIsland
//
//  Phase 1 modern UI state skeleton fed from projection snapshots.
//

import Combine
import Foundation

enum ProjectedSessionRuntimePhase: String, Equatable, Sendable {
    case idle
    case processing
    case compacting
    case waitingForApproval = "waiting_for_approval"
    case waitingForInput = "waiting_for_input"
    case ended

    var needsAttention: Bool {
        switch self {
        case .waitingForApproval, .waitingForInput:
            return true
        case .idle, .processing, .compacting, .ended:
            return false
        }
    }

    var isWaitingForApproval: Bool { self == .waitingForApproval }
    var isProcessingLike: Bool { self == .processing || self == .compacting }
}

enum ProjectedInteractionOptionRole: String, Equatable, Sendable {
    case primary
    case secondary
    case destructive
    case bypass
}

enum ProjectedPromptKind: String, Equatable, Sendable {
    case approval
    case choice
}

enum ProjectedPromptResponseCapability: String, Equatable, Sendable {
    case nativeHookAvailable = "native_hook_available"
    case keyboardFallbackAvailable = "keyboard_fallback_available"
    case directTextAvailable = "direct_text_available"
    case detectOnly = "detect_only"
}

enum ProjectedPromptSubmissionEncoding: String, Equatable, Sendable {
    case optionValue = "option_value"
    case optionLabel = "option_label"
}

enum ProjectedPromptProgrammaticStrategy: String, Equatable, Sendable {
    case none
    case claudeAskUserQuestion = "claude_ask_user_question"
}

struct ProjectedInteractionOptionState: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let submissionValue: String
    let detail: String?
    let role: ProjectedInteractionOptionRole
}

struct ProjectedInteractionQuestionState: Identifiable, Equatable, Sendable {
    let id: String
    let header: String?
    let question: String
    let options: [ProjectedInteractionOptionState]
}

struct ProjectedPromptSelection: Equatable, Sendable {
    let questionID: String
    let option: ProjectedInteractionOptionState
}

struct ProjectedPromptState: Identifiable, Equatable, Sendable {
    let id: String
    let sessionID: String
    let toolUseID: String?
    let toolName: String?
    let toolInputPreview: String?
    let sourceAgentID: String
    let kind: ProjectedPromptKind
    let title: String
    let questions: [ProjectedInteractionQuestionState]
    let preferredOptionID: String?
    let createdAt: Date
    let responseCapability: ProjectedPromptResponseCapability
    let submissionEncoding: ProjectedPromptSubmissionEncoding
    let programmaticStrategy: ProjectedPromptProgrammaticStrategy
    let sourceToolInputJSON: String?

    var question: String {
        questions.first?.question ?? ""
    }

    var options: [ProjectedInteractionOptionState] {
        questions.first?.options ?? []
    }

    var isMultiQuestion: Bool {
        questions.count > 1
    }

    var canSubmitDirectly: Bool {
        responseCapability != .detectOnly
    }

    func commandValue(for selections: [ProjectedPromptSelection]) -> [String: Any]? {
        guard !selections.isEmpty else { return nil }

        switch programmaticStrategy {
        case .claudeAskUserQuestion:
            return claudeAskUserQuestionValue(for: selections)
        case .none:
            return defaultProgrammaticValue(for: selections)
        }
    }

    private func claudeAskUserQuestionValue(for selections: [ProjectedPromptSelection]) -> [String: Any]? {
        let selectionsByQuestionID = Dictionary(uniqueKeysWithValues: selections.map { ($0.questionID, $0.option) })
        let questionsByID = Dictionary(uniqueKeysWithValues: questions.map { ($0.id, $0) })
        var updatedInput = decodedToolInputPayload() ?? serializedQuestionsPayload()
        var answers: [String: String] = [:]

        for (questionID, option) in selectionsByQuestionID {
            guard let question = questionsByID[questionID] else { continue }
            answers[question.question] = option.label
        }

        guard !answers.isEmpty else { return nil }
        updatedInput["answers"] = answers
        return updatedInput
    }

    private func defaultProgrammaticValue(for selections: [ProjectedPromptSelection]) -> [String: Any]? {
        let selectionsByQuestionID = Dictionary(uniqueKeysWithValues: selections.map { ($0.questionID, $0.option) })

        switch sourceAgentID {
        case "codex":
            let answers = questions.reduce(into: [String: Any]()) { partialResult, question in
                guard let option = selectionsByQuestionID[question.id] else { return }
                partialResult[question.id] = [
                    "answers": [
                        encodedAnswerValue(for: option)
                    ]
                ]
            }
            return answers.isEmpty ? nil : ["answers": answers]

        default:
            let orderedAnswers = questions.compactMap { question -> String? in
                guard let option = selectionsByQuestionID[question.id] else { return nil }
                return encodedAnswerValue(for: option)
            }
            return orderedAnswers.isEmpty ? nil : ["answers": orderedAnswers]
        }
    }

    private func encodedAnswerValue(for option: ProjectedInteractionOptionState) -> String {
        switch submissionEncoding {
        case .optionValue:
            return option.submissionValue
        case .optionLabel:
            return option.label
        }
    }

    private func decodedToolInputPayload() -> [String: Any]? {
        guard let sourceToolInputJSON,
              let data = sourceToolInputJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return json
    }

    private func serializedQuestionsPayload() -> [String: Any] {
        [
            "questions": questions.map { question in
                var result: [String: Any] = [
                    "id": question.id,
                    "question": question.question,
                    "multiSelect": false,
                    "options": question.options.map { option in
                        var optionResult: [String: Any] = ["label": option.label]
                        if let detail = option.detail {
                            optionResult["description"] = detail
                        }
                        return optionResult
                    }
                ]
                if let header = question.header {
                    result["header"] = header
                }
                return result
            }
        ]
    }
}

enum ProjectedTimelineItemContent: Equatable, Sendable {
    case user(String)
    case assistant(String)
    case tool(ToolCallItem)
    case thinking(String)
    case interrupted
}

struct ProjectedTimelineItemState: Identifiable, Equatable, Sendable {
    let id: String
    let content: ProjectedTimelineItemContent
    let timestamp: Date
}

struct ProjectedSessionViewState: Identifiable, Equatable, Sendable {
    let sessionID: String
    let adapterID: RuntimeAdapterID
    let familyID: RuntimeFamilyID
    let agentID: String
    let title: String
    let cwd: String
    let pid: Int?
    let tty: String?
    let isInTmux: Bool
    let phase: ProjectedSessionRuntimePhase
    let prompt: ProjectedPromptState?
    let pendingInteractionCount: Int
    let lastActivity: Date
    let createdAt: Date
    let messages: [ProjectedMessageState]
    let tools: [ProjectedToolState]
    let timeline: [ProjectedTimelineItemState]
    let agentDescriptions: [String: String]
    let firstUserMessage: String?
    let lastUserMessage: String?
    let lastUserMessageDate: Date?
    let lastMessage: String?
    let lastMessageRole: String?
    let lastToolName: String?
    let pendingToolName: String?
    let pendingToolInput: String?

    var id: String { sessionID }

    var stableID: String { sessionID }

    var displayTitle: String { title }

    var needsAttention: Bool {
        phase.needsAttention || prompt != nil
    }
}

struct ProjectedInteractionPopState: Equatable, Identifiable, Sendable {
    let sessionID: String
    let prompt: ProjectedPromptState
    let createdAt: Date

    var id: String { prompt.id }
}

struct ProjectedSessionListItemState: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let status: CanonicalConversationStatus
    let needsAttention: Bool
    let pendingInteractionCount: Int
    let inProgressToolCount: Int
    let lastMessageText: String?
}

struct ProjectedChatPanelState: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let messages: [ProjectedMessageState]
    let tools: [ProjectedToolState]
}

struct ProjectedInteractionSurfaceState: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case approval(ProjectedApprovalState)
        case choice(ProjectedChoiceState)
    }

    let id: String
    let conversationID: String
    let kind: Kind
}

struct ProjectedCommandFeedbackState: Identifiable, Equatable, Sendable {
    let id: String
    let conversationID: String
    let commandType: CanonicalCommandType
    let submissionState: ProjectedSubmissionState
}

struct ProjectedUIState: Equatable, Sendable {
    var sessionList: [ProjectedSessionListItemState]
    var chatPanels: [String: ProjectedChatPanelState]
    var interactionSurfaces: [String: ProjectedInteractionSurfaceState]
    var commandFeedback: [String: ProjectedCommandFeedbackState]

    init(
        sessionList: [ProjectedSessionListItemState],
        chatPanels: [String: ProjectedChatPanelState],
        interactionSurfaces: [String: ProjectedInteractionSurfaceState],
        commandFeedback: [String: ProjectedCommandFeedbackState]
    ) {
        self.sessionList = sessionList
        self.chatPanels = chatPanels
        self.interactionSurfaces = interactionSurfaces
        self.commandFeedback = commandFeedback
    }

    static let empty = ProjectedUIState(
        sessionList: [],
        chatPanels: [:],
        interactionSurfaces: [:],
        commandFeedback: [:]
    )

    init(snapshot: SessionProjectionSnapshot) {
        let conversations = snapshot.conversations.values.sorted { $0.id < $1.id }

        sessionList = conversations.map { conversation in
            let title = conversation.title
                ?? conversation.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? conversation.id
            let pendingInteractionCount =
                conversation.approvals.filter { $0.domainState == .requested }.count +
                conversation.choices.filter { $0.domainState == .requested }.count
            let inProgressToolCount = conversation.tools.filter {
                $0.state == .started || $0.state == .running
            }.count
            let lastMessageText = conversation.messages.last?.text
            let needsAttention = pendingInteractionCount > 0
                || conversation.choices.contains { $0.submissionState == .submissionPending }

            return ProjectedSessionListItemState(
                id: conversation.id,
                title: title,
                status: conversation.status,
                needsAttention: needsAttention,
                pendingInteractionCount: pendingInteractionCount,
                inProgressToolCount: inProgressToolCount,
                lastMessageText: lastMessageText
            )
        }

        chatPanels = Dictionary(
            uniqueKeysWithValues: conversations.map { conversation in
                let title = conversation.title
                    ?? conversation.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
                    ?? conversation.id
                return (
                    conversation.id,
                    ProjectedChatPanelState(
                        id: conversation.id,
                        title: title,
                        messages: conversation.messages,
                        tools: conversation.tools
                    )
                )
            }
        )

        let interactionStates = conversations.flatMap { conversation -> [ProjectedInteractionSurfaceState] in
            let approvalStates = conversation.approvals
                .filter { $0.domainState == .requested }
                .map { approval in
                    ProjectedInteractionSurfaceState(
                        id: Self.interactionSurfaceID(
                            conversationID: conversation.id,
                            kind: "approval",
                            entityID: approval.id
                        ),
                        conversationID: conversation.id,
                        kind: .approval(approval)
                    )
                }
            let choiceStates = conversation.choices
                .filter { $0.domainState == .requested || $0.submissionState == .submissionPending }
                .map { choice in
                    ProjectedInteractionSurfaceState(
                        id: Self.interactionSurfaceID(
                            conversationID: conversation.id,
                            kind: "choice",
                            entityID: choice.id
                        ),
                        conversationID: conversation.id,
                        kind: .choice(choice)
                    )
                }
            return approvalStates + choiceStates
        }
        interactionSurfaces = Dictionary(uniqueKeysWithValues: interactionStates.map { ($0.id, $0) })

        let feedbackStates = conversations.flatMap { conversation -> [ProjectedCommandFeedbackState] in
            conversation.sessionCommandSubmissionStates.compactMap { commandType, submissionState in
                guard submissionState != .idle else { return nil }
                let feedbackID = "\(conversation.id):\(commandType.rawValue)"
                return ProjectedCommandFeedbackState(
                    id: feedbackID,
                    conversationID: conversation.id,
                    commandType: commandType,
                    submissionState: submissionState
                )
            }
        }
        commandFeedback = Dictionary(uniqueKeysWithValues: feedbackStates.map { ($0.id, $0) })
    }

    private static func interactionSurfaceID(
        conversationID: String,
        kind: String,
        entityID: String
    ) -> String {
        "\(conversationID):\(kind):\(entityID)"
    }
}

@MainActor
final class ProjectedUIStateStore: ObservableObject {
    @Published var state: ProjectedUIState = .empty

    private var observationTask: Task<Void, Never>?

    init(projectionStore: SessionProjectionStore, autostart: Bool = false) {
        if autostart {
            startObserving(projectionStore: projectionStore)
        }
    }

    func startObserving(projectionStore: SessionProjectionStore) {
        observationTask?.cancel()
        observationTask = Task {
            let stream = await projectionStore.subscribe()
            for await snapshot in stream {
                if Task.isCancelled { break }
                self.state = ProjectedUIState(snapshot: snapshot)
            }
        }
    }

    func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
    }

    deinit {
        observationTask?.cancel()
    }
}
