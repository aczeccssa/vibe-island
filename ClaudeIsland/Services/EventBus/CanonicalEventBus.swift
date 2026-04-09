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
    private static let maxFingerprintsPerDedupeKey = 64
    private static let maxDedupeKeys = 2048

    private var historyStorage: [CanonicalEventEnvelope] = []
    private var subscribers: [UUID: SubscriberStream.Continuation] = [:]
    private var seenFingerprints: [CanonicalEventDedupeKey: [Data]] = [:]
    private var dedupeKeyOrder: [CanonicalEventDedupeKey] = []

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

        var bucket = seenFingerprints[dedupeKey, default: []]
        if bucket.isEmpty {
            dedupeKeyOrder.append(dedupeKey)
            trimDedupeKeyStorageIfNeeded()
        }
        bucket.append(fingerprint)
        if bucket.count > Self.maxFingerprintsPerDedupeKey {
            bucket.removeFirst(bucket.count - Self.maxFingerprintsPerDedupeKey)
        }
        seenFingerprints[dedupeKey] = bucket
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

    func fingerprintCount(for event: CanonicalEventEnvelope) -> Int {
        let dedupeKey = CanonicalEventDedupeKey(
            type: event.type,
            conversationID: event.conversation.id,
            primaryEntityID: event.primaryEntityID,
            adapterID: event.adapterID,
            sourceKind: event.agent.sourceKind,
            sourceSequence: sourceSequenceToken(from: event.sourceSeq)
        )
        return seenFingerprints[dedupeKey, default: []].count
    }

    func dedupeKeyCount() -> Int {
        seenFingerprints.count
    }

    private func fanOut(_ event: CanonicalEventEnvelope) {
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    private func removeSubscriber(_ subscriberID: UUID) {
        subscribers.removeValue(forKey: subscriberID)
    }

    private func trimDedupeKeyStorageIfNeeded() {
        guard dedupeKeyOrder.count > Self.maxDedupeKeys else { return }

        let overflowCount = dedupeKeyOrder.count - Self.maxDedupeKeys
        let evictedKeys = dedupeKeyOrder.prefix(overflowCount)
        for key in evictedKeys {
            seenFingerprints.removeValue(forKey: key)
        }
        dedupeKeyOrder.removeFirst(overflowCount)
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
