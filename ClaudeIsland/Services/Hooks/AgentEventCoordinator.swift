//
//  AgentEventCoordinator.swift
//  ClaudeIsland
//
//  Phase 2 runtime orchestration boundary.
//

import Foundation
import os.log

struct RuntimeCutoverConfiguration: Equatable, Sendable {
    let activeAdapterIDs: Set<RuntimeAdapterID>
    let enablesCanonicalProjectionLiveIngress: Bool
}

actor RuntimeOrchestrator {
    static let shared = RuntimeOrchestrator()
    private static let logger = Logger(subsystem: "com.claudeisland", category: "RuntimeOrchestrator")

    private struct InteractionTimeoutKey: Hashable, Sendable {
        let adapterID: RuntimeAdapterID
        let conversationID: String
        let kind: RuntimeInteractionKind
        let interactionID: String
    }

    private let commandRouter = CommandRouter()
    private let adapters = RuntimeAdapterCatalog.adapters()

    private var startedMode: ProjectionLaunchMode?
    private var interactionTimeouts: [InteractionTimeoutKey: Task<Void, Never>] = [:]
    private var activeAdapterIDs: Set<RuntimeAdapterID> = Set(RuntimeAdapterID.allCases)

    private init() {}

    func start(mode: ProjectionLaunchMode = .current) async {
        guard startedMode == nil else { return }
        startedMode = mode
        let cutover = Self.liveCutoverConfiguration(for: mode, flags: EventBusFeatureFlags.snapshot())
        activeAdapterIDs = cutover.activeAdapterIDs

        await ProjectionBootstrap.shared.start(mode: mode)
        await wireCommandRouter(adapters: activeAdapters)
        await refreshCapabilities(
            for: mode.startsLiveIngress ? .attached : .ambient,
            adapters: activeAdapters
        )

        guard mode.startsLiveIngress else { return }
        guard cutover.enablesCanonicalProjectionLiveIngress else {
            Self.logger.notice("Live runtime cutover disabled by feature flags; skipping live ingress startup.")
            return
        }

        let enabledAdapters = cutover.activeAdapterIDs.map(\.rawValue).sorted().joined(separator: ",")
        Self.logger.notice("Starting live runtime ingress with adapters: \(enabledAdapters, privacy: .public)")

        await MainActor.run {
            HookInstaller.installIfNeeded()
        }
        startHookIngress()
        await startProcessDiscovery(adapters: activeAdapters)
    }

    func stop() async {
        guard startedMode != nil else { return }
        startedMode = nil

        await HookSocketServer.shared.stop()
        await MainActor.run {
            InterruptWatcherManager.shared.stopAll()
        }
        cancelAllTimeouts()
        activeAdapterIDs = Set(RuntimeAdapterID.allCases)

        await ProcessBasedAgentDetector.shared.stop()
        await ProjectionBootstrap.shared.stop()
    }

    func dispatch(_ command: CanonicalCommandEnvelope) async -> CanonicalCommandDispatchResult {
        let result = await commandRouter.dispatch(command)
        await ProjectionBootstrap.shared.applyCommandDispatch(result, for: command)

        if result.status == .accepted {
            switch command.type {
            case .approvalResolve, .choiceSubmit:
                noteInteractionResolved(
                    sessionID: command.conversationID,
                    interactionID: command.target.entityID
                )
            case .sessionFocus, .sessionArchive, .sessionInterrupt, .sessionClear:
                break
            }
        }

        return result
    }

    func noteInteractionResolved(sessionID: String, interactionID: String?) {
        cancelTimeouts(sessionID: sessionID, interactionID: interactionID)
    }

    func noteSessionEnded(_ sessionID: String) {
        cancelTimeouts(sessionID: sessionID, interactionID: nil)
    }

    func registerManagedInteraction(_ interaction: RuntimeManagedInteraction, timeoutOverride: TimeInterval? = nil) {
        let key = InteractionTimeoutKey(
            adapterID: interaction.adapterID,
            conversationID: interaction.conversationID,
            kind: interaction.kind,
            interactionID: interaction.interactionID
        )

        interactionTimeouts[key]?.cancel()
        let timeout = timeoutOverride ?? timeoutInterval(for: interaction.kind, adapterID: interaction.adapterID)
        let orchestrator = self
        interactionTimeouts[key] = Task {
            let nanoseconds = UInt64(max(timeout, 0) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            if Task.isCancelled { return }
            await orchestrator.emitExpiredInteraction(for: interaction, key: key)
        }
    }

    func activeManagedInteractionCount() -> Int {
        interactionTimeouts.count
    }

    private func wireCommandRouter(adapters: [any RuntimeAdapter]) async {
        for adapter in adapters {
            await adapter.makePlanes().control.registerCommands(on: commandRouter)
        }
    }

    private func refreshCapabilities(for mode: RuntimeIngressMode, adapters: [any RuntimeAdapter]) async {
        for adapter in adapters {
            let capabilities = adapter.makePlanes().capability.capabilitySnapshot(for: mode)
            for capability in capabilities.values {
                await ProjectionBootstrap.shared.publishCapability(capability)
            }
        }
    }

    private func startHookIngress() {
        let orchestrator = self
        HookSocketServer.shared.start(
            onEvent: { event in
                Task {
                    await orchestrator.handleHookEvent(event)
                }
            },
            onPermissionFailure: { sessionID, toolUseID in
                Task {
                    await orchestrator.handlePermissionFailure(sessionID: sessionID, toolUseID: toolUseID)
                }
            }
        )
    }

    private func startProcessDiscovery(adapters: [any RuntimeAdapter]) async {
        let discoveryPlanes = adapters.compactMap { $0.makePlanes().sessionDiscovery }
        let orchestrator = self

        await ProcessBasedAgentDetector.shared.start(
            discoveryPlanes: discoveryPlanes,
            trackedSessionsProvider: {
                await ProjectionBootstrap.shared.trackedSessions()
            },
            onSessionDiscovered: { session in
                await orchestrator.handleDiscoveredSession(session)
            },
            onSessionEnded: { sessionID in
                await orchestrator.handleEndedSession(sessionID)
            }
        )
    }

    private func handleHookEvent(_ event: HookEvent) async {
        guard let adapterID = adapterID(for: event) else { return }
        await ProjectionBootstrap.shared.handleHookEvent(event)

        await MainActor.run {
            AgentRegistry.shared.updatePrimaryAgent(withSessionFrom: event.agentId)
        }

        if RuntimeSemanticRegistry
            .semanticPlane(for: adapterID)?
            .shouldStartInterruptWatcher(for: event) == true {
            await MainActor.run {
                InterruptWatcherManager.shared.startWatching(
                    sessionId: event.sessionId,
                    cwd: event.cwd
                )
            }
        }

        if event.status == "ended" || event.event == HookEventType.sessionEnd.rawValue {
            await MainActor.run {
                InterruptWatcherManager.shared.stopWatching(sessionId: event.sessionId)
            }
            cancelTimeouts(sessionID: event.sessionId, interactionID: nil)
        }

        if event.event == HookEventType.stop.rawValue {
            HookSocketServer.shared.cancelPendingPermissions(sessionId: event.sessionId)
            cancelTimeouts(sessionID: event.sessionId, interactionID: nil)
        }

        if event.event == HookEventType.postToolUse.rawValue, let toolUseID = event.toolUseId {
            HookSocketServer.shared.cancelPendingPermission(toolUseId: toolUseID)
            cancelTimeouts(sessionID: event.sessionId, interactionID: toolUseID)
        }

        if event.event == HookEventType.interactionResolved.rawValue {
            cancelTimeouts(sessionID: event.sessionId, interactionID: event.toolUseId)
        }

        registerTimeoutIfNeeded(for: event, adapterID: adapterID)
    }

    private func handlePermissionFailure(sessionID: String, toolUseID: String) async {
        cancelTimeouts(sessionID: sessionID, interactionID: toolUseID)
    }

    private func handleDiscoveredSession(_ session: RuntimeDiscoveredSession) async {
        await MainActor.run {
            AgentRegistry.shared.updatePrimaryAdapter(session.adapterID)
        }

        await ProjectionBootstrap.shared.handleProcessDetected(
            sessionID: session.sessionID,
            cwd: session.cwd,
            agentID: session.legacyAgentID,
            pid: session.pid,
            tty: session.tty
        )
    }

    private func handleEndedSession(_ sessionID: String) async {
        cancelTimeouts(sessionID: sessionID, interactionID: nil)
        await ProjectionBootstrap.shared.handleProcessEnded(sessionID: sessionID)
    }

    private func registerTimeoutIfNeeded(for event: HookEvent, adapterID: RuntimeAdapterID) {
        guard let interactionID = event.toolUseId else {
            return
        }

        let interactionKind = RuntimeSemanticRegistry
            .semanticPlane(for: adapterID)?
            .managedInteractionKind(for: event)
        guard let interactionKind else { return }

        registerManagedInteraction(
            RuntimeManagedInteraction(
                kind: interactionKind,
                adapterID: adapterID,
                conversationID: event.sessionId,
                interactionID: interactionID,
                observedAt: Date(),
                reason: event.message ?? event.tool
            )
        )
    }

    private func timeoutInterval(for kind: RuntimeInteractionKind, adapterID: RuntimeAdapterID) -> TimeInterval {
        if let override = adapters.first(where: { $0.descriptor.adapterID == adapterID })?
            .makePlanes()
            .capability
            .timeoutOverride(for: kind) {
            return override
        }

        switch kind {
        case .approval:
            return 5 * 60
        case .choice:
            return 10 * 60
        }
    }

    private func cancelTimeouts(sessionID: String, interactionID: String?) {
        let matchingKeys = interactionTimeouts.keys.filter { key in
            guard key.conversationID == sessionID else { return false }
            guard let interactionID else { return true }
            return key.interactionID == interactionID
        }

        for key in matchingKeys {
            interactionTimeouts[key]?.cancel()
            interactionTimeouts.removeValue(forKey: key)
        }
    }

    private func cancelAllTimeouts() {
        for task in interactionTimeouts.values {
            task.cancel()
        }
        interactionTimeouts.removeAll()
    }

    private func emitExpiredInteraction(for interaction: RuntimeManagedInteraction, key: InteractionTimeoutKey) async {
        interactionTimeouts.removeValue(forKey: key)

        guard let event = await makeExpiredEvent(for: interaction) else { return }
        do {
            _ = try await ProjectionBootstrap.shared.eventBus.publish(event)
        } catch {
            Self.logger.error(
                "Failed to publish expired interaction event for \(interaction.conversationID, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
        await ProjectionBootstrap.shared.applySyntheticInteractionResolution(event)
    }

    private func makeExpiredEvent(for interaction: RuntimeManagedInteraction) async -> CanonicalEventEnvelope? {
        let snapshot = await ProjectionBootstrap.shared.projectionStore.snapshot()
        let currentConversation = snapshot.conversations[interaction.conversationID]
        let familyID = currentConversation?.familyID ?? familyID(for: interaction.adapterID)
        let conversation = CanonicalConversationDescriptor(
            id: interaction.conversationID,
            title: currentConversation?.title,
            cwd: currentConversation?.cwd,
            status: currentConversation?.status ?? .unknown
        )
        let turn = currentConversation?.turn ?? CanonicalTurnDescriptor(id: nil, status: .unknown)

        do {
            switch interaction.kind {
            case .approval:
                return try CanonicalEventEnvelope(
                    type: .approvalResolved,
                    adapterID: interaction.adapterID,
                    agent: CanonicalAgentDescriptor(family: familyID, sourceKind: .synthetic),
                    conversation: conversation,
                    turn: turn,
                    entity: CanonicalEntityDescriptor(
                        messageID: nil,
                        toolID: nil,
                        approvalID: interaction.interactionID,
                        choiceID: nil,
                        planID: nil
                    ),
                    payload: .approvalResolved(
                        CanonicalApprovalResolvedPayload(
                            approval: CanonicalApprovalResolved(
                                id: interaction.interactionID,
                                result: .expired,
                                decision: .unknown,
                                scope: .unknown,
                                resolvedBy: .runtime
                            )
                        )
                    ),
                    raw: CanonicalRawEvent(
                        vendorEvent: "runtime_timeout",
                        vendorPayload: ["reason": AnyCodable(interaction.reason ?? "approval timeout")]
                    )
                )
            case .choice:
                return try CanonicalEventEnvelope(
                    type: .userChoiceResolved,
                    adapterID: interaction.adapterID,
                    agent: CanonicalAgentDescriptor(family: familyID, sourceKind: .synthetic),
                    conversation: conversation,
                    turn: turn,
                    entity: CanonicalEntityDescriptor(
                        messageID: nil,
                        toolID: nil,
                        approvalID: nil,
                        choiceID: interaction.interactionID,
                        planID: nil
                    ),
                    payload: .userChoiceResolved(
                        CanonicalUserChoiceResolvedPayload(
                            choice: CanonicalChoiceResolved(
                                id: interaction.interactionID,
                                result: .expired,
                                resolvedBy: .runtime
                            )
                        )
                    ),
                    raw: CanonicalRawEvent(
                        vendorEvent: "runtime_timeout",
                        vendorPayload: ["reason": AnyCodable(interaction.reason ?? "choice timeout")]
                    )
                )
            }
        } catch {
            return nil
        }
    }

    private func familyID(for adapterID: RuntimeAdapterID) -> RuntimeFamilyID {
        switch adapterID {
        case .claudeCode:
            return .claude
        case .codexCLI, .codexApp:
            return .codex
        case .geminiCLI:
            return .gemini
        case .opencode:
            return .opencode
        }
    }

    private var activeAdapters: [any RuntimeAdapter] {
        adapters.filter { activeAdapterIDs.contains($0.descriptor.adapterID) }
    }

    private func adapterID(for event: HookEvent) -> RuntimeAdapterID? {
        activeAdapters.first(where: { $0.makePlanes().observation.supports(hookEvent: event) })?
            .descriptor
            .adapterID
    }

    static func liveCutoverConfiguration(
        for mode: ProjectionLaunchMode,
        flags: EventBusFeatureFlags
    ) -> RuntimeCutoverConfiguration {
        guard mode.startsLiveIngress else {
            return RuntimeCutoverConfiguration(
                activeAdapterIDs: Set(RuntimeAdapterID.allCases),
                enablesCanonicalProjectionLiveIngress: true
            )
        }

        let explicitAdapterFlags: [RuntimeAdapterID: Bool] = [
            .claudeCode: flags.enableClaudeCodeAdapterPath,
            .codexCLI: flags.enableCodexCLIAdapterPath,
            .codexApp: flags.enableCodexAppAdapterPath,
            .geminiCLI: flags.enableGeminiCLIAdapterPath,
            .opencode: flags.enableOpencodeAdapterPath
        ]

        guard flags.hasExplicitLivePathSelection else {
            return RuntimeCutoverConfiguration(
                activeAdapterIDs: Set(RuntimeAdapterID.allCases),
                enablesCanonicalProjectionLiveIngress: true
            )
        }

        let enabledAdapters = Set(
            explicitAdapterFlags.compactMap { adapterID, isEnabled in
                isEnabled ? adapterID : nil
            }
        )
        let activeAdapters = enabledAdapters.isEmpty ? Set(RuntimeAdapterID.allCases) : enabledAdapters

        return RuntimeCutoverConfiguration(
            activeAdapterIDs: activeAdapters,
            enablesCanonicalProjectionLiveIngress: flags.enableCanonicalProjectionPath
        )
    }
}
