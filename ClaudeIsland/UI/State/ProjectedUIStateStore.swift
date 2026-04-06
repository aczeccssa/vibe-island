//
//  ProjectedUIStateStore.swift
//  ClaudeIsland
//
//  Phase 1 modern UI state skeleton fed from projection snapshots.
//

import Combine
import Foundation

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
