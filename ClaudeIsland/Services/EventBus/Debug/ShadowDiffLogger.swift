//
//  ShadowDiffLogger.swift
//  ClaudeIsland
//
//  Observe-only shadow diff logging. Phase 0 deliberately avoids mutating UI or
//  runtime state; if no projection snapshot is registered, this logger is a
//  no-op.
//

import Foundation
import os.log

struct SessionShadowDiff: Codable, Equatable, Sendable {
    let sessionCountMismatch: [Int]
    let sessionIDsMismatch: [[String]]
    let attentionMismatch: [[String]]
    let activeApprovalMismatch: [[String: String]]
    let activeChoiceMismatch: [[String: String]]
    let pendingCountMismatch: [[String: Int]]
    let chatItemCountMismatch: [[String: Int]]
    let inProgressToolCountMismatch: [[String: Int]]

    var hasDiff: Bool {
        !sessionCountMismatch.isEmpty
            || !sessionIDsMismatch.isEmpty
            || !attentionMismatch.isEmpty
            || !activeApprovalMismatch.isEmpty
            || !activeChoiceMismatch.isEmpty
            || !pendingCountMismatch.isEmpty
            || !chatItemCountMismatch.isEmpty
            || !inProgressToolCountMismatch.isEmpty
    }
}

enum ShadowDiffLogger {
    private static let logger = Logger(subsystem: "com.claudeisland", category: "EventBusShadow")
    private static let lock = NSLock()
    private static var projectedSnapshot: LegacySessionParitySnapshot?

    static func updateProjectedSnapshot(_ snapshot: LegacySessionParitySnapshot?) {
        lock.lock()
        projectedSnapshot = snapshot
        lock.unlock()
    }

    static func logDiffIfAvailable(legacySessions: [SessionState]) {
        guard EventBusFeatureFlags.snapshot().enableShadowDiffLogging else { return }

        let projected = currentProjectedSnapshot()
        guard let projected else { return }

        let legacy = LegacySessionParitySnapshot.from(sessions: legacySessions)
        let diff = SessionShadowDiff(
            sessionCountMismatch: legacy.sessionCount == projected.sessionCount ? [] : [legacy.sessionCount, projected.sessionCount],
            sessionIDsMismatch: legacy.sessionIDs == projected.sessionIDs ? [] : [legacy.sessionIDs, projected.sessionIDs],
            attentionMismatch: legacy.attentionSessionIDs == projected.attentionSessionIDs ? [] : [legacy.attentionSessionIDs, projected.attentionSessionIDs],
            activeApprovalMismatch: legacy.activeApprovalToolUseIDs == projected.activeApprovalToolUseIDs ? [] : [legacy.activeApprovalToolUseIDs, projected.activeApprovalToolUseIDs],
            activeChoiceMismatch: legacy.activeChoiceIDs == projected.activeChoiceIDs ? [] : [legacy.activeChoiceIDs, projected.activeChoiceIDs],
            pendingCountMismatch: legacy.pendingInteractionCounts == projected.pendingInteractionCounts ? [] : [legacy.pendingInteractionCounts, projected.pendingInteractionCounts],
            chatItemCountMismatch: legacy.chatItemCounts == projected.chatItemCounts ? [] : [legacy.chatItemCounts, projected.chatItemCounts],
            inProgressToolCountMismatch: legacy.inProgressToolCounts == projected.inProgressToolCounts ? [] : [legacy.inProgressToolCounts, projected.inProgressToolCounts]
        )

        guard diff.hasDiff,
              let data = try? JSONEncoder().encode(diff),
              let payload = String(data: data, encoding: .utf8) else {
            return
        }

        logger.warning("shadow_diff \(payload, privacy: .public)")
    }

    private static func currentProjectedSnapshot() -> LegacySessionParitySnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return projectedSnapshot
    }
}
