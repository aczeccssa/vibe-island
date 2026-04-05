//
//  CanonicalEventBus.swift
//  ClaudeIsland
//
//  Phase 1 canonical event bus with validation, append-only storage,
//  exact duplicate dedupe, and ordered AsyncStream fan-out.
//

import Foundation

enum CanonicalEventPublishOutcome: Equatable, Sendable {
    case published
    case duplicateIgnored
}

private struct CanonicalEventDedupeKey: Hashable, Sendable {
    let type: CanonicalEventType
    let conversationID: String
    let primaryEntityID: String
    let adapterID: RuntimeAdapterID
    let sourceKind: CanonicalAgentSourceKind
    let sourceSequence: String?
}

actor CanonicalEventBus {
    typealias SubscriberStream = AsyncStream<CanonicalEventEnvelope>

    private var historyStorage: [CanonicalEventEnvelope] = []
    private var subscribers: [UUID: SubscriberStream.Continuation] = [:]
    private var seenFingerprints: [CanonicalEventDedupeKey: Set<Data>] = [:]

    func publish(_ event: CanonicalEventEnvelope) throws -> CanonicalEventPublishOutcome {
        let dedupeKey = CanonicalEventDedupeKey(
            type: event.type,
            conversationID: event.conversation.id,
            primaryEntityID: event.primaryEntityID,
            adapterID: event.adapterID,
            sourceKind: event.agent.sourceKind,
            sourceSequence: sourceSequenceToken(from: event.sourceSeq)
        )
        let fingerprint = try event.dedupeFingerprint()

        if seenFingerprints[dedupeKey, default: []].contains(fingerprint) {
            return .duplicateIgnored
        }

        seenFingerprints[dedupeKey, default: []].insert(fingerprint)
        historyStorage.append(event)
        fanOut(event)
        return .published
    }

    func subscribe() -> SubscriberStream {
        let subscriberID = UUID()
        var continuation: SubscriberStream.Continuation!
        let stream = SubscriberStream { continuation = $0 }
        subscribers[subscriberID] = continuation
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeSubscriber(subscriberID)
            }
        }
        return stream
    }

    func history() -> [CanonicalEventEnvelope] {
        historyStorage
    }

    private func fanOut(_ event: CanonicalEventEnvelope) {
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    private func removeSubscriber(_ subscriberID: UUID) {
        subscribers.removeValue(forKey: subscriberID)
    }

    private func sourceSequenceToken(from sourceSequence: CanonicalSourceSequence?) -> String? {
        switch sourceSequence {
        case .string(let value):
            return "string:\(value)"
        case .number(let value):
            return "number:\(value)"
        case nil:
            return nil
        }
    }
}
