//
//  SessionProjectionStore.swift
//  ClaudeIsland
//
//  Phase 1 projection-owned state materialization.
//

import Foundation

enum ProjectedSubmissionState: String, Codable, Equatable, Sendable {
    case idle
    case submissionPending = "submission_pending"
    case rejected
    case unsupported
    case timedOut = "timed_out"
}

enum ProjectedApprovalDomainState: String, Codable, Equatable, Sendable {
    case requested
    case resolvedAllowed = "resolved_allowed"
    case resolvedDenied = "resolved_denied"
    case resolvedCancelled = "resolved_cancelled"
    case expired
}

enum ProjectedChoiceDomainState: String, Codable, Equatable, Sendable {
    case requested
    case resolved
    case cancelled
    case expired
}

enum ProjectedToolLifecycleState: String, Codable, Equatable, Sendable {
    case started
    case running
    case completed
    case failed
    case declined
    case cancelled
    case timedOut = "timed_out"
}

struct ProjectedMessageState: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let turnID: String?
    let role: CanonicalMessageRole
    let format: CanonicalMessageFormat
    var text: String
    var isFinal: Bool
    let sourceKind: CanonicalAgentSourceKind
    var updatedAt: Date
}

struct ProjectedToolState: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var name: String
    var kind: CanonicalToolKind
    var input: [String: AnyCodable]
    var output: [String: AnyCodable]
    var state: ProjectedToolLifecycleState
    var errorKind: CanonicalToolErrorKind?
    var updatedAt: Date
}

struct ProjectedApprovalState: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var toolID: String?
    var kind: CanonicalApprovalKind
    var reason: String?
    var options: [CanonicalApprovalOption]
    var scope: CanonicalDecisionScope
    var strength: CanonicalApprovalStrength
    var domainState: ProjectedApprovalDomainState
    var submissionState: ProjectedSubmissionState
    var resolvedBy: CanonicalResolutionActor?
    var updatedAt: Date
}

struct ProjectedChoiceState: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var toolID: String?
    var kind: CanonicalChoiceKind
    var prompt: String?
    var schema: [String: AnyCodable]
    var options: [AnyCodable]
    var domainState: ProjectedChoiceDomainState
    var submissionState: ProjectedSubmissionState
    var submittedBy: CanonicalChoiceSubmittedBy?
    var resolvedBy: CanonicalChoiceResolutionActor?
    var valueShape: CanonicalChoiceValueShape?
    var updatedAt: Date
}

struct ProjectedPlanStepState: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let sourceStepID: String?
    var step: String
    var status: CanonicalPlanStepStatus
}

struct ProjectedPlanState: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var text: String?
    var steps: [ProjectedPlanStepState]
    var updatedAt: Date
}

struct ProjectedConversationState: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var adapterID: RuntimeAdapterID
    var familyID: RuntimeFamilyID
    var sourceKind: CanonicalAgentSourceKind
    var title: String?
    var cwd: String?
    var status: CanonicalConversationStatus
    var lastTransition: CanonicalConversationTransition?
    var turn: CanonicalTurnDescriptor
    var messages: [ProjectedMessageState]
    var tools: [ProjectedToolState]
    var approvals: [ProjectedApprovalState]
    var choices: [ProjectedChoiceState]
    var plans: [ProjectedPlanState]
    var sessionCommandSubmissionStates: [CanonicalCommandType: ProjectedSubmissionState]
    var lastUpdatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case adapterID
        case familyID
        case sourceKind
        case title
        case cwd
        case status
        case lastTransition
        case turn
        case messages
        case tools
        case approvals
        case choices
        case plans
        case sessionCommandSubmissionStates
        case lastUpdatedAt
    }

    init(
        id: String,
        adapterID: RuntimeAdapterID,
        familyID: RuntimeFamilyID,
        sourceKind: CanonicalAgentSourceKind,
        title: String?,
        cwd: String?,
        status: CanonicalConversationStatus,
        lastTransition: CanonicalConversationTransition?,
        turn: CanonicalTurnDescriptor,
        messages: [ProjectedMessageState],
        tools: [ProjectedToolState],
        approvals: [ProjectedApprovalState],
        choices: [ProjectedChoiceState],
        plans: [ProjectedPlanState],
        sessionCommandSubmissionStates: [CanonicalCommandType: ProjectedSubmissionState],
        lastUpdatedAt: Date
    ) {
        self.id = id
        self.adapterID = adapterID
        self.familyID = familyID
        self.sourceKind = sourceKind
        self.title = title
        self.cwd = cwd
        self.status = status
        self.lastTransition = lastTransition
        self.turn = turn
        self.messages = messages
        self.tools = tools
        self.approvals = approvals
        self.choices = choices
        self.plans = plans
        self.sessionCommandSubmissionStates = sessionCommandSubmissionStates
        self.lastUpdatedAt = lastUpdatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        adapterID = try container.decode(RuntimeAdapterID.self, forKey: .adapterID)
        familyID = try container.decode(RuntimeFamilyID.self, forKey: .familyID)
        sourceKind = try container.decode(CanonicalAgentSourceKind.self, forKey: .sourceKind)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        status = try container.decode(CanonicalConversationStatus.self, forKey: .status)
        lastTransition = try container.decodeIfPresent(CanonicalConversationTransition.self, forKey: .lastTransition)
        turn = try container.decode(CanonicalTurnDescriptor.self, forKey: .turn)
        messages = try container.decode([ProjectedMessageState].self, forKey: .messages)
        tools = try container.decode([ProjectedToolState].self, forKey: .tools)
        approvals = try container.decode([ProjectedApprovalState].self, forKey: .approvals)
        choices = try container.decode([ProjectedChoiceState].self, forKey: .choices)
        plans = try container.decode([ProjectedPlanState].self, forKey: .plans)
        let commandStates = try container.decodeIfPresent([String: ProjectedSubmissionState].self, forKey: .sessionCommandSubmissionStates) ?? [:]
        sessionCommandSubmissionStates = Dictionary(
            uniqueKeysWithValues: commandStates.compactMap { key, value in
                CanonicalCommandType(rawValue: key).map { ($0, value) }
            }
        )
        lastUpdatedAt = try container.decode(Date.self, forKey: .lastUpdatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(adapterID, forKey: .adapterID)
        try container.encode(familyID, forKey: .familyID)
        try container.encode(sourceKind, forKey: .sourceKind)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(lastTransition, forKey: .lastTransition)
        try container.encode(turn, forKey: .turn)
        try container.encode(messages, forKey: .messages)
        try container.encode(tools, forKey: .tools)
        try container.encode(approvals, forKey: .approvals)
        try container.encode(choices, forKey: .choices)
        try container.encode(plans, forKey: .plans)
        try container.encode(
            Dictionary(uniqueKeysWithValues: sessionCommandSubmissionStates.map { ($0.key.rawValue, $0.value) }),
            forKey: .sessionCommandSubmissionStates
        )
        try container.encode(lastUpdatedAt, forKey: .lastUpdatedAt)
    }
}

struct SessionProjectionSnapshot: Codable, Equatable, Sendable {
    let conversations: [String: ProjectedConversationState]
    let capabilities: [RuntimeAdapterID: [CanonicalSemanticArea: AdapterCapabilitySnapshot]]

    private enum CodingKeys: String, CodingKey {
        case conversations
        case capabilities
    }

    init(
        conversations: [String: ProjectedConversationState],
        capabilities: [RuntimeAdapterID: [CanonicalSemanticArea: AdapterCapabilitySnapshot]]
    ) {
        self.conversations = conversations
        self.capabilities = capabilities
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        conversations = try container.decode([String: ProjectedConversationState].self, forKey: .conversations)
        let rawCapabilities = try container.decodeIfPresent([String: [String: AdapterCapabilitySnapshot]].self, forKey: .capabilities) ?? [:]
        capabilities = Dictionary(uniqueKeysWithValues: rawCapabilities.compactMap { adapterKey, areas in
            guard let adapterID = RuntimeAdapterID(rawValue: adapterKey) else { return nil }
            let mappedAreas = Dictionary(uniqueKeysWithValues: areas.compactMap { areaKey, value in
                CanonicalSemanticArea(rawValue: areaKey).map { ($0, value) }
            })
            return (adapterID, mappedAreas)
        })
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(conversations, forKey: .conversations)
        let encodedCapabilities = Dictionary(uniqueKeysWithValues: capabilities.map { adapterID, areas in
            (
                adapterID.rawValue,
                Dictionary(uniqueKeysWithValues: areas.map { ($0.key.rawValue, $0.value) })
            )
        })
        try container.encode(encodedCapabilities, forKey: .capabilities)
    }
}

actor SessionProjectionStore {
    typealias SnapshotStream = AsyncStream<SessionProjectionSnapshot>

    private var conversations: [String: ProjectedConversationState] = [:]
    private var capabilities: [RuntimeAdapterID: [CanonicalSemanticArea: AdapterCapabilitySnapshot]] = [:]
    private var subscribers: [UUID: SnapshotStream.Continuation] = [:]

    func apply(_ event: CanonicalEventEnvelope) {
        var conversation = materializeConversation(from: event)

        switch event.payload {
        case .conversationActive(let payload):
            conversation.status = payload.status
            conversation.lastTransition = payload.transition
        case .messageDelta(let payload):
            upsertMessageDelta(payload, from: event, into: &conversation)
        case .messageFinal(let payload):
            upsertMessageFinal(payload, from: event, into: &conversation)
        case .toolCallStarted(let payload):
            upsertToolStarted(payload, from: event, into: &conversation)
        case .toolCallCompleted(let payload):
            upsertToolCompleted(payload, from: event, into: &conversation)
        case .approvalRequested(let payload):
            upsertApprovalRequested(payload, from: event, into: &conversation)
        case .approvalResolved(let payload):
            upsertApprovalResolved(payload, from: event, into: &conversation)
        case .userChoiceRequested(let payload):
            upsertChoiceRequested(payload, from: event, into: &conversation)
        case .userChoiceSubmitted(let payload):
            upsertChoiceSubmitted(payload, from: event, into: &conversation)
        case .userChoiceResolved(let payload):
            upsertChoiceResolved(payload, from: event, into: &conversation)
        case .planUpdated(let payload):
            upsertPlan(payload, from: event, into: &conversation)
        }

        conversation.turn = event.turn
        conversation.lastUpdatedAt = event.observedAt
        persist(conversation)
    }

    func apply(_ commandResult: CanonicalCommandDispatchResult, for command: CanonicalCommandEnvelope) {
        guard var conversation = conversations[command.conversationID] else { return }

        let submissionState: ProjectedSubmissionState
        switch commandResult.status {
        case .accepted:
            submissionState = .submissionPending
        case .rejected:
            submissionState = .rejected
        case .unsupported:
            submissionState = .unsupported
        case .timedOut:
            submissionState = .timedOut
        }

        switch command.type {
        case .approvalResolve:
            if let approvalID = command.target.entityID,
               let index = conversation.approvals.firstIndex(where: { $0.id == approvalID }) {
                conversation.approvals[index].submissionState = submissionState
                conversation.approvals[index].updatedAt = commandResult.observedAt
            }
        case .choiceSubmit:
            if let choiceID = command.target.entityID,
               let index = conversation.choices.firstIndex(where: { $0.id == choiceID }) {
                conversation.choices[index].submissionState = submissionState
                conversation.choices[index].updatedAt = commandResult.observedAt
            }
        case .sessionFocus, .sessionArchive, .sessionInterrupt, .sessionClear:
            conversation.sessionCommandSubmissionStates[command.type] = submissionState
        }

        conversation.lastUpdatedAt = commandResult.observedAt
        persist(conversation)
    }

    func publishCapability(_ capability: AdapterCapabilitySnapshot) {
        capabilities[capability.adapterID, default: [:]][capability.semanticArea] = capability
        publishSnapshot()
    }

    func snapshot() -> SessionProjectionSnapshot {
        SessionProjectionSnapshot(
            conversations: conversations,
            capabilities: capabilities
        )
    }

    func subscribe() -> SnapshotStream {
        let subscriberID = UUID()
        var continuation: SnapshotStream.Continuation!
        let stream = SnapshotStream { continuation = $0 }
        subscribers[subscriberID] = continuation
        continuation.yield(snapshot())
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeSubscriber(subscriberID)
            }
        }
        return stream
    }

    func reset() {
        conversations.removeAll()
        capabilities.removeAll()
        publishSnapshot()
    }

    func replaceSnapshot(_ snapshot: SessionProjectionSnapshot) {
        conversations = snapshot.conversations
        capabilities = snapshot.capabilities
        publishSnapshot()
    }

    func removeConversation(id: String) {
        conversations.removeValue(forKey: id)
        publishSnapshot()
    }

    private func materializeConversation(from event: CanonicalEventEnvelope) -> ProjectedConversationState {
        if var existing = conversations[event.conversation.id] {
            existing.adapterID = event.adapterID
            existing.familyID = event.agent.family
            existing.sourceKind = event.agent.sourceKind
            existing.title = event.conversation.title ?? existing.title
            existing.cwd = event.conversation.cwd ?? existing.cwd
            existing.status = event.conversation.status
            return existing
        }

        return ProjectedConversationState(
            id: event.conversation.id,
            adapterID: event.adapterID,
            familyID: event.agent.family,
            sourceKind: event.agent.sourceKind,
            title: event.conversation.title,
            cwd: event.conversation.cwd,
            status: event.conversation.status,
            lastTransition: nil,
            turn: event.turn,
            messages: [],
            tools: [],
            approvals: [],
            choices: [],
            plans: [],
            sessionCommandSubmissionStates: [:],
            lastUpdatedAt: event.observedAt
        )
    }

    private func persist(_ conversation: ProjectedConversationState) {
        conversations[conversation.id] = sort(conversation)
        publishSnapshot()
    }

    private func publishSnapshot() {
        let currentSnapshot = snapshot()

        for continuation in subscribers.values {
            continuation.yield(currentSnapshot)
        }
    }

    private func removeSubscriber(_ subscriberID: UUID) {
        subscribers.removeValue(forKey: subscriberID)
    }

    private func sort(_ conversation: ProjectedConversationState) -> ProjectedConversationState {
        var sorted = conversation
        sorted.messages.sort {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
            return $0.id < $1.id
        }
        sorted.tools.sort {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
            return $0.id < $1.id
        }
        sorted.approvals.sort {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
            return $0.id < $1.id
        }
        sorted.choices.sort {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
            return $0.id < $1.id
        }
        sorted.plans.sort {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
            return $0.id < $1.id
        }
        return sorted
    }

    private func upsertMessageDelta(
        _ payload: CanonicalMessageDeltaPayload,
        from event: CanonicalEventEnvelope,
        into conversation: inout ProjectedConversationState
    ) {
        let messageID = resolveMessageID(from: event, payloadID: payload.message.id)
        let index = conversation.messages.firstIndex(where: { $0.id == messageID })

        if let index {
            conversation.messages[index].text += payload.message.delta
            conversation.messages[index].isFinal = false
            conversation.messages[index].updatedAt = event.observedAt
        } else {
            conversation.messages.append(
                ProjectedMessageState(
                    id: messageID,
                    turnID: event.turn.id,
                    role: payload.message.role,
                    format: payload.message.format,
                    text: payload.message.delta,
                    isFinal: false,
                    sourceKind: event.agent.sourceKind,
                    updatedAt: event.observedAt
                )
            )
        }
    }

    private func upsertMessageFinal(
        _ payload: CanonicalMessageFinalPayload,
        from event: CanonicalEventEnvelope,
        into conversation: inout ProjectedConversationState
    ) {
        let messageID = resolveMessageID(from: event, payloadID: payload.message.id)
        let existingMessageIndex = conversation.messages.firstIndex(where: { $0.id == messageID })
        let finalText = payload.message.text
            ?? existingMessageIndex.map { conversation.messages[$0].text }
            ?? ""
        let updated = ProjectedMessageState(
            id: messageID,
            turnID: event.turn.id,
            role: payload.message.role,
            format: payload.message.format,
            text: finalText,
            isFinal: payload.message.isFinal,
            sourceKind: event.agent.sourceKind,
            updatedAt: event.observedAt
        )

        if let index = existingMessageIndex {
            conversation.messages[index] = updated
        } else {
            conversation.messages.append(updated)
        }
    }

    private func upsertToolStarted(
        _ payload: CanonicalToolCallStartedPayload,
        from event: CanonicalEventEnvelope,
        into conversation: inout ProjectedConversationState
    ) {
        let toolID = resolveToolID(from: event, payloadID: payload.tool.id, name: payload.tool.name, input: payload.tool.input)
        let state: ProjectedToolLifecycleState = payload.tool.status == .running ? .running : .started
        let updated = ProjectedToolState(
            id: toolID,
            name: payload.tool.name,
            kind: payload.tool.kind,
            input: payload.tool.input,
            output: [:],
            state: state,
            errorKind: nil,
            updatedAt: event.observedAt
        )

        if let index = conversation.tools.firstIndex(where: { $0.id == toolID }) {
            conversation.tools[index] = updated
        } else {
            conversation.tools.append(updated)
        }
    }

    private func upsertToolCompleted(
        _ payload: CanonicalToolCallCompletedPayload,
        from event: CanonicalEventEnvelope,
        into conversation: inout ProjectedConversationState
    ) {
        let toolID = resolveCompletedToolID(
            in: conversation,
            from: event,
            payload: payload.tool
        )
        let state = mapToolState(payload.tool.status)

        if let index = conversation.tools.firstIndex(where: { $0.id == toolID }) {
            conversation.tools[index].name = payload.tool.name
            conversation.tools[index].kind = payload.tool.kind
            conversation.tools[index].output = payload.tool.output
            conversation.tools[index].state = state
            conversation.tools[index].errorKind = payload.tool.errorKind == .unknown ? nil : payload.tool.errorKind
            conversation.tools[index].updatedAt = event.observedAt
        } else {
            conversation.tools.append(
                ProjectedToolState(
                    id: toolID,
                    name: payload.tool.name,
                    kind: payload.tool.kind,
                    input: [:],
                    output: payload.tool.output,
                    state: state,
                    errorKind: payload.tool.errorKind == .unknown ? nil : payload.tool.errorKind,
                    updatedAt: event.observedAt
                )
            )
        }
    }

    private func upsertApprovalRequested(
        _ payload: CanonicalApprovalRequestedPayload,
        from event: CanonicalEventEnvelope,
        into conversation: inout ProjectedConversationState
    ) {
        let approvalID = resolveApprovalID(from: event, payloadID: payload.approval.id)
        let updated = ProjectedApprovalState(
            id: approvalID,
            toolID: event.entity.toolID,
            kind: payload.approval.kind,
            reason: payload.approval.reason,
            options: payload.approval.options,
            scope: payload.approval.scope,
            strength: payload.approval.strength,
            domainState: .requested,
            submissionState: .idle,
            resolvedBy: nil,
            updatedAt: event.observedAt
        )

        if let index = conversation.approvals.firstIndex(where: { $0.id == approvalID }) {
            conversation.approvals[index] = updated
        } else {
            conversation.approvals.append(updated)
        }
    }

    private func upsertApprovalResolved(
        _ payload: CanonicalApprovalResolvedPayload,
        from event: CanonicalEventEnvelope,
        into conversation: inout ProjectedConversationState
    ) {
        let approvalID = resolveApprovalID(from: event, payloadID: payload.approval.id)
        let domainState = mapApprovalState(payload.approval.result)

        if let index = conversation.approvals.firstIndex(where: { $0.id == approvalID }) {
            conversation.approvals[index].toolID = event.entity.toolID ?? conversation.approvals[index].toolID
            conversation.approvals[index].domainState = domainState
            conversation.approvals[index].scope = payload.approval.scope
            conversation.approvals[index].submissionState = .idle
            conversation.approvals[index].resolvedBy = payload.approval.resolvedBy
            conversation.approvals[index].updatedAt = event.observedAt
        } else {
            conversation.approvals.append(
                ProjectedApprovalState(
                    id: approvalID,
                    toolID: event.entity.toolID,
                    kind: .unknown,
                    reason: nil,
                    options: [],
                    scope: payload.approval.scope,
                    strength: .weak,
                    domainState: domainState,
                    submissionState: .idle,
                    resolvedBy: payload.approval.resolvedBy,
                    updatedAt: event.observedAt
                )
            )
        }
    }

    private func upsertChoiceRequested(
        _ payload: CanonicalUserChoiceRequestedPayload,
        from event: CanonicalEventEnvelope,
        into conversation: inout ProjectedConversationState
    ) {
        let choiceID = resolveChoiceID(from: event, payloadID: payload.choice.id)
        let updated = ProjectedChoiceState(
            id: choiceID,
            toolID: event.entity.toolID,
            kind: payload.choice.kind,
            prompt: payload.choice.prompt,
            schema: payload.choice.schema,
            options: payload.choice.options,
            domainState: .requested,
            submissionState: .idle,
            submittedBy: nil,
            resolvedBy: nil,
            valueShape: nil,
            updatedAt: event.observedAt
        )

        if let index = conversation.choices.firstIndex(where: { $0.id == choiceID }) {
            conversation.choices[index] = updated
        } else {
            conversation.choices.append(updated)
        }
    }

    private func upsertChoiceSubmitted(
        _ payload: CanonicalUserChoiceSubmittedPayload,
        from event: CanonicalEventEnvelope,
        into conversation: inout ProjectedConversationState
    ) {
        let choiceID = resolveChoiceID(from: event, payloadID: payload.choice.id)

        if let index = conversation.choices.firstIndex(where: { $0.id == choiceID }) {
            conversation.choices[index].toolID = event.entity.toolID ?? conversation.choices[index].toolID
            conversation.choices[index].submissionState = .submissionPending
            conversation.choices[index].submittedBy = payload.choice.submittedBy
            conversation.choices[index].valueShape = payload.choice.valueShape
            conversation.choices[index].updatedAt = event.observedAt
        } else {
            conversation.choices.append(
                ProjectedChoiceState(
                    id: choiceID,
                    toolID: event.entity.toolID,
                    kind: .unknown,
                    prompt: nil,
                    schema: [:],
                    options: [],
                    domainState: .requested,
                    submissionState: .submissionPending,
                    submittedBy: payload.choice.submittedBy,
                    resolvedBy: nil,
                    valueShape: payload.choice.valueShape,
                    updatedAt: event.observedAt
                )
            )
        }
    }

    private func upsertChoiceResolved(
        _ payload: CanonicalUserChoiceResolvedPayload,
        from event: CanonicalEventEnvelope,
        into conversation: inout ProjectedConversationState
    ) {
        let choiceID = resolveChoiceID(from: event, payloadID: payload.choice.id)

        if let index = conversation.choices.firstIndex(where: { $0.id == choiceID }) {
            conversation.choices[index].toolID = event.entity.toolID ?? conversation.choices[index].toolID
            switch payload.choice.result {
            case .accepted:
                conversation.choices[index].domainState = .resolved
                conversation.choices[index].submissionState = .idle
            case .cancelled:
                conversation.choices[index].domainState = .cancelled
                conversation.choices[index].submissionState = .idle
            case .expired:
                conversation.choices[index].domainState = .expired
                conversation.choices[index].submissionState = .idle
            case .rejected:
                conversation.choices[index].submissionState = .rejected
            case .unknown:
                break
            }
            conversation.choices[index].resolvedBy = payload.choice.resolvedBy
            conversation.choices[index].updatedAt = event.observedAt
        } else {
            let choice = ProjectedChoiceState(
                id: choiceID,
                toolID: event.entity.toolID,
                kind: .unknown,
                prompt: nil,
                schema: [:],
                options: [],
                domainState: payload.choice.result == .expired ? .expired : .requested,
                submissionState: payload.choice.result == .rejected ? .rejected : .idle,
                submittedBy: nil,
                resolvedBy: payload.choice.resolvedBy,
                valueShape: nil,
                updatedAt: event.observedAt
            )
            conversation.choices.append(choice)
        }
    }

    private func upsertPlan(
        _ payload: CanonicalPlanUpdatedPayload,
        from event: CanonicalEventEnvelope,
        into conversation: inout ProjectedConversationState
    ) {
        let planID = resolvePlanID(from: event)
        let steps = mergePlanSteps(
            existing: conversation.plans.first(where: { $0.id == planID })?.steps ?? [],
            incoming: payload.plan.steps
        )

        let updated = ProjectedPlanState(
            id: planID,
            text: payload.plan.text,
            steps: steps,
            updatedAt: event.observedAt
        )

        if let index = conversation.plans.firstIndex(where: { $0.id == planID }) {
            conversation.plans[index] = updated
        } else {
            conversation.plans.append(updated)
        }
    }

    private func mergePlanSteps(
        existing: [ProjectedPlanStepState],
        incoming: [CanonicalPlanStep]
    ) -> [ProjectedPlanStepState] {
        var mergedByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        var orderedIDs = existing.map(\.id)

        for step in incoming {
            let projectedID = step.stepID ?? "step-text:\(step.step)"
            let projected = ProjectedPlanStepState(
                id: projectedID,
                sourceStepID: step.stepID,
                step: step.step,
                status: step.status
            )
            if !orderedIDs.contains(projectedID) {
                orderedIDs.append(projectedID)
            }
            mergedByID[projectedID] = projected
        }

        return orderedIDs.compactMap { mergedByID[$0] }
    }

    private func resolveMessageID(from event: CanonicalEventEnvelope, payloadID: String?) -> String {
        if let id = event.entity.messageID, !id.isEmpty { return id }
        if let payloadID, !payloadID.isEmpty { return payloadID }
        let turnToken = event.turn.id ?? "turnless"
        return "synthetic-message:\(event.adapterID.rawValue):\(event.agent.sourceKind.rawValue):\(turnToken)"
    }

    private func resolveToolID(
        from event: CanonicalEventEnvelope,
        payloadID: String?,
        name: String,
        input: [String: AnyCodable]
    ) -> String {
        if let id = event.entity.toolID, !id.isEmpty { return id }
        if let payloadID, !payloadID.isEmpty { return payloadID }
        return "synthetic-tool:\(event.conversation.id):\(event.turn.id ?? "turnless"):\(name):\(stableDictionaryFingerprint(input))"
    }

    private func resolveCompletedToolID(
        in conversation: ProjectedConversationState,
        from event: CanonicalEventEnvelope,
        payload: CanonicalCompletedTool
    ) -> String {
        if let id = event.entity.toolID, !id.isEmpty { return id }
        if let payloadID = payload.id, !payloadID.isEmpty { return payloadID }

        if let activeMatch = conversation.tools.last(where: {
            $0.name == payload.name
                && $0.kind == payload.kind
                && ($0.state == .started || $0.state == .running)
        }) {
            return activeMatch.id
        }

        return resolveToolID(from: event, payloadID: payload.id, name: payload.name, input: [:])
    }

    private func resolveApprovalID(from event: CanonicalEventEnvelope, payloadID: String?) -> String {
        if let id = event.entity.approvalID, !id.isEmpty { return id }
        if let payloadID, !payloadID.isEmpty { return payloadID }
        if let toolID = event.entity.toolID, !toolID.isEmpty { return toolID }
        return "synthetic-approval:\(event.conversation.id):\(event.turn.id ?? "turnless")"
    }

    private func resolveChoiceID(from event: CanonicalEventEnvelope, payloadID: String?) -> String {
        if let id = event.entity.choiceID, !id.isEmpty { return id }
        if let payloadID, !payloadID.isEmpty { return payloadID }
        if let toolID = event.entity.toolID, !toolID.isEmpty { return toolID }
        return "synthetic-choice:\(event.conversation.id):\(event.turn.id ?? "turnless")"
    }

    private func resolvePlanID(from event: CanonicalEventEnvelope) -> String {
        if let id = event.entity.planID, !id.isEmpty { return id }
        return "plan:\(event.conversation.id)"
    }

    private func stableDictionaryFingerprint(_ value: [String: AnyCodable]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "unknown"
        }
        return string
    }

    private func mapToolState(_ status: CanonicalToolCompletedStatus) -> ProjectedToolLifecycleState {
        switch status {
        case .completed:
            return .completed
        case .failed:
            return .failed
        case .declined:
            return .declined
        case .cancelled:
            return .cancelled
        case .timedOut:
            return .timedOut
        case .unknown:
            return .running
        }
    }

    private func mapApprovalState(_ result: CanonicalApprovalResolutionResult) -> ProjectedApprovalDomainState {
        switch result {
        case .accepted:
            return .resolvedAllowed
        case .rejected:
            return .resolvedDenied
        case .cancelled:
            return .resolvedCancelled
        case .expired:
            return .expired
        case .unknown:
            return .requested
        }
    }
}
