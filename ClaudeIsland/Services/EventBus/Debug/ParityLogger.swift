//
//  ParityLogger.swift
//  ClaudeIsland
//
//  Observe-only parity logging for the frozen legacy state baseline.
//

import Foundation
import os.log

struct LegacySessionParitySnapshot: Codable, Equatable, Sendable {
    let sessionCount: Int
    let sessionIDs: [String]
    let attentionSessionIDs: [String]
    let activeApprovalToolUseIDs: [String: String]
    let activeChoiceIDs: [String: String]
    let pendingInteractionCounts: [String: Int]
    let chatItemCounts: [String: Int]
    let inProgressToolCounts: [String: Int]

    static func from(sessions: [SessionState]) -> LegacySessionParitySnapshot {
        let sortedSessions = sessions.sorted { $0.sessionId < $1.sessionId }

        return LegacySessionParitySnapshot(
            sessionCount: sortedSessions.count,
            sessionIDs: sortedSessions.map(\.sessionId),
            attentionSessionIDs: sortedSessions.filter(\.needsAttention).map(\.sessionId),
            activeApprovalToolUseIDs: Dictionary(
                uniqueKeysWithValues: sortedSessions.compactMap { session in
                    guard let toolUseID = session.activePermission?.toolUseId, !toolUseID.isEmpty else {
                        return nil
                    }
                    return (session.sessionId, toolUseID)
                }
            ),
            activeChoiceIDs: Dictionary(
                uniqueKeysWithValues: sortedSessions.compactMap { session in
                    guard let interaction = session.activeInteraction else { return nil }
                    let choiceID = interaction.toolUseId ?? interaction.id
                    guard !choiceID.isEmpty else { return nil }
                    return (session.sessionId, choiceID)
                }
            ),
            pendingInteractionCounts: Dictionary(
                uniqueKeysWithValues: sortedSessions.map { ($0.sessionId, $0.pendingInteractionCount) }
            ),
            chatItemCounts: Dictionary(
                uniqueKeysWithValues: sortedSessions.map { ($0.sessionId, $0.chatItems.count) }
            ),
            inProgressToolCounts: Dictionary(
                uniqueKeysWithValues: sortedSessions.map { ($0.sessionId, $0.toolTracker.inProgress.count) }
            )
        )
    }
}

enum ParityLogger {
    private static let logger = Logger(subsystem: "com.claudeisland", category: "EventBusParity")

    static func logLegacySnapshot(sessions: [SessionState]) {
        guard EventBusFeatureFlags.snapshot().enableParityLogging else { return }

        let snapshot = LegacySessionParitySnapshot.from(sessions: sessions)
        guard let data = try? JSONEncoder().encode(snapshot),
              let payload = String(data: data, encoding: .utf8) else {
            logger.error("Failed to encode legacy parity snapshot")
            return
        }

        logger.debug("legacy_parity \(payload, privacy: .public)")
    }
}
