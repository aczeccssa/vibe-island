import XCTest
@testable import Claude_Island

final class CanonicalFoundationTests: XCTestCase {
    func testAllCanonicalEventTypesRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for event in CanonicalFixtures.allEvents() {
            let data = try encoder.encode(event)
            let decoded = try decoder.decode(CanonicalEventEnvelope.self, from: data)
            XCTAssertEqual(decoded, event)
        }
    }

    func testAllCanonicalCommandTypesRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for command in CanonicalFixtures.allCommands() {
            let data = try encoder.encode(command)
            let decoded = try decoder.decode(CanonicalCommandEnvelope.self, from: data)
            XCTAssertEqual(decoded, command)
        }
    }

    func testCapabilitySchemaSupportsAllSessionControlAreas() {
        XCTAssertTrue(
            CanonicalSemanticArea.requiredSessionControlAreas.isSubset(of: Set(CanonicalSemanticArea.allCases))
        )
        XCTAssertEqual(CanonicalSemanticArea.requiredSessionControlAreas.count, 4)
    }

    func testEventValidationRejectsEmptyConversationID() {
        XCTAssertThrowsError(
            try CanonicalEventEnvelope(
                type: .conversationActive,
                adapterID: .claudeCode,
                agent: CanonicalFixtures.agent(),
                conversation: CanonicalFixtures.conversation(id: ""),
                payload: .conversationActive(
                    CanonicalConversationActivePayload(status: .active, transition: .created)
                ),
                raw: CanonicalFixtures.raw(vendorEvent: "session_start")
            )
        ) { error in
            XCTAssertEqual(error as? CanonicalEventValidationError, .emptyConversationID)
        }
    }

    func testEventValidationRejectsEmptyRawVendorEvent() {
        XCTAssertThrowsError(
            try CanonicalEventEnvelope(
                type: .conversationActive,
                adapterID: .claudeCode,
                agent: CanonicalFixtures.agent(),
                conversation: CanonicalFixtures.conversation(),
                payload: .conversationActive(
                    CanonicalConversationActivePayload(status: .active, transition: .created)
                ),
                raw: CanonicalRawEvent(vendorEvent: "", vendorPayload: [:])
            )
        ) { error in
            XCTAssertEqual(error as? CanonicalEventValidationError, .emptyRawVendorEvent)
        }
    }

    func testEventBusDeduplicatesExactLogicalDuplicates() async throws {
        let bus = CanonicalEventBus()
        let first = CanonicalFixtures.messageDeltaEvent(delta: "Hello")
        let duplicate = try CanonicalEventEnvelope(
            eventID: CanonicalFixtures.fixtureUUID("20000000-0000-0000-0000-000000000001"),
            type: first.type,
            occurredAt: first.occurredAt,
            observedAt: first.observedAt.addingTimeInterval(30),
            sourceSeq: first.sourceSeq,
            causationID: first.causationID,
            supersedesEventID: first.supersedesEventID,
            adapterID: first.adapterID,
            agent: first.agent,
            conversation: first.conversation,
            turn: first.turn,
            entity: first.entity,
            payload: first.payload,
            raw: first.raw
        )

        let firstResult = try await bus.publish(first)
        let duplicateResult = try await bus.publish(duplicate)
        let history = await bus.history()

        XCTAssertEqual(firstResult, .published)
        XCTAssertEqual(duplicateResult, .duplicateIgnored)
        XCTAssertEqual(history.count, 1)
    }

    func testEventBusPreservesOrderedFanout() async throws {
        let bus = CanonicalEventBus()
        let first = CanonicalFixtures.messageDeltaEvent(delta: "Hello")
        let second = CanonicalFixtures.messageFinalEvent(text: "Hello world")
        let stream = await bus.subscribe()

        let collector = Task { () -> [CanonicalEventEnvelope] in
            var iterator = stream.makeAsyncIterator()
            var received: [CanonicalEventEnvelope] = []
            if let first = await iterator.next() { received.append(first) }
            if let second = await iterator.next() { received.append(second) }
            return received
        }

        _ = try await bus.publish(first)
        _ = try await bus.publish(second)

        let received = await collector.value
        XCTAssertEqual(received.map(\.eventID), [first.eventID, second.eventID])
    }

    func testEventBusBoundsFingerprintRetentionPerLogicalKey() async throws {
        let bus = CanonicalEventBus()
        let baseline = CanonicalFixtures.messageDeltaEvent(delta: "baseline")
        let baseDate = CanonicalFixtures.baseDate

        for index in 0..<80 {
            let event = try CanonicalEventEnvelope(
                eventID: UUID(),
                type: .messageDelta,
                occurredAt: baseDate.addingTimeInterval(TimeInterval(index)),
                observedAt: baseDate.addingTimeInterval(TimeInterval(index)),
                sourceSeq: baseline.sourceSeq,
                causationID: baseline.causationID,
                supersedesEventID: baseline.supersedesEventID,
                adapterID: baseline.adapterID,
                agent: baseline.agent,
                conversation: baseline.conversation,
                turn: baseline.turn,
                entity: baseline.entity,
                payload: .messageDelta(
                    CanonicalMessageDeltaPayload(
                        message: CanonicalMessageDelta(
                            id: baseline.entity.messageID,
                            role: .assistant,
                            format: .markdown,
                            delta: "delta-\(index)"
                        )
                    )
                ),
                raw: CanonicalRawEvent(
                    vendorEvent: "message_delta",
                    vendorPayload: ["payload": AnyCodable("delta-\(index)")]
                )
            )
            _ = try await bus.publish(event)
        }

        let fingerprintCount = await bus.fingerprintCount(for: baseline)
        XCTAssertEqual(fingerprintCount, 64)
    }

    func testEventBusBoundsDedupeKeyCardinality() async throws {
        let bus = CanonicalEventBus()

        for index in 0..<2100 {
            let event = try CanonicalEventEnvelope(
                eventID: UUID(),
                type: .messageDelta,
                occurredAt: CanonicalFixtures.baseDate.addingTimeInterval(TimeInterval(index)),
                observedAt: CanonicalFixtures.baseDate.addingTimeInterval(TimeInterval(index)),
                adapterID: .claudeCode,
                agent: CanonicalFixtures.agent(),
                conversation: CanonicalFixtures.conversation(id: "conversation-\(index)"),
                turn: CanonicalFixtures.turn(),
                entity: CanonicalFixtures.entity(messageID: "message-\(index)"),
                payload: .messageDelta(
                    CanonicalMessageDeltaPayload(
                        message: CanonicalMessageDelta(
                            id: "message-\(index)",
                            role: .assistant,
                            format: .markdown,
                            delta: "delta-\(index)"
                        )
                    )
                ),
                raw: CanonicalRawEvent(
                    vendorEvent: "message_delta",
                    vendorPayload: ["payload": AnyCodable("delta-\(index)")]
                )
            )
            _ = try await bus.publish(event)
        }

        let dedupeKeyCount = await bus.dedupeKeyCount()
        XCTAssertEqual(dedupeKeyCount, 2048)
    }

    func testProjectionStoreMessageDeltaThenFinalSupersedesAccumulatedText() async {
        let store = SessionProjectionStore()
        await store.apply(CanonicalFixtures.messageDeltaEvent(delta: "Hel"))
        await store.apply(CanonicalFixtures.messageDeltaEvent(delta: "lo"))
        await store.apply(CanonicalFixtures.messageFinalEvent(text: "Hello world"))

        let snapshot = await store.snapshot()
        let conversation = snapshot.conversations["conversation-1"]
        XCTAssertEqual(conversation?.messages.count, 1)
        XCTAssertEqual(conversation?.messages.first?.text, "Hello world")
        XCTAssertEqual(conversation?.messages.first?.isFinal, true)
    }

    func testProjectionStoreMessageFinalWithoutTextPreservesAccumulatedText() async {
        let store = SessionProjectionStore()
        await store.apply(CanonicalFixtures.messageDeltaEvent(delta: "Hel"))
        await store.apply(CanonicalFixtures.messageDeltaEvent(delta: "lo"))
        await store.apply(CanonicalFixtures.messageFinalEvent(text: nil))

        let snapshot = await store.snapshot()
        let conversation = snapshot.conversations["conversation-1"]
        XCTAssertEqual(conversation?.messages.count, 1)
        XCTAssertEqual(conversation?.messages.first?.text, "Hello")
        XCTAssertEqual(conversation?.messages.first?.isFinal, true)
    }

    func testProjectionStoreToolStartedThenCompletedMergesSingleTool() async {
        let store = SessionProjectionStore()
        await store.apply(CanonicalFixtures.toolStartedEvent(toolID: "tool-merge"))
        await store.apply(CanonicalFixtures.toolCompletedEvent(toolID: "tool-merge"))

        let snapshot = await store.snapshot()
        let tool = snapshot.conversations["conversation-1"]?.tools.first
        XCTAssertEqual(snapshot.conversations["conversation-1"]?.tools.count, 1)
        XCTAssertEqual(tool?.state, .completed)
        XCTAssertEqual(tool?.output["stdout"], AnyCodable("hello"))
    }

    func testProjectionStoreToolWithoutExplicitIDStillMergesCompletionIntoStartedTool() async {
        let store = SessionProjectionStore()
        await store.apply(CanonicalFixtures.toolStartedEvent(toolID: nil))
        await store.apply(CanonicalFixtures.toolCompletedEvent(toolID: nil))

        let snapshot = await store.snapshot()
        let tool = snapshot.conversations["conversation-1"]?.tools.first
        XCTAssertEqual(snapshot.conversations["conversation-1"]?.tools.count, 1)
        XCTAssertEqual(tool?.state, .completed)
        XCTAssertEqual(tool?.output["stdout"], AnyCodable("hello"))
    }

    func testProjectionStoreApprovalLifecycleIncludesExpired() async {
        let store = SessionProjectionStore()
        await store.apply(CanonicalFixtures.approvalRequestedEvent(approvalID: "approval-expired"))
        await store.apply(
            CanonicalFixtures.approvalResolvedEvent(
                approvalID: "approval-expired",
                result: .expired
            )
        )

        let snapshot = await store.snapshot()
        let approval = snapshot.conversations["conversation-1"]?.approvals.first
        XCTAssertEqual(approval?.domainState, .expired)
        XCTAssertEqual(approval?.submissionState, .idle)
    }

    func testProjectionStoreChoiceLifecycleAndSubmissionStates() async {
        let store = SessionProjectionStore()
        let requested = CanonicalFixtures.choiceRequestedEvent(choiceID: "choice-submission")
        await store.apply(requested)

        let command = CanonicalCommandEnvelope(
            commandID: CanonicalFixtures.fixtureUUID("30000000-0000-0000-0000-000000000001"),
            issuedAt: CanonicalFixtures.baseDate,
            conversationID: requested.conversation.id,
            target: CanonicalCommandTarget(
                adapterID: .codexCLI,
                entityType: .choice,
                entityID: "choice-submission"
            ),
            type: .choiceSubmit,
            mode: .authoritative,
            idempotencyKey: "choice-submission",
            payload: .choiceSubmit(
                CanonicalChoiceSubmitCommandPayload(
                    submittedBy: .user,
                    valueShape: .options,
                    value: ["selection": AnyCodable("Option A")]
                )
            )
        )

        await store.apply(
            CanonicalCommandDispatchResult(
                commandID: command.commandID,
                adapterID: .codexCLI,
                status: .accepted
            ),
            for: command
        )
        await store.apply(CanonicalFixtures.choiceSubmittedEvent(choiceID: "choice-submission"))
        await store.apply(
            CanonicalFixtures.choiceResolvedEvent(
                choiceID: "choice-submission",
                result: .rejected
            )
        )
        await store.apply(
            CanonicalCommandDispatchResult(
                commandID: command.commandID,
                adapterID: .codexCLI,
                status: .unsupported
            ),
            for: command
        )
        await store.apply(
            CanonicalCommandDispatchResult(
                commandID: command.commandID,
                adapterID: .codexCLI,
                status: .timedOut
            ),
            for: command
        )
        await store.apply(
            CanonicalCommandDispatchResult(
                commandID: command.commandID,
                adapterID: .codexCLI,
                status: .accepted
            ),
            for: command
        )
        await store.apply(
            CanonicalFixtures.choiceResolvedEvent(
                choiceID: "choice-submission",
                result: .accepted
            )
        )

        let snapshot = await store.snapshot()
        let choice = snapshot.conversations["conversation-choice"]?.choices.first
        XCTAssertEqual(choice?.domainState, .resolved)
        XCTAssertEqual(choice?.submissionState, .idle)
    }

    func testProjectionStoreRejectedChoiceKeepsDomainOpenForRetry() async {
        let store = SessionProjectionStore()
        await store.apply(CanonicalFixtures.choiceRequestedEvent(choiceID: "choice-rejected"))
        await store.apply(CanonicalFixtures.choiceSubmittedEvent(choiceID: "choice-rejected"))
        await store.apply(
            CanonicalFixtures.choiceResolvedEvent(
                choiceID: "choice-rejected",
                result: .rejected
            )
        )

        let snapshot = await store.snapshot()
        let choice = snapshot.conversations["conversation-choice"]?.choices.first
        XCTAssertEqual(choice?.domainState, .requested)
        XCTAssertEqual(choice?.submissionState, .rejected)
    }

    func testProjectionStorePlanStepMergeUsesStepIDOrText() async {
        let store = SessionProjectionStore()
        await store.apply(CanonicalFixtures.planUpdatedEvent(planID: "plan-merge"))

        let secondPlan = CanonicalFixtures.makeEvent {
            try CanonicalEventEnvelope(
            eventID: CanonicalFixtures.fixtureUUID("40000000-0000-0000-0000-000000000001"),
            type: .planUpdated,
            occurredAt: CanonicalFixtures.baseDate.addingTimeInterval(30),
            observedAt: CanonicalFixtures.baseDate.addingTimeInterval(30),
            adapterID: .opencode,
            agent: CanonicalAgentDescriptor(family: .opencode, sourceKind: .api),
            conversation: CanonicalFixtures.conversation(id: "conversation-plan"),
            turn: CanonicalFixtures.turn(),
            entity: CanonicalFixtures.entity(planID: "plan-merge"),
            payload: .planUpdated(
                CanonicalPlanUpdatedPayload(
                    plan: CanonicalPlan(
                        text: "Updated plan body",
                        steps: [
                            CanonicalPlanStep(stepID: "step-1", step: "Implement", status: .completed),
                            CanonicalPlanStep(stepID: nil, step: "Verify", status: .inProgress),
                            CanonicalPlanStep(stepID: "step-2", step: "Ship", status: .pending)
                        ]
                    )
                )
            ),
            raw: CanonicalFixtures.raw(vendorEvent: "plan_updated")
            )
        }
        await store.apply(secondPlan)

        let snapshot = await store.snapshot()
        let steps = snapshot.conversations["conversation-plan"]?.plans.first?.steps ?? []
        XCTAssertEqual(steps.count, 3)
        XCTAssertEqual(steps.first(where: { $0.id == "step-1" })?.status, .completed)
        XCTAssertEqual(steps.first(where: { $0.id == "step-text:Verify" })?.status, .inProgress)
    }

    func testCompatibilityProjectorProducesParitySnapshot() async {
        let store = SessionProjectionStore()
        await store.apply(CanonicalFixtures.messageFinalEvent(text: "Last message"))
        await store.apply(CanonicalFixtures.toolStartedEvent(toolID: "tool-running"))
        await store.apply(CanonicalFixtures.approvalRequestedEvent(approvalID: "approval-parity"))

        let compatibility = CompatibilityStateProjector.project(await store.snapshot())
        XCTAssertEqual(compatibility.paritySnapshot.sessionCount, 1)
        XCTAssertEqual(compatibility.paritySnapshot.activeApprovalToolUseIDs["conversation-1"], "tool-approval")
        XCTAssertEqual(compatibility.paritySnapshot.pendingInteractionCounts["conversation-1"], 1)
        XCTAssertEqual(compatibility.paritySnapshot.chatItemCounts["conversation-1"], 3) // 1 message + 1 tool + 1 synthetic interaction item
        XCTAssertEqual(compatibility.paritySnapshot.inProgressToolCounts["conversation-1"], 1)
        XCTAssertTrue(compatibility.paritySnapshot.attentionSessionIDs.contains("conversation-1"))
    }

    func testProjectionBootstrapArchiveSessionMarksCanonicalConversationArchived() async {
        await ProjectionBootstrap.shared.stop()
        await ProjectionBootstrap.shared.start(mode: .live)

        await ProjectionBootstrap.shared.handleProcessDetected(
            sessionID: "conversation-archived",
            cwd: "/tmp/archive-status",
            agentID: "codex",
            pid: nil,
            tty: nil
        )

        await ProjectionBootstrap.shared.archiveSession("conversation-archived")

        let snapshot = await ProjectionBootstrap.shared.projectionStore.snapshot()
        let uiSessions = await ProjectionBootstrap.shared.uiSessions()

        XCTAssertEqual(snapshot.conversations["conversation-archived"]?.status, .archived)
        XCTAssertFalse(uiSessions.contains(where: { $0.sessionID == "conversation-archived" }))

        await ProjectionBootstrap.shared.stop()
    }

    func testRuntimeCutoverDefaultsPreserveCurrentLiveBehavior() {
        let flags = EventBusFeatureFlags(environment: [:], defaults: UserDefaults(suiteName: #function)!)
        let configuration = RuntimeOrchestrator.liveCutoverConfiguration(for: .live, flags: flags)

        XCTAssertEqual(configuration.activeAdapterIDs, Set(RuntimeAdapterID.allCases))
        XCTAssertTrue(configuration.enablesCanonicalProjectionLiveIngress)
    }

    func testRuntimeCutoverHonorsExplicitAdapterAndProjectionFlags() {
        let flags = EventBusFeatureFlags(
            environment: [
                "VIBE_ISLAND_ENABLE_CODEX_CLI_ADAPTER_PATH": "true",
                "VIBE_ISLAND_ENABLE_CANONICAL_PROJECTION_PATH": "true"
            ],
            defaults: UserDefaults(suiteName: #function)!
        )
        let configuration = RuntimeOrchestrator.liveCutoverConfiguration(for: .live, flags: flags)

        XCTAssertEqual(configuration.activeAdapterIDs, [.codexCLI])
        XCTAssertTrue(configuration.enablesCanonicalProjectionLiveIngress)
    }

    func testCompatibilityProjectorUsesToolOrInteractionIDsAndBinaryPendingCount() async {
        let snapshot = SessionProjectionSnapshot(
            conversations: [
                "conversation-compat": ProjectedConversationState(
                    id: "conversation-compat",
                    adapterID: .codexCLI,
                    familyID: .codex,
                    sourceKind: .api,
                    title: "Compatibility",
                    cwd: "/tmp/compatibility",
                    status: .active,
                    lastTransition: .created,
                    turn: CanonicalFixtures.turn(),
                    messages: [],
                    tools: [],
                    approvals: [
                        ProjectedApprovalState(
                            id: "approval-entity",
                            toolID: "tool-use-123",
                            kind: .tool,
                            reason: nil,
                            options: [.allowOnce],
                            scope: .once,
                            strength: .strong,
                            domainState: .requested,
                            submissionState: .idle,
                            resolvedBy: nil,
                            updatedAt: CanonicalFixtures.baseDate
                        )
                    ],
                    choices: [
                        ProjectedChoiceState(
                            id: "choice-entity",
                            toolID: "interaction-tool-456",
                            kind: .options,
                            prompt: "Choose",
                            schema: [:],
                            options: [],
                            domainState: .requested,
                            submissionState: .submissionPending,
                            submittedBy: nil,
                            resolvedBy: nil,
                            valueShape: nil,
                            updatedAt: CanonicalFixtures.baseDate.addingTimeInterval(1)
                        )
                    ],
                    plans: [],
                    sessionCommandSubmissionStates: [:],
                    lastUpdatedAt: CanonicalFixtures.baseDate.addingTimeInterval(1)
                )
            ],
            capabilities: [:]
        )

        let compatibility = CompatibilityStateProjector.project(snapshot)
        XCTAssertEqual(compatibility.paritySnapshot.activeApprovalToolUseIDs["conversation-compat"], "tool-use-123")
        XCTAssertEqual(compatibility.paritySnapshot.activeChoiceIDs["conversation-compat"], "interaction-tool-456")
        XCTAssertEqual(compatibility.paritySnapshot.pendingInteractionCounts["conversation-compat"], 1)
    }

    func testProjectedUIStateDerivesFromProjectionSnapshot() async {
        let store = SessionProjectionStore()
        await store.apply(CanonicalFixtures.messageFinalEvent(text: "UI message"))
        await store.apply(CanonicalFixtures.approvalRequestedEvent(approvalID: "approval-ui"))

        let command = CanonicalCommandEnvelope(
            commandID: CanonicalFixtures.fixtureUUID("50000000-0000-0000-0000-000000000001"),
            issuedAt: CanonicalFixtures.baseDate,
            conversationID: "conversation-1",
            target: CanonicalCommandTarget(adapterID: .claudeCode, entityType: .session, entityID: "conversation-1"),
            type: .sessionFocus,
            mode: .desktopFallback,
            idempotencyKey: "focus-ui",
            payload: .sessionFocus(CanonicalSessionCommandPayload(reason: "Focus"))
        )
        await store.apply(
            CanonicalCommandDispatchResult(
                commandID: command.commandID,
                adapterID: .claudeCode,
                status: .unsupported
            ),
            for: command
        )

        let state = ProjectedUIState(snapshot: await store.snapshot())
        XCTAssertEqual(state.sessionList.count, 1)
        XCTAssertEqual(state.chatPanels["conversation-1"]?.messages.first?.text, "UI message")
        XCTAssertNotNil(state.interactionSurfaces["conversation-1:approval:approval-ui"])
        XCTAssertEqual(
            state.commandFeedback["conversation-1:session.focus"]?.submissionState,
            .unsupported
        )
    }

    func testProjectedUIStateKeepsRejectedChoiceVisibleForRetry() async {
        let snapshot = SessionProjectionSnapshot(
            conversations: [
                "conversation-choice": ProjectedConversationState(
                    id: "conversation-choice",
                    adapterID: .codexCLI,
                    familyID: .codex,
                    sourceKind: .api,
                    title: "Choice Retry",
                    cwd: "/tmp/choice-retry",
                    status: .active,
                    lastTransition: .created,
                    turn: CanonicalFixtures.turn(),
                    messages: [],
                    tools: [],
                    approvals: [],
                    choices: [
                        ProjectedChoiceState(
                            id: "choice-rejected",
                            toolID: "tool-choice-rejected",
                            kind: .options,
                            prompt: "Try again",
                            schema: [:],
                            options: [],
                            domainState: .requested,
                            submissionState: .rejected,
                            submittedBy: .user,
                            resolvedBy: .adapter,
                            valueShape: .options,
                            updatedAt: CanonicalFixtures.baseDate
                        )
                    ],
                    plans: [],
                    sessionCommandSubmissionStates: [:],
                    lastUpdatedAt: CanonicalFixtures.baseDate
                )
            ],
            capabilities: [:]
        )

        let state = ProjectedUIState(snapshot: snapshot)
        XCTAssertEqual(state.sessionList.first?.pendingInteractionCount, 1)
        XCTAssertTrue(state.sessionList.first?.needsAttention == true)
        XCTAssertNotNil(state.interactionSurfaces["conversation-choice:choice:choice-rejected"])
    }

    func testProjectedUIStateNamespacesInteractionSurfaceIDsByConversation() async {
        let store = SessionProjectionStore()
        await store.apply(
            CanonicalFixtures.approvalRequestedEvent(
                approvalID: "approval-shared",
                conversationID: "conversation-1"
            )
        )
        await store.apply(
            CanonicalFixtures.approvalRequestedEvent(
                approvalID: "approval-shared",
                conversationID: "conversation-2"
            )
        )

        let state = ProjectedUIState(snapshot: await store.snapshot())
        XCTAssertEqual(state.interactionSurfaces.count, 2)
        XCTAssertNotNil(state.interactionSurfaces["conversation-1:approval:approval-shared"])
        XCTAssertNotNil(state.interactionSurfaces["conversation-2:approval:approval-shared"])
    }

    func testProjectionBootstrapFixturePublishesCompatibilitySessions() async throws {
        await ProjectionBootstrap.shared.stop()
        defer {
            Task {
                await ProjectionBootstrap.shared.stop()
            }
        }

        let timestamp = CanonicalFixtures.baseDate
        let snapshot = SessionProjectionSnapshot(
            conversations: [
                "conversation-fixture": ProjectedConversationState(
                    id: "conversation-fixture",
                    adapterID: .claudeCode,
                    familyID: .claude,
                    sourceKind: .hook,
                    title: "Fixture Session",
                    cwd: "/tmp/fixture-session",
                    status: .active,
                    lastTransition: .created,
                    turn: CanonicalFixtures.turn(),
                    messages: [
                        ProjectedMessageState(
                            id: "message-1",
                            turnID: "turn-1",
                            role: .assistant,
                            format: .markdown,
                            text: "Hello from fixture",
                            isFinal: true,
                            sourceKind: .hook,
                            updatedAt: timestamp
                        )
                    ],
                    tools: [
                        ProjectedToolState(
                            id: "tool-1",
                            name: "Bash",
                            kind: .bash,
                            input: ["command": AnyCodable("echo fixture")],
                            output: ["text": AnyCodable("fixture output")],
                            state: .completed,
                            errorKind: nil,
                            updatedAt: timestamp
                        )
                    ],
                    approvals: [],
                    choices: [],
                    plans: [],
                    sessionCommandSubmissionStates: [:],
                    lastUpdatedAt: timestamp
                )
            ],
            capabilities: [:]
        )

        let document = ProjectionFixtureDocument(
            snapshot: snapshot,
            sessions: [
                .init(
                    sessionID: "conversation-fixture",
                    agentID: "claude",
                    pid: 123,
                    tty: "ttys001",
                    isInTmux: true,
                    lastActivity: timestamp,
                    createdAt: timestamp
                )
            ]
        )

        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(CanonicalTimestampCoding.string(from: date))
        }
        try encoder.encode(document).write(to: fixtureURL)

        await ProjectionBootstrap.shared.start(
            mode: .projectedFixture(
                .init(
                    fixturePath: fixtureURL.path,
                    initialContent: .chat(sessionID: "conversation-fixture")
                )
            )
        )

        let sessions = await ProjectionBootstrap.shared.uiSessions()
        let fixtureBootSessionID = await ProjectionBootstrap.shared.fixtureBootSessionID()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.sessionID, "conversation-fixture")
        XCTAssertEqual(sessions.first?.timeline.count, 2)
        XCTAssertEqual(sessions.first?.displayTitle, "Fixture Session")
        XCTAssertEqual(fixtureBootSessionID, "conversation-fixture")
    }

    func testProjectionBootstrapFixtureRegistersShadowParitySnapshot() async throws {
        await ProjectionBootstrap.shared.stop()
        ShadowDiffLogger.updateProjectedSnapshot(nil)
        defer {
            Task {
                await ProjectionBootstrap.shared.stop()
                ShadowDiffLogger.updateProjectedSnapshot(nil)
            }
        }

        let timestamp = CanonicalFixtures.baseDate
        let snapshot = SessionProjectionSnapshot(
            conversations: [
                "conversation-fixture": ProjectedConversationState(
                    id: "conversation-fixture",
                    adapterID: .claudeCode,
                    familyID: .claude,
                    sourceKind: .hook,
                    title: "Fixture Session",
                    cwd: "/tmp/fixture-session",
                    status: .active,
                    lastTransition: .created,
                    turn: CanonicalFixtures.turn(),
                    messages: [],
                    tools: [],
                    approvals: [
                        ProjectedApprovalState(
                            id: "approval-fixture",
                            toolID: "tool-fixture",
                            kind: .tool,
                            reason: nil,
                            options: [.allowOnce],
                            scope: .once,
                            strength: .strong,
                            domainState: .requested,
                            submissionState: .idle,
                            resolvedBy: nil,
                            updatedAt: timestamp
                        )
                    ],
                    choices: [],
                    plans: [],
                    sessionCommandSubmissionStates: [:],
                    lastUpdatedAt: timestamp
                )
            ],
            capabilities: [:]
        )

        let document = ProjectionFixtureDocument(
            snapshot: snapshot,
            sessions: [
                .init(
                    sessionID: "conversation-fixture",
                    agentID: "claude",
                    pid: 123,
                    tty: "ttys001",
                    isInTmux: true,
                    lastActivity: timestamp,
                    createdAt: timestamp
                )
            ]
        )

        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(CanonicalTimestampCoding.string(from: date))
        }
        try encoder.encode(document).write(to: fixtureURL)

        await ProjectionBootstrap.shared.start(
            mode: .projectedFixture(
                .init(
                    fixturePath: fixtureURL.path,
                    initialContent: .instances
                )
            )
        )

        let paritySnapshot = ShadowDiffLogger.projectedSnapshotForTesting()
        XCTAssertEqual(paritySnapshot?.sessionCount, 1)
        XCTAssertEqual(paritySnapshot?.activeApprovalToolUseIDs["conversation-fixture"], "tool-fixture")
        XCTAssertEqual(paritySnapshot?.pendingInteractionCounts["conversation-fixture"], 1)
    }
}
