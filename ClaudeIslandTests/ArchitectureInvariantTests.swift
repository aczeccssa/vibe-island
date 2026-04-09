import Foundation
import XCTest
@testable import Claude_Island

final class ArchitectureInvariantTests: XCTestCase {
    func testCanonicalEventEnvelopePreservesRawVendorPayload() throws {
        let event = try CanonicalEventEnvelope(
            eventID: CanonicalFixtures.fixtureUUID("70000000-0000-0000-0000-000000000001"),
            type: .messageFinal,
            occurredAt: CanonicalFixtures.baseDate,
            observedAt: CanonicalFixtures.baseDate.addingTimeInterval(1),
            adapterID: .claudeCode,
            agent: CanonicalFixtures.agent(sourceKind: .hook),
            conversation: CanonicalFixtures.conversation(),
            turn: CanonicalFixtures.turn(status: .completed),
            entity: CanonicalFixtures.entity(messageID: "raw-preserved-message"),
            payload: .messageFinal(
                CanonicalMessageFinalPayload(
                    message: CanonicalFinalMessage(
                        id: "raw-preserved-message",
                        role: .assistant,
                        format: .json,
                        text: "{\"ok\":true}",
                        isFinal: true
                    )
                )
            ),
            raw: CanonicalRawEvent(
                vendorEvent: "message_final",
                vendorPayload: [
                    "string": AnyCodable("value"),
                    "number": AnyCodable(42),
                    "array": AnyCodable(["a", "b"]),
                    "object": AnyCodable(["nested": "yes"])
                ]
            )
        )

        let encoded = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(CanonicalEventEnvelope.self, from: encoded)

        XCTAssertEqual(decoded.raw.vendorPayload["string"], AnyCodable("value"))
        XCTAssertEqual(decoded.raw.vendorPayload["number"], AnyCodable(42))
        XCTAssertEqual(decoded.raw.vendorPayload["array"], AnyCodable(["a", "b"]))
        XCTAssertEqual(decoded.raw.vendorPayload["object"], AnyCodable(["nested": "yes"]))
    }

    func testCanonicalEventEnvelopeDecodingFailsWithoutAdapterID() throws {
        let event = CanonicalFixtures.conversationActiveEvent()
        let encoded = try JSONEncoder().encode(event)
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        json.removeValue(forKey: "adapter_id")

        let mutated = try JSONSerialization.data(withJSONObject: json)

        XCTAssertThrowsError(try JSONDecoder().decode(CanonicalEventEnvelope.self, from: mutated))
    }

    func testCommandRouterDispatchesByAdapterID() async {
        let router = CommandRouter()

        await router.registerHandler(for: .claudeCode) { command in
            CanonicalCommandDispatchResult(
                commandID: command.commandID,
                adapterID: .claudeCode,
                status: .accepted,
                notes: "claude"
            )
        }
        await router.registerHandler(for: .codexCLI) { command in
            CanonicalCommandDispatchResult(
                commandID: command.commandID,
                adapterID: .codexCLI,
                status: .rejected,
                notes: "codex"
            )
        }

        let claudeResult = await router.dispatch(
            CanonicalCommandEnvelope(
                commandID: CanonicalFixtures.fixtureUUID("70000000-0000-0000-0000-000000000002"),
                issuedAt: CanonicalFixtures.baseDate,
                conversationID: "conversation-1",
                target: CanonicalCommandTarget(
                    adapterID: .claudeCode,
                    entityType: .session,
                    entityID: "conversation-1"
                ),
                type: .sessionFocus,
                mode: .authoritative,
                idempotencyKey: "claude-route",
                payload: .sessionFocus(CanonicalSessionCommandPayload(reason: "route claude"))
            )
        )
        let codexResult = await router.dispatch(
            CanonicalCommandEnvelope(
                commandID: CanonicalFixtures.fixtureUUID("70000000-0000-0000-0000-000000000003"),
                issuedAt: CanonicalFixtures.baseDate,
                conversationID: "conversation-1",
                target: CanonicalCommandTarget(
                    adapterID: .codexCLI,
                    entityType: .session,
                    entityID: "conversation-1"
                ),
                type: .sessionFocus,
                mode: .authoritative,
                idempotencyKey: "codex-route",
                payload: .sessionFocus(CanonicalSessionCommandPayload(reason: "route codex"))
            )
        )

        XCTAssertEqual(claudeResult.adapterID, .claudeCode)
        XCTAssertEqual(claudeResult.status, .accepted)
        XCTAssertEqual(claudeResult.notes, "claude")
        XCTAssertEqual(codexResult.adapterID, .codexCLI)
        XCTAssertEqual(codexResult.status, .rejected)
        XCTAssertEqual(codexResult.notes, "codex")
    }

    func testCanonicalProjectionAndModernUIStateHaveNoSessionStoreDependency() throws {
        let repoRoot = repoRootURL()
        let targetDirectories = [
            repoRoot.appendingPathComponent("ClaudeIsland/Models/Canonical"),
            repoRoot.appendingPathComponent("ClaudeIsland/Services/Projection"),
            repoRoot.appendingPathComponent("ClaudeIsland/UI/State")
        ]

        try assertNoForbiddenTokens(
            in: targetDirectories,
            forbiddenTokens: ["SessionStore", "SessionEvent"]
        )
    }

    func testProjectionAndModernUIStateDoNotBridgeBackToLegacyCarriers() throws {
        let repoRoot = repoRootURL()
        let targetFiles = [
            repoRoot.appendingPathComponent("ClaudeIsland/Services/Projection/SessionProjectionStore.swift"),
            repoRoot.appendingPathComponent("ClaudeIsland/Services/Projection/CompatibilityStateProjector.swift"),
            repoRoot.appendingPathComponent("ClaudeIsland/UI/State/ProjectedUIStateStore.swift"),
            repoRoot.appendingPathComponent("ClaudeIsland/Services/Projection/ProjectionBootstrap.swift"),
            repoRoot.appendingPathComponent("ClaudeIsland/Services/Session/ClaudeSessionMonitor.swift"),
            repoRoot.appendingPathComponent("ClaudeIsland/UI/Views/NotchView.swift"),
            repoRoot.appendingPathComponent("ClaudeIsland/UI/Views/ChatView.swift"),
            repoRoot.appendingPathComponent("ClaudeIsland/UI/Views/ClaudeInstancesView.swift")
        ]

        try assertNoForbiddenTokens(
            inFiles: targetFiles,
            forbiddenTokens: [
                "SessionState",
                "ChatHistoryItem",
                "SessionInteractionRequest",
                "PermissionContext"
            ]
        )
    }

    func testSessionProjectionStorePublishSnapshotDoesNotInvokePhase0Diagnostics() throws {
        let repoRoot = repoRootURL()
        let storeFile = repoRoot.appendingPathComponent(
            "ClaudeIsland/Services/Projection/SessionProjectionStore.swift"
        )
        let content = try String(contentsOf: storeFile, encoding: .utf8)

        let methodStart = try XCTUnwrap(content.range(of: "    private func publishSnapshot() {"))
        let methodBody = String(content[methodStart.lowerBound...])

        XCTAssertFalse(
            methodBody.contains("ShadowDiffLogger"),
            "publishSnapshot() must not call ShadowDiffLogger."
        )
        XCTAssertFalse(
            methodBody.contains("ParityLogger"),
            "publishSnapshot() must not call ParityLogger."
        )
    }

    func testProjectionBootstrapOwnsShadowDiffRegistrationInsteadOfStore() throws {
        let repoRoot = repoRootURL()
        let bootstrapFile = repoRoot.appendingPathComponent(
            "ClaudeIsland/Services/Projection/ProjectionBootstrap.swift"
        )
        let content = try String(contentsOf: bootstrapFile, encoding: .utf8)

        XCTAssertTrue(
            content.contains("ShadowDiffLogger.updateProjectedSnapshot"),
            "ProjectionBootstrap must register projected parity snapshots for Phase 0 shadow diff."
        )
    }

    func testProjectionBootstrapRefreshesUICacheBeforePublishingSnapshots() throws {
        let repoRoot = repoRootURL()
        let bootstrapFile = repoRoot.appendingPathComponent(
            "ClaudeIsland/Services/Projection/ProjectionBootstrap.swift"
        )
        let content = try String(contentsOf: bootstrapFile, encoding: .utf8)

        let rebuildCache = try XCTUnwrap(
            content.range(of: "cachedUISessionsByID = buildUISessions(\n            snapshot: snapshot,")
        )
        let rebuildPublish = try XCTUnwrap(
            content.range(of: "await projectionStore.replaceSnapshot(snapshot)")
        )
        XCTAssertLessThan(rebuildCache.lowerBound, rebuildPublish.lowerBound)

        let fixtureCache = try XCTUnwrap(
            content.range(of: "cachedUISessionsByID = buildUISessions(\n                snapshot: fixture.snapshot,")
        )
        let fixturePublish = try XCTUnwrap(
            content.range(of: "await projectionStore.replaceSnapshot(fixture.snapshot)")
        )
        XCTAssertLessThan(fixtureCache.lowerBound, fixturePublish.lowerBound)
    }

    func testAppDelegateTerminationStopsLiveIngressCoordinator() throws {
        let repoRoot = repoRootURL()
        let appDelegateFile = repoRoot.appendingPathComponent("ClaudeIsland/App/AppDelegate.swift")
        let content = try String(contentsOf: appDelegateFile, encoding: .utf8)

        XCTAssertTrue(
            content.contains("await RuntimeOrchestrator.shared.stop()"),
            "AppDelegate termination path must stop the runtime orchestrator."
        )
    }

    func testRuntimeOrchestratorBootstrapsProjectionBeforeStartingLiveIngress() throws {
        let repoRoot = repoRootURL()
        let coordinatorFile = repoRoot.appendingPathComponent(
            "ClaudeIsland/Services/Hooks/AgentEventCoordinator.swift"
        )
        let content = try String(contentsOf: coordinatorFile, encoding: .utf8)

        let bootstrapRange = try XCTUnwrap(
            content.range(of: "await ProjectionBootstrap.shared.start(mode: mode)")
        )
        let hookStartRange = try XCTUnwrap(
            content.range(of: "HookSocketServer.shared.start(")
        )
        let processStartRange = try XCTUnwrap(
            content.range(of: "await ProcessBasedAgentDetector.shared.start(")
        )

        XCTAssertLessThan(
            content.distance(from: content.startIndex, to: bootstrapRange.lowerBound),
            content.distance(from: content.startIndex, to: hookStartRange.lowerBound),
            "Projection bootstrap must complete before hook ingress starts."
        )
        XCTAssertLessThan(
            content.distance(from: content.startIndex, to: hookStartRange.lowerBound),
            content.distance(from: content.startIndex, to: processStartRange.lowerBound),
            "Hook ingress should start before process discovery in the coordinated startup sequence."
        )
    }

    func testRuntimeProtocolsAreSplitAndGodAgentProtocolIsRemoved() throws {
        let repoRoot = repoRootURL()
        let protocolFile = repoRoot.appendingPathComponent(
            "ClaudeIsland/Services/Agent/AIAgentProtocol.swift"
        )
        let content = try String(contentsOf: protocolFile, encoding: .utf8)

        XCTAssertFalse(content.contains("protocol AIAgent"))
        XCTAssertTrue(content.contains("protocol RuntimeAdapter"))
        XCTAssertTrue(content.contains("protocol RuntimeObservationPlane"))
        XCTAssertTrue(content.contains("protocol RuntimeRecoveryPlane"))
        XCTAssertTrue(content.contains("protocol RuntimeControlPlane"))
        XCTAssertTrue(content.contains("protocol RuntimeCapabilityPlane"))
        XCTAssertTrue(content.contains("protocol RuntimeSessionDiscoveryPlane"))
    }

    func testAgentRegistryIsMetadataOnlyInPhase2() throws {
        let repoRoot = repoRootURL()
        let registryFile = repoRoot.appendingPathComponent(
            "ClaudeIsland/Services/Agent/AgentRegistry.swift"
        )
        let content = try String(contentsOf: registryFile, encoding: .utf8)

        XCTAssertTrue(content.contains("[RuntimeAdapterID: RuntimeAdapterDescriptor]"))
        XCTAssertFalse(content.contains("installHooksForAll"))
        XCTAssertFalse(content.contains("uninstallHooksForAll"))
        XCTAssertFalse(content.contains("areAllHooksInstalled"))
        XCTAssertFalse(content.contains("hookSocketPaths"))
        XCTAssertFalse(content.contains("any HookInstallableAgent"))
    }

    func testLegacyFrozenCoverageIncludesSessionStateAndSessionInteraction() throws {
        let repoRoot = repoRootURL()
        let legacyFiles = [
            "ClaudeIsland/Models/SessionEvent.swift",
            "ClaudeIsland/Models/SessionPhase.swift",
            "ClaudeIsland/Services/State/SessionStore.swift",
            "ClaudeIsland/Services/Agent/ExternalAgentToolSupport.swift",
            "ClaudeIsland/Services/Hooks/HookSocketServer.swift",
            "ClaudeIsland/Models/SessionState.swift",
            "ClaudeIsland/Models/SessionInteraction.swift"
        ]

        for relativePath in legacyFiles {
            let fileURL = repoRoot.appendingPathComponent(relativePath)
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            XCTAssertTrue(
                content.contains("LEGACY FROZEN (Phase 0)"),
                "Missing LEGACY FROZEN marker in \(relativePath)"
            )
        }
    }

    func testCodexCLIAndCodexAppRemainDistinctAtTypeLevel() throws {
        let repoRoot = repoRootURL()
        let protocolFile = repoRoot.appendingPathComponent(
            "ClaudeIsland/Services/Agent/AIAgentProtocol.swift"
        )
        let content = try String(contentsOf: protocolFile, encoding: .utf8)

        XCTAssertTrue(content.contains("struct CodexCLIRuntimeAdapter"))
        XCTAssertTrue(content.contains("struct CodexAppRuntimeAdapter"))
        XCTAssertTrue(content.contains("adapterID: .codexCLI"))
        XCTAssertTrue(content.contains("adapterID: .codexApp"))
    }

    func testRuntimeOrchestratorIsTheOnlyCompositionBoundary() throws {
        let repoRoot = repoRootURL()
        let orchestratorFile = repoRoot.appendingPathComponent(
            "ClaudeIsland/Services/Hooks/AgentEventCoordinator.swift"
        )
        let appDelegateFile = repoRoot.appendingPathComponent("ClaudeIsland/App/AppDelegate.swift")
        let detectorFile = repoRoot.appendingPathComponent(
            "ClaudeIsland/Services/Hooks/ProcessBasedAgentDetector.swift"
        )

        let orchestratorContent = try String(contentsOf: orchestratorFile, encoding: .utf8)
        let appDelegateContent = try String(contentsOf: appDelegateFile, encoding: .utf8)
        let detectorContent = try String(contentsOf: detectorFile, encoding: .utf8)

        XCTAssertTrue(orchestratorContent.contains("actor RuntimeOrchestrator"))
        XCTAssertTrue(orchestratorContent.contains("await ProjectionBootstrap.shared.start(mode: mode)"))
        XCTAssertTrue(orchestratorContent.contains("HookSocketServer.shared.start("))
        XCTAssertTrue(orchestratorContent.contains("await ProcessBasedAgentDetector.shared.start("))
        XCTAssertFalse(orchestratorContent.contains("SessionStore.shared"))
        XCTAssertTrue(appDelegateContent.contains("await RuntimeOrchestrator.shared.start(mode: launchMode)"))
        XCTAssertFalse(appDelegateContent.contains("AgentEventCoordinator.shared.start()"))
        XCTAssertFalse(orchestratorContent.contains("final class AgentEventCoordinator"))
        XCTAssertFalse(detectorContent.contains("SessionStore.shared.process(.processDetected"))
        XCTAssertFalse(detectorContent.contains("ProjectionBootstrap.shared.handleProcessDetected"))
    }

    func testProjectionBootstrapAsyncMapUsesTaskGroupAndStableIndexes() throws {
        let repoRoot = repoRootURL()
        let bootstrapFile = repoRoot.appendingPathComponent(
            "ClaudeIsland/Services/Projection/ProjectionBootstrap.swift"
        )
        let content = try String(contentsOf: bootstrapFile, encoding: .utf8)

        XCTAssertTrue(
            content.contains("await withTaskGroup(of: (Int, T).self)"),
            "ProjectionBootstrap asyncMap should parallelize hydration work with a task group."
        )
        XCTAssertTrue(
            content.contains("values[index] = value"),
            "ProjectionBootstrap asyncMap must preserve input ordering while collecting concurrent results."
        )
    }

    func testNotchViewFallsBackToInstancesWhenSavedChatSessionIsMissing() throws {
        let repoRoot = repoRootURL()
        let notchFile = repoRoot.appendingPathComponent(
            "ClaudeIsland/UI/Views/NotchView.swift"
        )
        let content = try String(contentsOf: notchFile, encoding: .utf8)

        XCTAssertTrue(
            content.contains("viewModel.exitChat()"),
            "NotchView should clear stale chat state when the saved session target is missing."
        )
        XCTAssertTrue(
            content.contains("AgentInstancesView("),
            "NotchView should render the instances list instead of an empty pane when the saved chat target is gone."
        )
    }

    func testCodexAgentClosesPartiallyOpenedDatabaseHandleOnOpenFailure() throws {
        let repoRoot = repoRootURL()
        let codexFile = repoRoot.appendingPathComponent(
            "ClaudeIsland/Services/Agent/CodexAgent.swift"
        )
        let content = try String(contentsOf: codexFile, encoding: .utf8)

        XCTAssertTrue(
            content.contains("let openResult = sqlite3_open_v2"),
            "CodexAgent should capture the sqlite open result before deciding whether the handle must be closed."
        )
        XCTAssertTrue(
            content.contains("if let database {\n                sqlite3_close(database)\n            }"),
            "CodexAgent should close any partially initialized sqlite handle before returning from an open failure."
        )
    }

    func testProjectFileDoesNotHardcodeDevelopmentTeamIdentifiers() throws {
        let repoRoot = repoRootURL()
        let projectFile = repoRoot.appendingPathComponent("ClaudeIsland.xcodeproj/project.pbxproj")
        let content = try String(contentsOf: projectFile, encoding: .utf8)

        XCTAssertFalse(
            content.contains("DEVELOPMENT_TEAM = "),
            "The shared project file must not hardcode a development team identifier."
        )
    }

    func testCurrentMainPathDoesNotReferencePhase2PlusCutoverSymbols() throws {
        let repoRoot = repoRootURL()
        let targetFiles = [
            repoRoot.appendingPathComponent("ClaudeIsland/App/AppDelegate.swift"),
            repoRoot.appendingPathComponent("ClaudeIsland/Services/Session/ClaudeSessionMonitor.swift"),
            repoRoot.appendingPathComponent("ClaudeIsland/UI/Views/NotchView.swift"),
            repoRoot.appendingPathComponent("ClaudeIsland/UI/Views/ClaudeInstancesView.swift"),
            repoRoot.appendingPathComponent("ClaudeIsland/UI/Views/ChatView.swift"),
            repoRoot.appendingPathComponent("ClaudeIsland/UI/Window/NotchViewController.swift")
        ]

        let forbiddenTokens = [
            "Phase1RuntimeController",
            "ProjectionSessionCompatibility",
            "ProjectedFixtureRootView",
            "AppBootstrapMode"
        ]

        for fileURL in targetFiles {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            for token in forbiddenTokens {
                XCTAssertFalse(content.contains(token), "Unexpected \(token) reference in \(fileURL.path)")
            }
        }
    }

    func testCurrentMainPathReadsDoNotUseLegacySessionPublishersOrChatHistoryManager() throws {
        let repoRoot = repoRootURL()
        let targetFiles = [
            repoRoot.appendingPathComponent("ClaudeIsland/Services/Session/ClaudeSessionMonitor.swift"),
            repoRoot.appendingPathComponent("ClaudeIsland/UI/Views/ChatView.swift")
        ]

        let forbiddenTokens = [
            "SessionStore.shared.sessionsPublisher",
            "ChatHistoryManager.shared",
            "ProjectionCompatibilityStore.shared.$sessions",
            "ProjectionCompatibilityStore.shared.$hydratedSessionIDs"
        ]

        for fileURL in targetFiles {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            for token in forbiddenTokens {
                XCTAssertFalse(content.contains(token), "Unexpected \(token) reference in \(fileURL.path)")
            }
        }
    }

    func testMainPathUIDoesNotInspectVendorSpecificToolInputKeys() throws {
        let repoRoot = repoRootURL()
        let chatViewFile = repoRoot.appendingPathComponent("ClaudeIsland/UI/Views/ChatView.swift")
        let content = try String(contentsOf: chatViewFile, encoding: .utf8)

        let forbiddenTokens = [
            "interaction_question",
            "interaction_options",
            "tool.input[\"questions\"]",
            "tool.input[\"agentId\"]",
            "tool.input[\"description\"]",
            "tool.input[\"block\"]"
        ]

        for token in forbiddenTokens {
            XCTAssertFalse(content.contains(token), "Unexpected vendor-specific tool input read in \(chatViewFile.path)")
        }
    }

    func testCanonicalMainPathDoesNotDependOnHookEventSemanticHelpers() throws {
        let repoRoot = repoRootURL()
        let targetFiles = [
            repoRoot.appendingPathComponent("ClaudeIsland/Services/Hooks/AgentEventCoordinator.swift"),
            repoRoot.appendingPathComponent("ClaudeIsland/Services/Projection/ProjectionBootstrap.swift")
        ]

        let forbiddenTokens = [
            "event.expectsPermissionResponse",
            "event.expectsInteractionResponse",
            "event.sessionPhase",
            "func expectsPermissionResponse(",
            "func expectsInteractionResponse(",
            "AskUserQuestion",
            "\"request_user_input\"",
            "\"ask_user\""
        ]

        for fileURL in targetFiles {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            for token in forbiddenTokens {
                XCTAssertFalse(content.contains(token), "Unexpected HookEvent semantic helper dependency in \(fileURL.path)")
            }
        }
    }

    func testClaudeSessionMonitorDoesNotOwnLiveRuntimeLifecycle() throws {
        let repoRoot = repoRootURL()
        let monitorFile = repoRoot.appendingPathComponent("ClaudeIsland/Services/Session/ClaudeSessionMonitor.swift")
        let content = try String(contentsOf: monitorFile, encoding: .utf8)

        XCTAssertFalse(content.contains("await RuntimeOrchestrator.shared.start(mode: .current)"))
        XCTAssertFalse(content.contains("await RuntimeOrchestrator.shared.stop()"))
    }

    func testProjectionBootstrapDoesNotReadVendorSpecificToolInputKeys() throws {
        let repoRoot = repoRootURL()
        let bootstrapFile = repoRoot.appendingPathComponent("ClaudeIsland/Services/Projection/ProjectionBootstrap.swift")
        let content = try String(contentsOf: bootstrapFile, encoding: .utf8)

        let forbiddenTokens = [
            "interaction_question",
            "interaction_options",
            "input[\"description\"]",
            "tool.input[\"description\"]",
            "input[\"question\"]"
        ]

        for token in forbiddenTokens {
            XCTAssertFalse(content.contains(token), "Unexpected vendor-specific projection read in \(bootstrapFile.path)")
        }
    }

    func testPurePhase1BranchDoesNotContainLaterPhaseRuntimeCutoverFiles() {
        let repoRoot = repoRootURL()
        let removedPaths = [
            "ClaudeIsland/Services/EventBus/Phase1RuntimeController.swift",
            "ClaudeIsland/Services/EventBus/ProcessSessionDiscovery.swift",
            "ClaudeIsland/Services/EventBus/RuntimeSessionContextStore.swift",
            "ClaudeIsland/Services/Projection/ProjectionSessionCompatibility.swift",
            "ClaudeIsland/UI/Views/ProjectedFixtureRootView.swift"
        ]

        for relativePath in removedPaths {
            let fileURL = repoRoot.appendingPathComponent(relativePath)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "Unexpected later-phase file at \(fileURL.path)")
        }
    }

    func testRuntimeOrchestratorApprovalTimeoutEmitsSingleExpiredEvent() async {
        await ProjectionBootstrap.shared.projectionStore.reset()

        await RuntimeOrchestrator.shared.registerManagedInteraction(
            RuntimeManagedInteraction(
                kind: .approval,
                adapterID: .claudeCode,
                conversationID: "timeout-approval",
                interactionID: "approval-timeout-1",
                observedAt: Date(),
                reason: "approval timeout"
            ),
            timeoutOverride: 0.01
        )

        try? await Task.sleep(nanoseconds: 100_000_000)
        let snapshot = await ProjectionBootstrap.shared.projectionStore.snapshot()
        let approvals = snapshot.conversations["timeout-approval"]?.approvals ?? []

        XCTAssertEqual(approvals.count, 1)
        XCTAssertEqual(approvals.first?.id, "approval-timeout-1")
        XCTAssertEqual(approvals.first?.domainState, .expired)
        let activeApprovalTimeouts = await RuntimeOrchestrator.shared.activeManagedInteractionCount()
        XCTAssertEqual(activeApprovalTimeouts, 0)

        try? await Task.sleep(nanoseconds: 100_000_000)
        let secondSnapshot = await ProjectionBootstrap.shared.projectionStore.snapshot()
        XCTAssertEqual(secondSnapshot.conversations["timeout-approval"]?.approvals.count, 1)
    }

    func testRuntimeOrchestratorApprovalTimeoutClearsProjectedPromptState() async {
        await ProjectionBootstrap.shared.stop()
        await ProjectionBootstrap.shared.start(mode: .live)

        await ProjectionBootstrap.shared.handleHookEvent(
            HookEvent(
                sessionId: "timeout-approval-ui",
                cwd: "/tmp/timeout-approval-ui",
                event: HookEventType.permissionRequest.rawValue,
                status: "waiting_for_approval",
                pid: nil,
                tty: nil,
                tool: "Bash",
                toolInput: nil,
                toolUseId: "approval-timeout-ui-1",
                notificationType: nil,
                message: "approval timeout",
                agentId: "claude"
            )
        )

        let pendingSession = await ProjectionBootstrap.shared.uiSession(id: "timeout-approval-ui")
        XCTAssertEqual(pendingSession?.prompt?.id, "approval-timeout-ui-1")
        XCTAssertEqual(pendingSession?.pendingInteractionCount, 1)
        XCTAssertEqual(pendingSession?.phase, .waitingForApproval)

        await RuntimeOrchestrator.shared.registerManagedInteraction(
            RuntimeManagedInteraction(
                kind: .approval,
                adapterID: .claudeCode,
                conversationID: "timeout-approval-ui",
                interactionID: "approval-timeout-ui-1",
                observedAt: Date(),
                reason: "approval timeout"
            ),
            timeoutOverride: 0.01
        )

        try? await Task.sleep(nanoseconds: 150_000_000)

        let resolvedSession = await ProjectionBootstrap.shared.uiSession(id: "timeout-approval-ui")

        XCTAssertNil(resolvedSession?.prompt)
        XCTAssertEqual(resolvedSession?.pendingInteractionCount, 0)
        XCTAssertEqual(resolvedSession?.phase, .processing)

        await ProjectionBootstrap.shared.stop()
    }

    func testRuntimeOrchestratorCancelsTimeoutAfterResolution() async {
        await ProjectionBootstrap.shared.projectionStore.reset()

        await RuntimeOrchestrator.shared.registerManagedInteraction(
            RuntimeManagedInteraction(
                kind: .choice,
                adapterID: .codexCLI,
                conversationID: "timeout-choice",
                interactionID: "choice-timeout-1",
                observedAt: Date(),
                reason: "choice timeout"
            ),
            timeoutOverride: 0.2
        )
        await RuntimeOrchestrator.shared.noteInteractionResolved(
            sessionID: "timeout-choice",
            interactionID: "choice-timeout-1"
        )

        try? await Task.sleep(nanoseconds: 300_000_000)
        let snapshot = await ProjectionBootstrap.shared.projectionStore.snapshot()
        let activeChoiceTimeouts = await RuntimeOrchestrator.shared.activeManagedInteractionCount()

        XCTAssertNil(snapshot.conversations["timeout-choice"]?.choices.first)
        XCTAssertEqual(activeChoiceTimeouts, 0)
    }

    func testCanonicalSessionInterruptDispatchWritesTTYControlSequence() async throws {
        await RuntimeOrchestrator.shared.stop()
        await ProjectionBootstrap.shared.stop()

        let timestamp = CanonicalFixtures.baseDate
        let ttyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("tty")
        FileManager.default.createFile(atPath: ttyURL.path, contents: Data())

        let fixtureURL = try makeProjectedFixture(
            snapshot: SessionProjectionSnapshot(
                conversations: [
                    "conversation-interrupt": ProjectedConversationState(
                        id: "conversation-interrupt",
                        adapterID: .claudeCode,
                        familyID: .claude,
                        sourceKind: .hook,
                        title: "Interrupt Fixture",
                        cwd: "/tmp/interrupt-fixture",
                        status: .active,
                        lastTransition: .created,
                        turn: CanonicalFixtures.turn(status: .inProgress),
                        messages: [],
                        tools: [],
                        approvals: [],
                        choices: [],
                        plans: [],
                        sessionCommandSubmissionStates: [:],
                        lastUpdatedAt: timestamp
                    )
                ],
                capabilities: [:]
            ),
            sessions: [
                .init(
                    sessionID: "conversation-interrupt",
                    agentID: "claude",
                    pid: nil,
                    tty: ttyURL.path,
                    isInTmux: false,
                    lastActivity: timestamp,
                    createdAt: timestamp
                )
            ]
        )

        await RuntimeOrchestrator.shared.start(
            mode: .projectedFixture(
                .init(
                    fixturePath: fixtureURL.path,
                    initialContent: .instances
                )
            )
        )

        let result = await RuntimeOrchestrator.shared.dispatch(
            CanonicalCommandEnvelope(
                conversationID: "conversation-interrupt",
                target: CanonicalCommandTarget(
                    adapterID: .claudeCode,
                    entityType: .session,
                    entityID: "conversation-interrupt"
                ),
                type: .sessionInterrupt,
                mode: .desktopFallback,
                idempotencyKey: "interrupt-tty",
                payload: .sessionInterrupt(CanonicalSessionCommandPayload(reason: "test_interrupt"))
            )
        )

        XCTAssertEqual(result.status, .accepted)
        XCTAssertEqual(try Data(contentsOf: ttyURL), Data([0x03]))
        await RuntimeOrchestrator.shared.stop()
        await ProjectionBootstrap.shared.stop()
    }

    func testCanonicalApprovalResolveRejectsWhenNoPendingSocketExists() async throws {
        await RuntimeOrchestrator.shared.stop()
        await ProjectionBootstrap.shared.stop()

        let timestamp = CanonicalFixtures.baseDate
        let fixtureURL = try makeProjectedFixture(
            snapshot: SessionProjectionSnapshot(
                conversations: [
                    "conversation-approval-no-socket": ProjectedConversationState(
                        id: "conversation-approval-no-socket",
                        adapterID: .claudeCode,
                        familyID: .claude,
                        sourceKind: .hook,
                        title: "Approval Fixture",
                        cwd: "/tmp/approval-fixture",
                        status: .active,
                        lastTransition: .created,
                        turn: CanonicalFixtures.turn(status: .inProgress),
                        messages: [],
                        tools: [],
                        approvals: [
                            ProjectedApprovalState(
                                id: "approval-no-socket",
                                toolID: "tool-no-socket",
                                kind: .tool,
                                reason: "Allow tool?",
                                options: [.allowOnce, .deny, .cancel],
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
            ),
            sessions: [
                .init(
                    sessionID: "conversation-approval-no-socket",
                    agentID: "claude",
                    pid: nil,
                    tty: nil,
                    isInTmux: false,
                    lastActivity: timestamp,
                    createdAt: timestamp
                )
            ]
        )

        await RuntimeOrchestrator.shared.start(
            mode: .projectedFixture(
                .init(
                    fixturePath: fixtureURL.path,
                    initialContent: .instances
                )
            )
        )

        let result = await RuntimeOrchestrator.shared.dispatch(
            CanonicalCommandEnvelope(
                conversationID: "conversation-approval-no-socket",
                target: CanonicalCommandTarget(
                    adapterID: .claudeCode,
                    entityType: .approval,
                    entityID: "approval-no-socket"
                ),
                type: .approvalResolve,
                mode: .authoritative,
                idempotencyKey: "approval-no-pending-socket",
                payload: .approvalResolve(
                    CanonicalApprovalResolveCommandPayload(
                        decision: .allowOnce,
                        scope: .once,
                        reason: "test_no_socket"
                    )
                )
            )
        )

        XCTAssertEqual(result.status, .rejected)
        await RuntimeOrchestrator.shared.stop()
        await ProjectionBootstrap.shared.stop()
    }

    func testCanonicalSessionClearRequiresExplicitProjectionFallback() async throws {
        await RuntimeOrchestrator.shared.stop()
        await ProjectionBootstrap.shared.stop()

        let timestamp = CanonicalFixtures.baseDate
        let fixtureURL = try makeProjectedFixture(
            snapshot: SessionProjectionSnapshot(
                conversations: [
                    "conversation-clear-reject": ProjectedConversationState(
                        id: "conversation-clear-reject",
                        adapterID: .codexCLI,
                        familyID: .codex,
                        sourceKind: .hook,
                        title: "Clear Reject Fixture",
                        cwd: "/tmp/clear-reject",
                        status: .active,
                        lastTransition: .created,
                        turn: CanonicalFixtures.turn(status: .inProgress),
                        messages: [
                            ProjectedMessageState(
                                id: "message-clear-reject",
                                turnID: nil,
                                role: .assistant,
                                format: .markdown,
                                text: "visible message",
                                isFinal: true,
                                sourceKind: .hook,
                                updatedAt: timestamp
                            )
                        ],
                        tools: [],
                        approvals: [],
                        choices: [],
                        plans: [],
                        sessionCommandSubmissionStates: [:],
                        lastUpdatedAt: timestamp
                    )
                ],
                capabilities: [:]
            ),
            sessions: [
                .init(
                    sessionID: "conversation-clear-reject",
                    agentID: "codex",
                    pid: nil,
                    tty: nil,
                    isInTmux: false,
                    lastActivity: timestamp,
                    createdAt: timestamp
                )
            ]
        )

        await RuntimeOrchestrator.shared.start(
            mode: .projectedFixture(
                .init(
                    fixturePath: fixtureURL.path,
                    initialContent: .instances
                )
            )
        )

        let result = await RuntimeOrchestrator.shared.dispatch(
            CanonicalCommandEnvelope(
                conversationID: "conversation-clear-reject",
                target: CanonicalCommandTarget(
                    adapterID: .codexCLI,
                    entityType: .session,
                    entityID: "conversation-clear-reject"
                ),
                type: .sessionClear,
                mode: .desktopFallback,
                idempotencyKey: "clear-without-fallback",
                payload: .sessionClear(
                    CanonicalSessionClearCommandPayload(
                        reason: "test_clear_reject",
                        allowProjectionFallback: false
                    )
                )
            )
        )

        XCTAssertEqual(result.status, .rejected)
        let sessions = await ProjectionBootstrap.shared.uiSessions()
        XCTAssertEqual(sessions.first?.timeline.count, 1)
        await RuntimeOrchestrator.shared.stop()
        await ProjectionBootstrap.shared.stop()
    }

    func testCanonicalSessionClearProjectionFallbackClearsVisibleSurface() async throws {
        await RuntimeOrchestrator.shared.stop()
        await ProjectionBootstrap.shared.stop()

        let timestamp = CanonicalFixtures.baseDate
        let fixtureURL = try makeProjectedFixture(
            snapshot: SessionProjectionSnapshot(
                conversations: [
                    "conversation-clear": ProjectedConversationState(
                        id: "conversation-clear",
                        adapterID: .codexCLI,
                        familyID: .codex,
                        sourceKind: .hook,
                        title: "Clear Fixture",
                        cwd: "/tmp/clear-fixture",
                        status: .active,
                        lastTransition: .created,
                        turn: CanonicalFixtures.turn(status: .inProgress),
                        messages: [
                            ProjectedMessageState(
                                id: "message-clear",
                                turnID: nil,
                                role: .assistant,
                                format: .markdown,
                                text: "visible message",
                                isFinal: true,
                                sourceKind: .hook,
                                updatedAt: timestamp
                            )
                        ],
                        tools: [],
                        approvals: [],
                        choices: [],
                        plans: [],
                        sessionCommandSubmissionStates: [:],
                        lastUpdatedAt: timestamp
                    )
                ],
                capabilities: [:]
            ),
            sessions: [
                .init(
                    sessionID: "conversation-clear",
                    agentID: "codex",
                    pid: nil,
                    tty: nil,
                    isInTmux: false,
                    lastActivity: timestamp,
                    createdAt: timestamp
                )
            ]
        )

        await RuntimeOrchestrator.shared.start(
            mode: .projectedFixture(
                .init(
                    fixturePath: fixtureURL.path,
                    initialContent: .instances
                )
            )
        )

        let result = await RuntimeOrchestrator.shared.dispatch(
            CanonicalCommandEnvelope(
                conversationID: "conversation-clear",
                target: CanonicalCommandTarget(
                    adapterID: .codexCLI,
                    entityType: .session,
                    entityID: "conversation-clear"
                ),
                type: .sessionClear,
                mode: .desktopFallback,
                idempotencyKey: "clear-with-fallback",
                payload: .sessionClear(
                    CanonicalSessionClearCommandPayload(
                        reason: "test_clear_accept",
                        allowProjectionFallback: true
                    )
                )
            )
        )

        XCTAssertEqual(result.status, .accepted)
        let sessions = await ProjectionBootstrap.shared.uiSessions()
        XCTAssertEqual(sessions.first?.timeline.count, 0)
        let snapshot = await ProjectionBootstrap.shared.projectionStore.snapshot()
        XCTAssertEqual(
            snapshot.conversations["conversation-clear"]?.sessionCommandSubmissionStates[.sessionClear],
            .submissionPending
        )
        await RuntimeOrchestrator.shared.stop()
        await ProjectionBootstrap.shared.stop()
    }

    private func repoRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func assertNoForbiddenTokens(
        in directories: [URL],
        forbiddenTokens: [String]
    ) throws {
        let fileManager = FileManager.default
        var inspectedFiles: [URL] = []

        for directory in directories {
            let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: nil
            )
            while let fileURL = enumerator?.nextObject() as? URL {
                guard fileURL.pathExtension == "swift" else { continue }
                inspectedFiles.append(fileURL)
                let content = try String(contentsOf: fileURL, encoding: .utf8)
                for token in forbiddenTokens {
                    XCTAssertFalse(content.contains(token), "Unexpected \(token) reference in \(fileURL.path)")
                }
            }
        }

        XCTAssertFalse(inspectedFiles.isEmpty)
    }

    private func assertNoForbiddenTokens(
        inFiles files: [URL],
        forbiddenTokens: [String]
    ) throws {
        for fileURL in files {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            for token in forbiddenTokens {
                XCTAssertFalse(content.contains(token), "Unexpected \(token) reference in \(fileURL.path)")
            }
        }
    }

    private func makeProjectedFixture(
        snapshot: SessionProjectionSnapshot,
        sessions: [ProjectionFixtureDocument.SessionMetadata]
    ) throws -> URL {
        let document = ProjectionFixtureDocument(snapshot: snapshot, sessions: sessions)
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(CanonicalTimestampCoding.string(from: date))
        }
        try encoder.encode(document).write(to: fixtureURL)
        return fixtureURL
    }
}
