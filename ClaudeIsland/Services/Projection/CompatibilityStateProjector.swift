//
//  CompatibilityStateProjector.swift
//  ClaudeIsland
//
//  Phase 1 compatibility view-shape skeleton derived from projection state.
//

import Foundation

struct CompatibilitySessionSummary: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let title: String
    let status: CanonicalConversationStatus
    let needsAttention: Bool
    let activeApprovalID: String?
    let activeChoiceID: String?
    let pendingInteractionCount: Int
    let chatItemCount: Int
    let inProgressToolCount: Int
    let lastMessageText: String?
}

struct CompatibilityProjectionSnapshot: Codable, Equatable, Sendable {
    let sessions: [CompatibilitySessionSummary]
    let paritySnapshot: LegacySessionParitySnapshot
}

enum CompatibilityStateProjector {
    static func project(_ snapshot: SessionProjectionSnapshot) -> CompatibilityProjectionSnapshot {
        let sortedConversations = snapshot.conversations.values.sorted { $0.id < $1.id }

        let sessions = sortedConversations.map { conversation in
            let activeApproval = conversation.approvals.first {
                $0.domainState == .requested
            }
            let activeChoice = conversation.choices.first {
                $0.domainState == .requested || $0.submissionState == .submissionPending
            }
            let pendingInteractionCount = (activeApproval != nil || activeChoice != nil) ? 1 : 0
            let inProgressToolCount = conversation.tools.filter {
                $0.state == .started || $0.state == .running
            }.count
            let chatItemCount = conversation.messages.count + conversation.tools.count + pendingInteractionCount
            let lastMessageText = conversation.messages
                .sorted { $0.updatedAt < $1.updatedAt }
                .last?
                .text
            let title = conversation.title
                ?? conversation.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? conversation.id

            return CompatibilitySessionSummary(
                id: conversation.id,
                title: title,
                status: conversation.status,
                needsAttention: activeApproval != nil || activeChoice != nil,
                activeApprovalID: activeApproval?.toolID ?? activeApproval?.id,
                activeChoiceID: activeChoice?.toolID ?? activeChoice?.id,
                pendingInteractionCount: pendingInteractionCount,
                chatItemCount: chatItemCount,
                inProgressToolCount: inProgressToolCount,
                lastMessageText: lastMessageText
            )
        }

        let paritySnapshot = LegacySessionParitySnapshot(
            sessionCount: sessions.count,
            sessionIDs: sessions.map(\.id),
            attentionSessionIDs: sessions.filter(\.needsAttention).map(\.id),
            activeApprovalToolUseIDs: Dictionary(
                uniqueKeysWithValues: sessions.compactMap { session in
                    guard let approvalID = session.activeApprovalID else { return nil }
                    return (session.id, approvalID)
                }
            ),
            activeChoiceIDs: Dictionary(
                uniqueKeysWithValues: sessions.compactMap { session in
                    guard let choiceID = session.activeChoiceID else { return nil }
                    return (session.id, choiceID)
                }
            ),
            pendingInteractionCounts: Dictionary(
                uniqueKeysWithValues: sessions.map { ($0.id, $0.pendingInteractionCount) }
            ),
            chatItemCounts: Dictionary(
                uniqueKeysWithValues: sessions.map { ($0.id, $0.chatItemCount) }
            ),
            inProgressToolCounts: Dictionary(
                uniqueKeysWithValues: sessions.map { ($0.id, $0.inProgressToolCount) }
            )
        )

        return CompatibilityProjectionSnapshot(
            sessions: sessions,
            paritySnapshot: paritySnapshot
        )
    }
}
