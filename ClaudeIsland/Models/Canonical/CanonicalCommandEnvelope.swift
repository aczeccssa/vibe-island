//
//  CanonicalCommandEnvelope.swift
//  ClaudeIsland
//
//  Phase 1 canonical command contracts.
//

import Foundation

enum CanonicalCommandType: String, CaseIterable, Codable, Sendable {
    case approvalResolve = "approval.resolve"
    case choiceSubmit = "choice.submit"
    case sessionFocus = "session.focus"
    case sessionArchive = "session.archive"
    case sessionInterrupt = "session.interrupt"
    case sessionClear = "session.clear"
}

enum CanonicalCommandTargetEntityType: String, Codable, Sendable {
    case approval
    case choice
    case session
}

enum CanonicalCommandMode: String, Codable, Sendable {
    case authoritative
    case desktopFallback = "desktop_fallback"
}

enum CanonicalCommandDispatchStatus: String, Codable, Equatable, Sendable {
    case accepted
    case rejected
    case unsupported
    case timedOut = "timed_out"
}

struct CanonicalCommandTarget: Codable, Equatable, Sendable {
    let adapterID: RuntimeAdapterID
    let entityType: CanonicalCommandTargetEntityType
    let entityID: String?

    private enum CodingKeys: String, CodingKey {
        case adapterID = "adapter_id"
        case entityType = "entity_type"
        case entityID = "entity_id"
    }
}

struct CanonicalApprovalResolveCommandPayload: Codable, Equatable, Sendable {
    let decision: CanonicalApprovalDecision
    let scope: CanonicalDecisionScope
    let reason: String?
}

struct CanonicalChoiceSubmitCommandPayload: Codable, Equatable, Sendable {
    let submittedBy: CanonicalChoiceSubmittedBy
    let valueShape: CanonicalChoiceValueShape
    let value: [String: AnyCodable]

    private enum CodingKeys: String, CodingKey {
        case submittedBy = "submitted_by"
        case valueShape = "value_shape"
        case value
    }
}

struct CanonicalSessionCommandPayload: Codable, Equatable, Sendable {
    let reason: String?
}

struct CanonicalSessionClearCommandPayload: Codable, Equatable, Sendable {
    let reason: String?
    let allowProjectionFallback: Bool

    private enum CodingKeys: String, CodingKey {
        case reason
        case allowProjectionFallback = "allow_projection_fallback"
    }
}

enum CanonicalCommandPayload: Equatable, Sendable {
    case approvalResolve(CanonicalApprovalResolveCommandPayload)
    case choiceSubmit(CanonicalChoiceSubmitCommandPayload)
    case sessionFocus(CanonicalSessionCommandPayload)
    case sessionArchive(CanonicalSessionCommandPayload)
    case sessionInterrupt(CanonicalSessionCommandPayload)
    case sessionClear(CanonicalSessionClearCommandPayload)

    var commandType: CanonicalCommandType {
        switch self {
        case .approvalResolve:
            return .approvalResolve
        case .choiceSubmit:
            return .choiceSubmit
        case .sessionFocus:
            return .sessionFocus
        case .sessionArchive:
            return .sessionArchive
        case .sessionInterrupt:
            return .sessionInterrupt
        case .sessionClear:
            return .sessionClear
        }
    }
}

struct CanonicalCommandEnvelope: Codable, Equatable, Sendable {
    let commandID: UUID
    let schemaVersion: CanonicalSchemaVersion
    let issuedAt: Date
    let conversationID: String
    let target: CanonicalCommandTarget
    let type: CanonicalCommandType
    let mode: CanonicalCommandMode
    let idempotencyKey: String
    let payload: CanonicalCommandPayload

    private enum CodingKeys: String, CodingKey {
        case commandID = "command_id"
        case schemaVersion = "schema_version"
        case issuedAt = "issued_at"
        case conversationID = "conversation_id"
        case target
        case type
        case mode
        case idempotencyKey = "idempotency_key"
        case payload
    }

    init(
        commandID: UUID = UUID(),
        schemaVersion: CanonicalSchemaVersion = .v2_0,
        issuedAt: Date = Date(),
        conversationID: String,
        target: CanonicalCommandTarget,
        type: CanonicalCommandType,
        mode: CanonicalCommandMode,
        idempotencyKey: String,
        payload: CanonicalCommandPayload
    ) {
        self.commandID = commandID
        self.schemaVersion = schemaVersion
        self.issuedAt = issuedAt
        self.conversationID = conversationID
        self.target = target
        self.type = type
        self.mode = mode
        self.idempotencyKey = idempotencyKey
        self.payload = payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(CanonicalCommandType.self, forKey: .type)

        commandID = try container.decode(UUID.self, forKey: .commandID)
        schemaVersion = try container.decode(CanonicalSchemaVersion.self, forKey: .schemaVersion)
        let issuedAtString = try container.decode(String.self, forKey: .issuedAt)
        guard let parsedIssuedAt = CanonicalTimestampCoding.date(from: issuedAtString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .issuedAt,
                in: container,
                debugDescription: "issued_at must decode as an ISO-8601 timestamp"
            )
        }
        issuedAt = parsedIssuedAt
        conversationID = try container.decode(String.self, forKey: .conversationID)
        target = try container.decode(CanonicalCommandTarget.self, forKey: .target)
        self.type = type
        mode = try container.decode(CanonicalCommandMode.self, forKey: .mode)
        idempotencyKey = try container.decode(String.self, forKey: .idempotencyKey)
        payload = try Self.decodePayload(for: type, from: container)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(commandID, forKey: .commandID)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(CanonicalTimestampCoding.string(from: issuedAt), forKey: .issuedAt)
        try container.encode(conversationID, forKey: .conversationID)
        try container.encode(target, forKey: .target)
        try container.encode(type, forKey: .type)
        try container.encode(mode, forKey: .mode)
        try container.encode(idempotencyKey, forKey: .idempotencyKey)
        try Self.encodePayload(payload, to: &container)
    }

    private static func decodePayload(
        for type: CanonicalCommandType,
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> CanonicalCommandPayload {
        switch type {
        case .approvalResolve:
            return .approvalResolve(try container.decode(CanonicalApprovalResolveCommandPayload.self, forKey: .payload))
        case .choiceSubmit:
            return .choiceSubmit(try container.decode(CanonicalChoiceSubmitCommandPayload.self, forKey: .payload))
        case .sessionFocus:
            return .sessionFocus(try container.decode(CanonicalSessionCommandPayload.self, forKey: .payload))
        case .sessionArchive:
            return .sessionArchive(try container.decode(CanonicalSessionCommandPayload.self, forKey: .payload))
        case .sessionInterrupt:
            return .sessionInterrupt(try container.decode(CanonicalSessionCommandPayload.self, forKey: .payload))
        case .sessionClear:
            return .sessionClear(try container.decode(CanonicalSessionClearCommandPayload.self, forKey: .payload))
        }
    }

    private static func encodePayload(
        _ payload: CanonicalCommandPayload,
        to container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        switch payload {
        case .approvalResolve(let value):
            try container.encode(value, forKey: .payload)
        case .choiceSubmit(let value):
            try container.encode(value, forKey: .payload)
        case .sessionFocus(let value):
            try container.encode(value, forKey: .payload)
        case .sessionArchive(let value):
            try container.encode(value, forKey: .payload)
        case .sessionInterrupt(let value):
            try container.encode(value, forKey: .payload)
        case .sessionClear(let value):
            try container.encode(value, forKey: .payload)
        }
    }
}

struct CanonicalCommandDispatchResult: Codable, Equatable, Sendable {
    let commandID: UUID
    let adapterID: RuntimeAdapterID
    let status: CanonicalCommandDispatchStatus
    let observedAt: Date
    let notes: String?

    init(
        commandID: UUID,
        adapterID: RuntimeAdapterID,
        status: CanonicalCommandDispatchStatus,
        observedAt: Date = Date(),
        notes: String? = nil
    ) {
        self.commandID = commandID
        self.adapterID = adapterID
        self.status = status
        self.observedAt = observedAt
        self.notes = notes
    }
}
