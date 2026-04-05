import Foundation
@testable import Claude_Island

enum CanonicalFixtures {
    static let baseDate = Date(timeIntervalSince1970: 1_710_000_000)

    static func agent(sourceKind: CanonicalAgentSourceKind = .hook) -> CanonicalAgentDescriptor {
        CanonicalAgentDescriptor(family: .claude, sourceKind: sourceKind)
    }

    static func conversation(
        id: String = "conversation-1",
        title: String? = "Canonical Foundation",
        cwd: String? = "/tmp/canonical-foundation",
        status: CanonicalConversationStatus = .active
    ) -> CanonicalConversationDescriptor {
        CanonicalConversationDescriptor(id: id, title: title, cwd: cwd, status: status)
    }

    static func turn(
        id: String? = "turn-1",
        status: CanonicalTurnStatus = .inProgress
    ) -> CanonicalTurnDescriptor {
        CanonicalTurnDescriptor(id: id, status: status)
    }

    static func entity(
        messageID: String? = nil,
        toolID: String? = nil,
        approvalID: String? = nil,
        choiceID: String? = nil,
        planID: String? = nil
    ) -> CanonicalEntityDescriptor {
        CanonicalEntityDescriptor(
            messageID: messageID,
            toolID: toolID,
            approvalID: approvalID,
            choiceID: choiceID,
            planID: planID
        )
    }

    static func raw(
        vendorEvent: String,
        vendorPayload: [String: AnyCodable] = ["payload": AnyCodable("value")]
    ) -> CanonicalRawEvent {
        CanonicalRawEvent(vendorEvent: vendorEvent, vendorPayload: vendorPayload)
    }

    static func conversationActiveEvent() -> CanonicalEventEnvelope {
        try! CanonicalEventEnvelope(
            eventID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            type: .conversationActive,
            occurredAt: baseDate,
            observedAt: baseDate,
            adapterID: .claudeCode,
            agent: agent(sourceKind: .hook),
            conversation: conversation(),
            turn: turn(),
            payload: .conversationActive(
                CanonicalConversationActivePayload(status: .active, transition: .created)
            ),
            raw: raw(vendorEvent: "session_start")
        )
    }

    static func messageDeltaEvent(
        messageID: String? = "message-1",
        delta: String = "Hello"
    ) -> CanonicalEventEnvelope {
        try! CanonicalEventEnvelope(
            eventID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            type: .messageDelta,
            occurredAt: baseDate,
            observedAt: baseDate.addingTimeInterval(1),
            adapterID: .claudeCode,
            agent: agent(sourceKind: .stream),
            conversation: conversation(),
            turn: turn(),
            entity: entity(messageID: messageID),
            payload: .messageDelta(
                CanonicalMessageDeltaPayload(
                    message: CanonicalMessageDelta(
                        id: messageID,
                        role: .assistant,
                        format: .markdown,
                        delta: delta
                    )
                )
            ),
            raw: raw(vendorEvent: "message_delta")
        )
    }

    static func messageFinalEvent(
        messageID: String? = "message-1",
        text: String? = "Hello world"
    ) -> CanonicalEventEnvelope {
        try! CanonicalEventEnvelope(
            eventID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            type: .messageFinal,
            occurredAt: baseDate.addingTimeInterval(2),
            observedAt: baseDate.addingTimeInterval(2),
            adapterID: .claudeCode,
            agent: agent(sourceKind: .stream),
            conversation: conversation(),
            turn: turn(status: .completed),
            entity: entity(messageID: messageID),
            payload: .messageFinal(
                CanonicalMessageFinalPayload(
                    message: CanonicalFinalMessage(
                        id: messageID,
                        role: .assistant,
                        format: .markdown,
                        text: text,
                        isFinal: true
                    )
                )
            ),
            raw: raw(vendorEvent: "message_final")
        )
    }

    static func toolStartedEvent(
        toolID: String? = "tool-1",
        conversationID: String = "conversation-1"
    ) -> CanonicalEventEnvelope {
        try! CanonicalEventEnvelope(
            eventID: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            type: .toolCallStarted,
            occurredAt: baseDate.addingTimeInterval(3),
            observedAt: baseDate.addingTimeInterval(3),
            adapterID: .claudeCode,
            agent: agent(sourceKind: .hook),
            conversation: conversation(id: conversationID),
            turn: turn(),
            entity: entity(toolID: toolID),
            payload: .toolCallStarted(
                CanonicalToolCallStartedPayload(
                    tool: CanonicalStartedTool(
                        id: toolID,
                        name: "Bash",
                        kind: .bash,
                        input: ["command": AnyCodable("echo hello")],
                        status: .running
                    )
                )
            ),
            raw: raw(vendorEvent: "tool_started")
        )
    }

    static func toolCompletedEvent(
        toolID: String? = "tool-1",
        conversationID: String = "conversation-1"
    ) -> CanonicalEventEnvelope {
        try! CanonicalEventEnvelope(
            eventID: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
            type: .toolCallCompleted,
            occurredAt: baseDate.addingTimeInterval(4),
            observedAt: baseDate.addingTimeInterval(4),
            adapterID: .claudeCode,
            agent: agent(sourceKind: .hook),
            conversation: conversation(id: conversationID),
            turn: turn(status: .completed),
            entity: entity(toolID: toolID),
            payload: .toolCallCompleted(
                CanonicalToolCallCompletedPayload(
                    tool: CanonicalCompletedTool(
                        id: toolID,
                        name: "Bash",
                        kind: .bash,
                        output: ["stdout": AnyCodable("hello")],
                        status: .completed,
                        errorKind: .unknown
                    )
                )
            ),
            raw: raw(vendorEvent: "tool_completed")
        )
    }

    static func approvalRequestedEvent(
        approvalID: String = "approval-1",
        conversationID: String = "conversation-1"
    ) -> CanonicalEventEnvelope {
        try! CanonicalEventEnvelope(
            eventID: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!,
            type: .approvalRequested,
            occurredAt: baseDate.addingTimeInterval(5),
            observedAt: baseDate.addingTimeInterval(5),
            adapterID: .claudeCode,
            agent: agent(sourceKind: .hook),
            conversation: conversation(id: conversationID),
            turn: turn(),
            entity: entity(toolID: "tool-approval", approvalID: approvalID),
            payload: .approvalRequested(
                CanonicalApprovalRequestedPayload(
                    approval: CanonicalApprovalRequested(
                        id: approvalID,
                        kind: .tool,
                        reason: "Need permission",
                        options: [.allowOnce, .deny],
                        scope: .once,
                        strength: .strong
                    )
                )
            ),
            raw: raw(vendorEvent: "approval_requested")
        )
    }

    static func approvalResolvedEvent(
        approvalID: String = "approval-1",
        result: CanonicalApprovalResolutionResult = .accepted
    ) -> CanonicalEventEnvelope {
        try! CanonicalEventEnvelope(
            eventID: UUID(uuidString: "00000000-0000-0000-0000-000000000007")!,
            type: .approvalResolved,
            occurredAt: baseDate.addingTimeInterval(6),
            observedAt: baseDate.addingTimeInterval(6),
            adapterID: .claudeCode,
            agent: agent(sourceKind: .hook),
            conversation: conversation(),
            turn: turn(status: .completed),
            entity: entity(approvalID: approvalID),
            payload: .approvalResolved(
                CanonicalApprovalResolvedPayload(
                    approval: CanonicalApprovalResolved(
                        id: approvalID,
                        result: result,
                        decision: result == .accepted ? .allowOnce : .deny,
                        scope: .once,
                        resolvedBy: .user
                    )
                )
            ),
            raw: raw(vendorEvent: "approval_resolved")
        )
    }

    static func choiceRequestedEvent(choiceID: String = "choice-1") -> CanonicalEventEnvelope {
        try! CanonicalEventEnvelope(
            eventID: UUID(uuidString: "00000000-0000-0000-0000-000000000008")!,
            type: .userChoiceRequested,
            occurredAt: baseDate.addingTimeInterval(7),
            observedAt: baseDate.addingTimeInterval(7),
            adapterID: .codexCLI,
            agent: CanonicalAgentDescriptor(family: .codex, sourceKind: .api),
            conversation: conversation(id: "conversation-choice"),
            turn: turn(),
            entity: entity(choiceID: choiceID),
            payload: .userChoiceRequested(
                CanonicalUserChoiceRequestedPayload(
                    choice: CanonicalChoiceRequested(
                        id: choiceID,
                        kind: .options,
                        prompt: "Choose an option",
                        schema: ["kind": AnyCodable("options")],
                        options: [AnyCodable("Option A"), AnyCodable("Option B")]
                    )
                )
            ),
            raw: raw(vendorEvent: "choice_requested")
        )
    }

    static func choiceSubmittedEvent(choiceID: String = "choice-1") -> CanonicalEventEnvelope {
        try! CanonicalEventEnvelope(
            eventID: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!,
            type: .userChoiceSubmitted,
            occurredAt: baseDate.addingTimeInterval(8),
            observedAt: baseDate.addingTimeInterval(8),
            adapterID: .codexCLI,
            agent: CanonicalAgentDescriptor(family: .codex, sourceKind: .api),
            conversation: conversation(id: "conversation-choice"),
            turn: turn(),
            entity: entity(choiceID: choiceID),
            payload: .userChoiceSubmitted(
                CanonicalUserChoiceSubmittedPayload(
                    choice: CanonicalChoiceSubmitted(
                        id: choiceID,
                        submissionMode: .programmatic,
                        submittedBy: .user,
                        valueShape: .options
                    )
                )
            ),
            raw: raw(vendorEvent: "choice_submitted")
        )
    }

    static func choiceResolvedEvent(
        choiceID: String = "choice-1",
        result: CanonicalApprovalResolutionResult = .accepted
    ) -> CanonicalEventEnvelope {
        try! CanonicalEventEnvelope(
            eventID: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            type: .userChoiceResolved,
            occurredAt: baseDate.addingTimeInterval(9),
            observedAt: baseDate.addingTimeInterval(9),
            adapterID: .codexCLI,
            agent: CanonicalAgentDescriptor(family: .codex, sourceKind: .api),
            conversation: conversation(id: "conversation-choice"),
            turn: turn(status: .completed),
            entity: entity(choiceID: choiceID),
            payload: .userChoiceResolved(
                CanonicalUserChoiceResolvedPayload(
                    choice: CanonicalChoiceResolved(
                        id: choiceID,
                        result: result,
                        resolvedBy: .runtime
                    )
                )
            ),
            raw: raw(vendorEvent: "choice_resolved")
        )
    }

    static func planUpdatedEvent(planID: String = "plan-1") -> CanonicalEventEnvelope {
        try! CanonicalEventEnvelope(
            eventID: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            type: .planUpdated,
            occurredAt: baseDate.addingTimeInterval(10),
            observedAt: baseDate.addingTimeInterval(10),
            adapterID: .opencode,
            agent: CanonicalAgentDescriptor(family: .opencode, sourceKind: .api),
            conversation: conversation(id: "conversation-plan"),
            turn: turn(),
            entity: entity(planID: planID),
            payload: .planUpdated(
                CanonicalPlanUpdatedPayload(
                    plan: CanonicalPlan(
                        text: "Plan body",
                        steps: [
                            CanonicalPlanStep(stepID: "step-1", step: "Implement", status: .inProgress),
                            CanonicalPlanStep(stepID: nil, step: "Verify", status: .pending)
                        ]
                    )
                )
            ),
            raw: raw(vendorEvent: "plan_updated")
        )
    }

    static func allEvents() -> [CanonicalEventEnvelope] {
        [
            conversationActiveEvent(),
            messageDeltaEvent(),
            messageFinalEvent(),
            toolStartedEvent(),
            toolCompletedEvent(),
            approvalRequestedEvent(),
            approvalResolvedEvent(),
            choiceRequestedEvent(),
            choiceSubmittedEvent(),
            choiceResolvedEvent(),
            planUpdatedEvent()
        ]
    }

    static func allCommands() -> [CanonicalCommandEnvelope] {
        [
            CanonicalCommandEnvelope(
                commandID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                issuedAt: baseDate,
                conversationID: "conversation-1",
                target: CanonicalCommandTarget(adapterID: .claudeCode, entityType: .approval, entityID: "approval-1"),
                type: .approvalResolve,
                mode: .authoritative,
                idempotencyKey: "approval-resolve-1",
                payload: .approvalResolve(
                    CanonicalApprovalResolveCommandPayload(
                        decision: .allowOnce,
                        scope: .once,
                        reason: "Allow once"
                    )
                )
            ),
            CanonicalCommandEnvelope(
                commandID: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
                issuedAt: baseDate,
                conversationID: "conversation-choice",
                target: CanonicalCommandTarget(adapterID: .codexCLI, entityType: .choice, entityID: "choice-1"),
                type: .choiceSubmit,
                mode: .authoritative,
                idempotencyKey: "choice-submit-1",
                payload: .choiceSubmit(
                    CanonicalChoiceSubmitCommandPayload(
                        submittedBy: .user,
                        valueShape: .options,
                        value: ["selection": AnyCodable("Option A")]
                    )
                )
            ),
            CanonicalCommandEnvelope(
                commandID: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
                issuedAt: baseDate,
                conversationID: "conversation-1",
                target: CanonicalCommandTarget(adapterID: .claudeCode, entityType: .session, entityID: "conversation-1"),
                type: .sessionFocus,
                mode: .desktopFallback,
                idempotencyKey: "session-focus-1",
                payload: .sessionFocus(CanonicalSessionCommandPayload(reason: "Focus"))
            ),
            CanonicalCommandEnvelope(
                commandID: UUID(uuidString: "10000000-0000-0000-0000-000000000004")!,
                issuedAt: baseDate,
                conversationID: "conversation-1",
                target: CanonicalCommandTarget(adapterID: .claudeCode, entityType: .session, entityID: "conversation-1"),
                type: .sessionArchive,
                mode: .authoritative,
                idempotencyKey: "session-archive-1",
                payload: .sessionArchive(CanonicalSessionCommandPayload(reason: "Archive"))
            ),
            CanonicalCommandEnvelope(
                commandID: UUID(uuidString: "10000000-0000-0000-0000-000000000005")!,
                issuedAt: baseDate,
                conversationID: "conversation-1",
                target: CanonicalCommandTarget(adapterID: .claudeCode, entityType: .session, entityID: "conversation-1"),
                type: .sessionInterrupt,
                mode: .authoritative,
                idempotencyKey: "session-interrupt-1",
                payload: .sessionInterrupt(CanonicalSessionCommandPayload(reason: "Interrupt"))
            ),
            CanonicalCommandEnvelope(
                commandID: UUID(uuidString: "10000000-0000-0000-0000-000000000006")!,
                issuedAt: baseDate,
                conversationID: "conversation-1",
                target: CanonicalCommandTarget(adapterID: .claudeCode, entityType: .session, entityID: "conversation-1"),
                type: .sessionClear,
                mode: .desktopFallback,
                idempotencyKey: "session-clear-1",
                payload: .sessionClear(
                    CanonicalSessionClearCommandPayload(
                        reason: "Clear",
                        allowProjectionFallback: true
                    )
                )
            )
        ]
    }
}
