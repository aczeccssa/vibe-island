//
//  CanonicalEventEnvelope.swift
//  ClaudeIsland
//
//  Phase 1 canonical event contracts.
//

import Foundation

enum CanonicalTimestampCoding {
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let fallbackFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func string(from date: Date) -> String {
        fractionalFormatter.string(from: date)
    }

    static func date(from string: String) -> Date? {
        fractionalFormatter.date(from: string) ?? fallbackFormatter.date(from: string)
    }
}

enum CanonicalEventValidationError: Error, Equatable {
    case emptyConversationID
    case emptyRawVendorEvent
    case payloadTypeMismatch(expected: CanonicalEventType, actual: CanonicalEventType)
}

enum CanonicalEventType: String, CaseIterable, Codable, Sendable {
    case conversationActive = "conversation.active"
    case messageDelta = "message.delta"
    case messageFinal = "message.final"
    case toolCallStarted = "tool.call.started"
    case toolCallCompleted = "tool.call.completed"
    case approvalRequested = "approval.requested"
    case approvalResolved = "approval.resolved"
    case userChoiceRequested = "user.choice.requested"
    case userChoiceSubmitted = "user.choice.submitted"
    case userChoiceResolved = "user.choice.resolved"
    case planUpdated = "plan.updated"
}

enum CanonicalSchemaVersion: String, Codable, Sendable {
    case v2_0 = "2.0"
}

enum CanonicalAgentSourceKind: String, Codable, Sendable {
    case api
    case stream
    case hook
    case transcript
    case replay
    case synthetic
    case accessibility
    case localState = "local_state"
}

enum CanonicalConversationStatus: String, Codable, Sendable {
    case active
    case idle
    case completed
    case errored
    case archived
    case unknown
}

enum CanonicalConversationTransition: String, Codable, Sendable {
    case created
    case switched
    case resumed
    case ended
    case statusChanged = "status_changed"
    case unknown
}

enum CanonicalTurnStatus: String, Codable, Sendable {
    case inProgress = "in_progress"
    case completed
    case failed
    case interrupted
    case unknown
}

enum CanonicalMessageRole: String, Codable, Sendable {
    case assistant
    case system
    case tool
    case user
}

enum CanonicalMessageFormat: String, Codable, Sendable {
    case markdown
    case text
    case json
    case unknown
}

enum CanonicalToolKind: String, Codable, Sendable {
    case bash
    case file
    case network
    case search
    case mcp
    case other
}

enum CanonicalToolStartedStatus: String, Codable, Sendable {
    case pending
    case running
    case unknown
}

enum CanonicalToolCompletedStatus: String, Codable, Sendable {
    case completed
    case failed
    case declined
    case cancelled
    case timedOut = "timed_out"
    case unknown
}

enum CanonicalToolErrorKind: String, Codable, Sendable {
    case runtimeError = "runtime_error"
    case transportError = "transport_error"
    case parseError = "parse_error"
    case permissionDenied = "permission_denied"
    case timeout
    case unknown
}

enum CanonicalApprovalKind: String, Codable, Sendable {
    case tool
    case file
    case command
    case network
    case plan
    case sideEffect = "side_effect"
    case unknown
}

enum CanonicalApprovalOption: String, Codable, Sendable {
    case allowOnce = "allow_once"
    case allowSession = "allow_session"
    case deny
    case cancel
}

enum CanonicalDecisionScope: String, Codable, Sendable {
    case once
    case session
    case persisted
    case unknown
}

enum CanonicalApprovalStrength: String, Codable, Sendable {
    case strong
    case weak
}

enum CanonicalApprovalResolutionResult: String, Codable, Sendable {
    case accepted
    case rejected
    case cancelled
    case expired
    case unknown
}

enum CanonicalApprovalDecision: String, Codable, Sendable {
    case allowOnce = "allow_once"
    case allowSession = "allow_session"
    case deny
    case cancel
    case unknown
}

enum CanonicalResolutionActor: String, Codable, Sendable {
    case user
    case adapter
    case runtime
    case unknown
}

enum CanonicalChoiceKind: String, Codable, Sendable {
    case form
    case options
    case oauth
    case freeText = "free_text"
    case unknown
}

enum CanonicalChoiceSubmissionMode: String, Codable, Sendable {
    case programmatic
    case localFallback = "local_fallback"
}

enum CanonicalChoiceSubmittedBy: String, Codable, Sendable {
    case user
    case adapter
}

enum CanonicalChoiceValueShape: String, Codable, Sendable {
    case options
    case form
    case text
    case oauth
    case unknown
}

enum CanonicalChoiceResolutionActor: String, Codable, Sendable {
    case runtime
    case adapter
    case unknown
}

enum CanonicalPlanStepStatus: String, Codable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
}

enum CanonicalSourceSequence: Codable, Equatable, Sendable {
    case string(String)
    case number(Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let number = try? container.decode(Int.self) {
            self = .number(number)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "source_seq must decode as a string or integer"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        }
    }
}

struct CanonicalAgentDescriptor: Codable, Equatable, Sendable {
    let family: RuntimeFamilyID
    let sourceKind: CanonicalAgentSourceKind

    private enum CodingKeys: String, CodingKey {
        case family
        case sourceKind = "source_kind"
    }
}

struct CanonicalConversationDescriptor: Codable, Equatable, Sendable {
    let id: String
    let title: String?
    let cwd: String?
    let status: CanonicalConversationStatus
}

struct CanonicalTurnDescriptor: Codable, Equatable, Sendable {
    let id: String?
    let status: CanonicalTurnStatus
}

struct CanonicalEntityDescriptor: Codable, Equatable, Sendable {
    let messageID: String?
    let toolID: String?
    let approvalID: String?
    let choiceID: String?
    let planID: String?

    private enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case toolID = "tool_id"
        case approvalID = "approval_id"
        case choiceID = "choice_id"
        case planID = "plan_id"
    }
}

struct CanonicalRawEvent: Codable, Equatable, Sendable {
    let vendorEvent: String
    let vendorPayload: [String: AnyCodable]

    private enum CodingKeys: String, CodingKey {
        case vendorEvent = "vendor_event"
        case vendorPayload = "vendor_payload"
    }
}

struct CanonicalConversationActivePayload: Codable, Equatable, Sendable {
    let status: CanonicalConversationStatus
    let transition: CanonicalConversationTransition
}

struct CanonicalMessageDelta: Codable, Equatable, Sendable {
    let id: String?
    let role: CanonicalMessageRole
    let format: CanonicalMessageFormat
    let delta: String
}

struct CanonicalMessageDeltaPayload: Codable, Equatable, Sendable {
    let message: CanonicalMessageDelta
}

struct CanonicalFinalMessage: Codable, Equatable, Sendable {
    let id: String?
    let role: CanonicalMessageRole
    let format: CanonicalMessageFormat
    let text: String?
    let isFinal: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case role
        case format
        case text
        case isFinal = "is_final"
    }
}

struct CanonicalMessageFinalPayload: Codable, Equatable, Sendable {
    let message: CanonicalFinalMessage
}

struct CanonicalStartedTool: Codable, Equatable, Sendable {
    let id: String?
    let name: String
    let kind: CanonicalToolKind
    let input: [String: AnyCodable]
    let status: CanonicalToolStartedStatus
}

struct CanonicalToolCallStartedPayload: Codable, Equatable, Sendable {
    let tool: CanonicalStartedTool
}

struct CanonicalCompletedTool: Codable, Equatable, Sendable {
    let id: String?
    let name: String
    let kind: CanonicalToolKind
    let output: [String: AnyCodable]
    let status: CanonicalToolCompletedStatus
    let errorKind: CanonicalToolErrorKind

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case output
        case status
        case errorKind = "error_kind"
    }
}

struct CanonicalToolCallCompletedPayload: Codable, Equatable, Sendable {
    let tool: CanonicalCompletedTool
}

struct CanonicalApprovalRequested: Codable, Equatable, Sendable {
    let id: String?
    let kind: CanonicalApprovalKind
    let reason: String?
    let options: [CanonicalApprovalOption]
    let scope: CanonicalDecisionScope
    let strength: CanonicalApprovalStrength
}

struct CanonicalApprovalRequestedPayload: Codable, Equatable, Sendable {
    let approval: CanonicalApprovalRequested
}

struct CanonicalApprovalResolved: Codable, Equatable, Sendable {
    let id: String?
    let result: CanonicalApprovalResolutionResult
    let decision: CanonicalApprovalDecision
    let scope: CanonicalDecisionScope
    let resolvedBy: CanonicalResolutionActor

    private enum CodingKeys: String, CodingKey {
        case id
        case result
        case decision
        case scope
        case resolvedBy = "resolved_by"
    }
}

struct CanonicalApprovalResolvedPayload: Codable, Equatable, Sendable {
    let approval: CanonicalApprovalResolved
}

struct CanonicalChoiceRequested: Codable, Equatable, Sendable {
    let id: String?
    let kind: CanonicalChoiceKind
    let prompt: String?
    let schema: [String: AnyCodable]
    let options: [AnyCodable]
}

struct CanonicalUserChoiceRequestedPayload: Codable, Equatable, Sendable {
    let choice: CanonicalChoiceRequested
}

struct CanonicalChoiceSubmitted: Codable, Equatable, Sendable {
    let id: String?
    let submissionMode: CanonicalChoiceSubmissionMode
    let submittedBy: CanonicalChoiceSubmittedBy
    let valueShape: CanonicalChoiceValueShape

    private enum CodingKeys: String, CodingKey {
        case id
        case submissionMode = "submission_mode"
        case submittedBy = "submitted_by"
        case valueShape = "value_shape"
    }
}

struct CanonicalUserChoiceSubmittedPayload: Codable, Equatable, Sendable {
    let choice: CanonicalChoiceSubmitted
}

struct CanonicalChoiceResolved: Codable, Equatable, Sendable {
    let id: String?
    let result: CanonicalApprovalResolutionResult
    let resolvedBy: CanonicalChoiceResolutionActor

    private enum CodingKeys: String, CodingKey {
        case id
        case result
        case resolvedBy = "resolved_by"
    }
}

struct CanonicalUserChoiceResolvedPayload: Codable, Equatable, Sendable {
    let choice: CanonicalChoiceResolved
}

struct CanonicalPlanStep: Codable, Equatable, Sendable {
    let stepID: String?
    let step: String
    let status: CanonicalPlanStepStatus

    private enum CodingKeys: String, CodingKey {
        case stepID = "step_id"
        case step
        case status
    }
}

struct CanonicalPlan: Codable, Equatable, Sendable {
    let text: String?
    let steps: [CanonicalPlanStep]
}

struct CanonicalPlanUpdatedPayload: Codable, Equatable, Sendable {
    let plan: CanonicalPlan
}

enum CanonicalEventPayload: Equatable, Sendable {
    case conversationActive(CanonicalConversationActivePayload)
    case messageDelta(CanonicalMessageDeltaPayload)
    case messageFinal(CanonicalMessageFinalPayload)
    case toolCallStarted(CanonicalToolCallStartedPayload)
    case toolCallCompleted(CanonicalToolCallCompletedPayload)
    case approvalRequested(CanonicalApprovalRequestedPayload)
    case approvalResolved(CanonicalApprovalResolvedPayload)
    case userChoiceRequested(CanonicalUserChoiceRequestedPayload)
    case userChoiceSubmitted(CanonicalUserChoiceSubmittedPayload)
    case userChoiceResolved(CanonicalUserChoiceResolvedPayload)
    case planUpdated(CanonicalPlanUpdatedPayload)

    var eventType: CanonicalEventType {
        switch self {
        case .conversationActive:
            return .conversationActive
        case .messageDelta:
            return .messageDelta
        case .messageFinal:
            return .messageFinal
        case .toolCallStarted:
            return .toolCallStarted
        case .toolCallCompleted:
            return .toolCallCompleted
        case .approvalRequested:
            return .approvalRequested
        case .approvalResolved:
            return .approvalResolved
        case .userChoiceRequested:
            return .userChoiceRequested
        case .userChoiceSubmitted:
            return .userChoiceSubmitted
        case .userChoiceResolved:
            return .userChoiceResolved
        case .planUpdated:
            return .planUpdated
        }
    }
}

struct CanonicalEventEnvelope: Codable, Equatable, Sendable {
    let eventID: UUID
    let schemaVersion: CanonicalSchemaVersion
    let type: CanonicalEventType
    let occurredAt: Date?
    let observedAt: Date
    let sourceSeq: CanonicalSourceSequence?
    let causationID: String?
    let supersedesEventID: String?
    let adapterID: RuntimeAdapterID
    let agent: CanonicalAgentDescriptor
    let conversation: CanonicalConversationDescriptor
    let turn: CanonicalTurnDescriptor
    let entity: CanonicalEntityDescriptor
    let payload: CanonicalEventPayload
    let raw: CanonicalRawEvent

    private enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case schemaVersion = "schema_version"
        case type
        case occurredAt = "occurred_at"
        case observedAt = "observed_at"
        case sourceSeq = "source_seq"
        case causationID = "causation_id"
        case supersedesEventID = "supersedes_event_id"
        case adapterID = "adapter_id"
        case agent
        case conversation
        case turn
        case entity
        case payload
        case raw
    }

    init(
        eventID: UUID = UUID(),
        schemaVersion: CanonicalSchemaVersion = .v2_0,
        type: CanonicalEventType,
        occurredAt: Date? = nil,
        observedAt: Date = Date(),
        sourceSeq: CanonicalSourceSequence? = nil,
        causationID: String? = nil,
        supersedesEventID: String? = nil,
        adapterID: RuntimeAdapterID,
        agent: CanonicalAgentDescriptor,
        conversation: CanonicalConversationDescriptor,
        turn: CanonicalTurnDescriptor = CanonicalTurnDescriptor(id: nil, status: .unknown),
        entity: CanonicalEntityDescriptor = CanonicalEntityDescriptor(messageID: nil, toolID: nil, approvalID: nil, choiceID: nil, planID: nil),
        payload: CanonicalEventPayload,
        raw: CanonicalRawEvent
    ) throws {
        self.eventID = eventID
        self.schemaVersion = schemaVersion
        self.type = type
        self.occurredAt = occurredAt
        self.observedAt = observedAt
        self.sourceSeq = sourceSeq
        self.causationID = causationID
        self.supersedesEventID = supersedesEventID
        self.adapterID = adapterID
        self.agent = agent
        self.conversation = conversation
        self.turn = turn
        self.entity = entity
        self.payload = payload
        self.raw = raw
        try validate()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(CanonicalEventType.self, forKey: .type)

        eventID = try container.decode(UUID.self, forKey: .eventID)
        schemaVersion = try container.decode(CanonicalSchemaVersion.self, forKey: .schemaVersion)
        self.type = type
        if let occurredAtString = try container.decodeIfPresent(String.self, forKey: .occurredAt) {
            guard let parsedDate = CanonicalTimestampCoding.date(from: occurredAtString) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .occurredAt,
                    in: container,
                    debugDescription: "occurred_at must decode as an ISO-8601 timestamp"
                )
            }
            occurredAt = parsedDate
        } else {
            occurredAt = nil
        }

        let observedAtString = try container.decode(String.self, forKey: .observedAt)
        guard let parsedObservedAt = CanonicalTimestampCoding.date(from: observedAtString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .observedAt,
                in: container,
                debugDescription: "observed_at must decode as an ISO-8601 timestamp"
            )
        }
        observedAt = parsedObservedAt
        sourceSeq = try container.decodeIfPresent(CanonicalSourceSequence.self, forKey: .sourceSeq)
        causationID = try container.decodeIfPresent(String.self, forKey: .causationID)
        supersedesEventID = try container.decodeIfPresent(String.self, forKey: .supersedesEventID)
        adapterID = try container.decode(RuntimeAdapterID.self, forKey: .adapterID)
        agent = try container.decode(CanonicalAgentDescriptor.self, forKey: .agent)
        conversation = try container.decode(CanonicalConversationDescriptor.self, forKey: .conversation)
        turn = try container.decode(CanonicalTurnDescriptor.self, forKey: .turn)
        entity = try container.decode(CanonicalEntityDescriptor.self, forKey: .entity)
        raw = try container.decode(CanonicalRawEvent.self, forKey: .raw)
        payload = try Self.decodePayload(for: type, from: container)

        try validate()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(eventID, forKey: .eventID)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(occurredAt.map(CanonicalTimestampCoding.string(from:)), forKey: .occurredAt)
        try container.encode(CanonicalTimestampCoding.string(from: observedAt), forKey: .observedAt)
        try container.encodeIfPresent(sourceSeq, forKey: .sourceSeq)
        try container.encodeIfPresent(causationID, forKey: .causationID)
        try container.encodeIfPresent(supersedesEventID, forKey: .supersedesEventID)
        try container.encode(adapterID, forKey: .adapterID)
        try container.encode(agent, forKey: .agent)
        try container.encode(conversation, forKey: .conversation)
        try container.encode(turn, forKey: .turn)
        try container.encode(entity, forKey: .entity)
        try Self.encodePayload(payload, to: &container)
        try container.encode(raw, forKey: .raw)
    }

    var primaryEntityID: String {
        switch type {
        case .conversationActive:
            return conversation.id
        case .messageDelta:
            return entity.messageID ?? payloadMessageID ?? turn.id ?? conversation.id
        case .messageFinal:
            return entity.messageID ?? payloadMessageID ?? turn.id ?? conversation.id
        case .toolCallStarted:
            return entity.toolID ?? payloadToolID ?? conversation.id
        case .toolCallCompleted:
            return entity.toolID ?? payloadToolID ?? conversation.id
        case .approvalRequested:
            return entity.approvalID ?? payloadApprovalID ?? conversation.id
        case .approvalResolved:
            return entity.approvalID ?? payloadApprovalID ?? conversation.id
        case .userChoiceRequested:
            return entity.choiceID ?? payloadChoiceID ?? conversation.id
        case .userChoiceSubmitted:
            return entity.choiceID ?? payloadChoiceID ?? conversation.id
        case .userChoiceResolved:
            return entity.choiceID ?? payloadChoiceID ?? conversation.id
        case .planUpdated:
            return entity.planID ?? conversation.id
        }
    }

    func dedupeFingerprint() throws -> Data {
        let zeroUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let normalized = try CanonicalEventEnvelope(
            eventID: zeroUUID,
            schemaVersion: schemaVersion,
            type: type,
            occurredAt: occurredAt,
            observedAt: Date(timeIntervalSince1970: 0),
            sourceSeq: sourceSeq,
            causationID: causationID,
            supersedesEventID: supersedesEventID,
            adapterID: adapterID,
            agent: agent,
            conversation: conversation,
            turn: turn,
            entity: entity,
            payload: payload,
            raw: raw
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(normalized)
    }

    private func validate() throws {
        if conversation.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CanonicalEventValidationError.emptyConversationID
        }

        if raw.vendorEvent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CanonicalEventValidationError.emptyRawVendorEvent
        }

        if payload.eventType != type {
            throw CanonicalEventValidationError.payloadTypeMismatch(
                expected: type,
                actual: payload.eventType
            )
        }
    }

    private static func decodePayload(
        for type: CanonicalEventType,
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> CanonicalEventPayload {
        switch type {
        case .conversationActive:
            return .conversationActive(try container.decode(CanonicalConversationActivePayload.self, forKey: .payload))
        case .messageDelta:
            return .messageDelta(try container.decode(CanonicalMessageDeltaPayload.self, forKey: .payload))
        case .messageFinal:
            return .messageFinal(try container.decode(CanonicalMessageFinalPayload.self, forKey: .payload))
        case .toolCallStarted:
            return .toolCallStarted(try container.decode(CanonicalToolCallStartedPayload.self, forKey: .payload))
        case .toolCallCompleted:
            return .toolCallCompleted(try container.decode(CanonicalToolCallCompletedPayload.self, forKey: .payload))
        case .approvalRequested:
            return .approvalRequested(try container.decode(CanonicalApprovalRequestedPayload.self, forKey: .payload))
        case .approvalResolved:
            return .approvalResolved(try container.decode(CanonicalApprovalResolvedPayload.self, forKey: .payload))
        case .userChoiceRequested:
            return .userChoiceRequested(try container.decode(CanonicalUserChoiceRequestedPayload.self, forKey: .payload))
        case .userChoiceSubmitted:
            return .userChoiceSubmitted(try container.decode(CanonicalUserChoiceSubmittedPayload.self, forKey: .payload))
        case .userChoiceResolved:
            return .userChoiceResolved(try container.decode(CanonicalUserChoiceResolvedPayload.self, forKey: .payload))
        case .planUpdated:
            return .planUpdated(try container.decode(CanonicalPlanUpdatedPayload.self, forKey: .payload))
        }
    }

    private static func encodePayload(
        _ payload: CanonicalEventPayload,
        to container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        switch payload {
        case .conversationActive(let value):
            try container.encode(value, forKey: .payload)
        case .messageDelta(let value):
            try container.encode(value, forKey: .payload)
        case .messageFinal(let value):
            try container.encode(value, forKey: .payload)
        case .toolCallStarted(let value):
            try container.encode(value, forKey: .payload)
        case .toolCallCompleted(let value):
            try container.encode(value, forKey: .payload)
        case .approvalRequested(let value):
            try container.encode(value, forKey: .payload)
        case .approvalResolved(let value):
            try container.encode(value, forKey: .payload)
        case .userChoiceRequested(let value):
            try container.encode(value, forKey: .payload)
        case .userChoiceSubmitted(let value):
            try container.encode(value, forKey: .payload)
        case .userChoiceResolved(let value):
            try container.encode(value, forKey: .payload)
        case .planUpdated(let value):
            try container.encode(value, forKey: .payload)
        }
    }

    private var payloadMessageID: String? {
        switch payload {
        case .messageDelta(let value):
            return value.message.id
        case .messageFinal(let value):
            return value.message.id
        default:
            return nil
        }
    }

    private var payloadToolID: String? {
        switch payload {
        case .toolCallStarted(let value):
            return value.tool.id
        case .toolCallCompleted(let value):
            return value.tool.id
        default:
            return nil
        }
    }

    private var payloadApprovalID: String? {
        switch payload {
        case .approvalRequested(let value):
            return value.approval.id
        case .approvalResolved(let value):
            return value.approval.id
        default:
            return nil
        }
    }

    private var payloadChoiceID: String? {
        switch payload {
        case .userChoiceRequested(let value):
            return value.choice.id
        case .userChoiceSubmitted(let value):
            return value.choice.id
        case .userChoiceResolved(let value):
            return value.choice.id
        default:
            return nil
        }
    }
}
