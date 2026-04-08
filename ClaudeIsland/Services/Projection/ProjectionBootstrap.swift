//
//  ProjectionBootstrap.swift
//  ClaudeIsland
//
//  Projection-owned runtime bootstrap for live ingress and fixtures.
//

import Foundation

struct ProjectionFixtureDocument: Codable, Equatable, Sendable {
    struct SessionMetadata: Codable, Equatable, Sendable {
        let sessionID: String
        let agentID: String
        let pid: Int?
        let tty: String?
        let isInTmux: Bool
        let lastActivity: Date
        let createdAt: Date?

        private enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case agentID = "agent_id"
            case pid
            case tty
            case isInTmux = "is_in_tmux"
            case lastActivity = "last_activity"
            case createdAt = "created_at"
        }
    }

    let snapshot: SessionProjectionSnapshot
    let sessions: [SessionMetadata]
}

struct ProjectionRuntimeMetadata: Equatable, Sendable {
    let sessionID: String
    var agentID: String
    var runtimeIdentity: RuntimeIdentity
    var cwd: String
    var pid: Int?
    var tty: String?
    var isInTmux: Bool
    var phase: ProjectedSessionRuntimePhase
    var activePrompt: ProjectedPromptState?
    var lastActivity: Date
    let createdAt: Date
}

private struct ProjectionHydratedArtifacts: Sendable {
    let conversationInfo: ConversationInfo
    let timeline: [ProjectedTimelineItemState]
    let messages: [ProjectedMessageState]
    let tools: [ProjectedToolState]
    let agentDescriptions: [String: String]
    let lastUpdatedAt: Date
}

actor ProjectionBootstrap {
    static let shared = ProjectionBootstrap()

    nonisolated let eventBus = CanonicalEventBus()
    nonisolated let projectionStore = SessionProjectionStore()

    private var startedMode: ProjectionLaunchMode?
    private var runtimeMetadataBySessionID: [String: ProjectionRuntimeMetadata] = [:]
    private var artifactsBySessionID: [String: ProjectionHydratedArtifacts] = [:]
    private var cachedUISessionsByID: [String: ProjectedSessionViewState] = [:]
    private var capabilities: [RuntimeAdapterID: [CanonicalSemanticArea: AdapterCapabilitySnapshot]] = [:]
    private var suppressedSessionIDs: Set<String> = []
    private var clearedAtBySessionID: [String: Date] = [:]
    private var fixtureBootSessionIDValue: String?

    private init() {}

    func start(mode: ProjectionLaunchMode = .current) async {
        guard startedMode == nil else { return }
        startedMode = mode

        switch mode {
        case .live:
            await rebuildProjectionState()
        case .projectedFixture(let configuration):
            await loadFixture(
                at: configuration.fixturePath,
                initialContent: configuration.initialContent
            )
        }
    }

    func stop() async {
        startedMode = nil
        runtimeMetadataBySessionID.removeAll()
        artifactsBySessionID.removeAll()
        cachedUISessionsByID.removeAll()
        capabilities.removeAll()
        suppressedSessionIDs.removeAll()
        clearedAtBySessionID.removeAll()
        fixtureBootSessionIDValue = nil
        await projectionStore.reset()
        ShadowDiffLogger.updateProjectedSnapshot(nil)
    }

    func handleHookEvent(_ event: HookEvent) async {
        guard activeModeStartsLiveIngress else { return }

        let runtimeIdentity = event.legacyRuntimeIdentity
            ?? RuntimeIdentity(adapterID: .claudeCode, familyID: .claude, modeHint: .unknown)
        let now = Date()
        let isInTmux = determineTmuxState(pid: event.pid, tty: event.tty)
        var metadata = runtimeMetadataBySessionID[event.sessionId]
            ?? ProjectionRuntimeMetadata(
                sessionID: event.sessionId,
                agentID: event.agentId,
                runtimeIdentity: runtimeIdentity,
                cwd: event.cwd,
                pid: event.pid,
                tty: event.tty?.replacingOccurrences(of: "/dev/", with: ""),
                isInTmux: isInTmux,
                phase: .idle,
                activePrompt: nil,
                lastActivity: now,
                createdAt: now
            )

        metadata.agentID = event.agentId
        metadata.runtimeIdentity = runtimeIdentity
        metadata.cwd = event.cwd
        metadata.pid = event.pid ?? metadata.pid
        metadata.tty = event.tty?.replacingOccurrences(of: "/dev/", with: "") ?? metadata.tty
        metadata.isInTmux = isInTmux || metadata.isInTmux
        metadata.lastActivity = now

        if let prompt = ProjectionRuntimeBuilder.buildPrompt(
            from: event,
            sessionID: event.sessionId,
            runtimeIdentity: runtimeIdentity
        ) {
            metadata.activePrompt = prompt
            metadata.phase = prompt.kind == .approval ? .waitingForApproval : .waitingForInput
        } else {
            metadata.phase = ProjectionRuntimeBuilder.runtimePhase(from: event, current: metadata.phase)
        }

        if let toolUseID = event.toolUseId,
           event.event == HookEventType.postToolUse.rawValue || event.event == HookEventType.interactionResolved.rawValue,
           metadata.activePrompt?.toolUseID == toolUseID {
            metadata.activePrompt = nil
            metadata.phase = event.status == "ended" ? .ended : .processing
        }

        if event.event == HookEventType.stop.rawValue {
            metadata.activePrompt = nil
            metadata.phase = .idle
        }

        if event.status == "ended" || event.event == HookEventType.stop.rawValue {
            runtimeMetadataBySessionID.removeValue(forKey: event.sessionId)
            artifactsBySessionID.removeValue(forKey: event.sessionId)
            cachedUISessionsByID.removeValue(forKey: event.sessionId)
            suppressedSessionIDs.remove(event.sessionId)
            clearedAtBySessionID.removeValue(forKey: event.sessionId)
        } else {
            runtimeMetadataBySessionID[event.sessionId] = metadata
        }

        await rebuildProjectionState()
    }

    func handleProcessDetected(
        sessionID: String,
        cwd: String,
        agentID: String,
        pid: Int?,
        tty: String?
    ) async {
        guard activeModeStartsLiveIngress else { return }

        let runtimeIdentity = RuntimeIdentity.fromLegacyAgentID(agentID)
            ?? RuntimeIdentity(adapterID: .codexCLI, familyID: .codex, modeHint: .unknown)
        let isInTmux = determineTmuxState(pid: pid, tty: tty)
        let now = Date()
        var metadata = runtimeMetadataBySessionID[sessionID]
            ?? ProjectionRuntimeMetadata(
                sessionID: sessionID,
                agentID: agentID,
                runtimeIdentity: runtimeIdentity,
                cwd: cwd,
                pid: pid,
                tty: tty?.replacingOccurrences(of: "/dev/", with: ""),
                isInTmux: isInTmux,
                phase: .processing,
                activePrompt: nil,
                lastActivity: now,
                createdAt: now
            )

        metadata.agentID = agentID
        metadata.runtimeIdentity = runtimeIdentity
        metadata.cwd = cwd
        metadata.pid = pid ?? metadata.pid
        metadata.tty = tty?.replacingOccurrences(of: "/dev/", with: "") ?? metadata.tty
        metadata.isInTmux = isInTmux || metadata.isInTmux
        if metadata.phase == .idle {
            metadata.phase = .processing
        }
        metadata.lastActivity = now
        runtimeMetadataBySessionID[sessionID] = metadata
        clearedAtBySessionID.removeValue(forKey: sessionID)

        await rebuildProjectionState()
    }

    func handleProcessEnded(sessionID: String) async {
        guard activeModeStartsLiveIngress else { return }
        runtimeMetadataBySessionID.removeValue(forKey: sessionID)
        artifactsBySessionID.removeValue(forKey: sessionID)
        cachedUISessionsByID.removeValue(forKey: sessionID)
        suppressedSessionIDs.remove(sessionID)
        clearedAtBySessionID.removeValue(forKey: sessionID)
        await rebuildProjectionState()
    }

    func handleInterruptDetected(sessionID: String) async {
        guard activeModeStartsLiveIngress,
              var metadata = runtimeMetadataBySessionID[sessionID] else { return }
        metadata.phase = .idle
        metadata.lastActivity = Date()
        runtimeMetadataBySessionID[sessionID] = metadata
        await rebuildProjectionState()
    }

    func archiveSession(_ sessionID: String) async {
        suppressedSessionIDs.insert(sessionID)
        await projectionStore.updateConversationStatus(id: sessionID, status: .archived)
        await rebuildProjectionState()
    }

    func restoreSession(_ sessionID: String) async {
        suppressedSessionIDs.remove(sessionID)
        await rebuildProjectionState()
    }

    func clearSessionSurface(_ sessionID: String, clearedAt: Date = Date()) async {
        guard runtimeMetadataBySessionID[sessionID] != nil else { return }
        clearedAtBySessionID[sessionID] = clearedAt
        await rebuildProjectionState()
    }

    func refresh() async {
        guard startedMode != nil else { return }
        await rebuildProjectionState()
    }

    func publishCapability(_ capability: AdapterCapabilitySnapshot) async {
        capabilities[capability.adapterID, default: [:]][capability.semanticArea] = capability
        await projectionStore.publishCapability(capability)
    }

    func trackedSessions() -> [RuntimeTrackedSession] {
        runtimeMetadataBySessionID.values
            .filter { !suppressedSessionIDs.contains($0.sessionID) }
            .map { RuntimeTrackedSession(sessionID: $0.sessionID, pid: $0.pid) }
    }

    func uiSessions() -> [ProjectedSessionViewState] {
        cachedUISessionsByID.values.sorted { lhs, rhs in
            if lhs.needsAttention != rhs.needsAttention {
                return lhs.needsAttention && !rhs.needsAttention
            }
            let leftDate = lhs.lastUserMessageDate ?? lhs.lastActivity
            let rightDate = rhs.lastUserMessageDate ?? rhs.lastActivity
            return leftDate > rightDate
        }
    }

    func uiSession(id: String) -> ProjectedSessionViewState? {
        cachedUISessionsByID[id]
    }

    func fixtureBootSessionID() -> String? {
        fixtureBootSessionIDValue
    }

    func applyCommandDispatch(
        _ result: CanonicalCommandDispatchResult,
        for command: CanonicalCommandEnvelope
    ) async {
        await projectionStore.apply(result, for: command)

        guard var metadata = runtimeMetadataBySessionID[command.conversationID] else { return }
        switch command.type {
        case .approvalResolve:
            if result.status == .accepted,
               metadata.activePrompt?.kind == .approval,
               metadata.activePrompt?.id == command.target.entityID {
                metadata.activePrompt = nil
                metadata.phase = .processing
            }
        case .choiceSubmit:
            if result.status == .accepted,
               metadata.activePrompt?.kind == .choice,
               metadata.activePrompt?.id == command.target.entityID {
                metadata.activePrompt = nil
                metadata.phase = .processing
            }
        case .sessionArchive:
            if result.status == .accepted {
                suppressedSessionIDs.insert(command.conversationID)
            }
        case .sessionFocus, .sessionInterrupt, .sessionClear:
            break
        }

        runtimeMetadataBySessionID[command.conversationID] = metadata
        await rebuildProjectionState()
    }

    private var activeModeStartsLiveIngress: Bool {
        startedMode?.startsLiveIngress == true
    }

    private func loadFixture(
        at path: String,
        initialContent: ProjectionLaunchMode.ProjectionFixtureLaunchConfiguration.InitialContent
    ) async {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let raw = try container.decode(String.self)
                guard let parsed = CanonicalTimestampCoding.date(from: raw) else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "Fixture timestamp must be ISO-8601"
                    )
                }
                return parsed
            }

            let fixture = try decoder.decode(ProjectionFixtureDocument.self, from: data)

            runtimeMetadataBySessionID = Dictionary(
                uniqueKeysWithValues: fixture.sessions.map { metadata in
                    let runtimeIdentity = RuntimeIdentity.fromLegacyAgentID(metadata.agentID)
                        ?? RuntimeIdentity(adapterID: .claudeCode, familyID: .claude, modeHint: .unknown)
                    let conversation = fixture.snapshot.conversations[metadata.sessionID]
                    let activePrompt = ProjectionRuntimeBuilder.prompt(from: conversation, sessionID: metadata.sessionID, agentID: metadata.agentID)
                    return (
                        metadata.sessionID,
                        ProjectionRuntimeMetadata(
                            sessionID: metadata.sessionID,
                            agentID: metadata.agentID,
                            runtimeIdentity: runtimeIdentity,
                            cwd: conversation?.cwd ?? "",
                            pid: metadata.pid,
                            tty: metadata.tty,
                            isInTmux: metadata.isInTmux,
                            phase: ProjectionRuntimeBuilder.runtimePhase(from: conversation, activePrompt: activePrompt),
                            activePrompt: activePrompt,
                            lastActivity: metadata.lastActivity,
                            createdAt: metadata.createdAt ?? metadata.lastActivity
                        )
                    )
                }
            )

            artifactsBySessionID = Dictionary(
                uniqueKeysWithValues: fixture.snapshot.conversations.map { sessionID, conversation in
                    (sessionID, ProjectionRuntimeBuilder.fallbackArtifacts(from: conversation, adapterID: conversation.adapterID))
                }
            )

            capabilities = fixture.snapshot.capabilities
            await projectionStore.replaceSnapshot(fixture.snapshot)

            switch initialContent {
            case .instances:
                fixtureBootSessionIDValue = nil
            case .chat(let sessionID):
                fixtureBootSessionIDValue = sessionID
            }

            cachedUISessionsByID = buildUISessions(
                snapshot: fixture.snapshot,
                hiddenSessionIDs: suppressedSessionIDs
            )
            let compatibility = CompatibilityStateProjector.project(fixture.snapshot)
            ShadowDiffLogger.updateProjectedSnapshot(compatibility.paritySnapshot)
        } catch {
            runtimeMetadataBySessionID.removeAll()
            artifactsBySessionID.removeAll()
            cachedUISessionsByID.removeAll()
            capabilities.removeAll()
            fixtureBootSessionIDValue = nil
            await projectionStore.reset()
            ShadowDiffLogger.updateProjectedSnapshot(nil)
        }
    }

    private func rebuildProjectionState() async {
        let metadataList = runtimeMetadataBySessionID.map(\.value)
        let previousSnapshot = await projectionStore.snapshot()

        if startedMode?.isFixture == true {
            artifactsBySessionID = Dictionary(
                uniqueKeysWithValues: metadataList.map { metadata in
                    let artifacts = fixtureArtifacts(
                        for: metadata,
                        previousConversations: previousSnapshot.conversations
                    )
                    return (metadata.sessionID, artifacts)
                }
            )
        } else {
            artifactsBySessionID = Dictionary(
                uniqueKeysWithValues: await metadataList.asyncMap { [self] metadata in
                    let artifacts = await hydrateArtifacts(for: metadata)
                    return (metadata.sessionID, artifacts)
                }
            )
        }

        let snapshot = buildSnapshot(
            from: metadataList,
            artifactsBySessionID: artifactsBySessionID,
            previousConversations: previousSnapshot.conversations,
            archivedSessionIDs: suppressedSessionIDs
        )
        await projectionStore.replaceSnapshot(snapshot)
        cachedUISessionsByID = buildUISessions(
            snapshot: snapshot,
            hiddenSessionIDs: suppressedSessionIDs
        )
        let compatibility = CompatibilityStateProjector.project(snapshot)
        ShadowDiffLogger.updateProjectedSnapshot(compatibility.paritySnapshot)
    }

    private func fixtureArtifacts(
        for metadata: ProjectionRuntimeMetadata,
        previousConversations: [String: ProjectedConversationState]
    ) -> ProjectionHydratedArtifacts {
        let baseArtifacts = artifactsBySessionID[metadata.sessionID]
            ?? previousConversations[metadata.sessionID].map { conversation in
                ProjectionRuntimeBuilder.fallbackArtifacts(from: conversation, adapterID: metadata.runtimeIdentity.adapterID)
            }
            ?? ProjectionRuntimeBuilder.emptyArtifacts(
                summary: URL(fileURLWithPath: metadata.cwd).lastPathComponent,
                lastUpdatedAt: metadata.lastActivity
            )

        guard clearedAtBySessionID[metadata.sessionID] != nil else {
            return baseArtifacts
        }

        return ProjectionRuntimeBuilder.clearedArtifacts(from: baseArtifacts)
    }

    private func hydrateArtifacts(for metadata: ProjectionRuntimeMetadata) async -> ProjectionHydratedArtifacts {
        let parsedMessages = await ConversationParser.shared.parseFullConversation(
            sessionId: metadata.sessionID,
            cwd: metadata.cwd
        )
        let allCompletedToolIDs = await ConversationParser.shared.completedToolIds(for: metadata.sessionID)
        let allToolResults = await ConversationParser.shared.toolResults(for: metadata.sessionID)
        let allStructuredResults = await ConversationParser.shared.structuredResults(for: metadata.sessionID)
        let parsedConversationInfo = await ConversationParser.shared.parse(
            sessionId: metadata.sessionID,
            cwd: metadata.cwd
        )
        let clearBoundary = clearedAtBySessionID[metadata.sessionID]
        let messages = ProjectionRuntimeBuilder.filteredMessages(
            from: parsedMessages,
            after: clearBoundary
        )
        let visibleToolIDs = ProjectionRuntimeBuilder.visibleToolIDs(in: messages)
        let completedToolIDs = allCompletedToolIDs.intersection(visibleToolIDs)
        let toolResults = allToolResults.filter { visibleToolIDs.contains($0.key) }
        let structuredResults = allStructuredResults.filter { visibleToolIDs.contains($0.key) }
        let conversationInfo = clearBoundary == nil
            ? parsedConversationInfo
            : ProjectionRuntimeBuilder.buildConversationInfo(from: messages)

        let built = ProjectionRuntimeBuilder.buildArtifacts(
            messages: messages,
            completedToolIDs: completedToolIDs,
            toolResults: toolResults,
            structuredResults: structuredResults,
            cwd: metadata.cwd,
            adapterID: metadata.runtimeIdentity.adapterID
        )

        return ProjectionHydratedArtifacts(
            conversationInfo: conversationInfo,
            timeline: built.timeline,
            messages: built.messages,
            tools: built.tools,
            agentDescriptions: built.agentDescriptions,
            lastUpdatedAt: max(built.timeline.last?.timestamp ?? metadata.lastActivity, metadata.lastActivity)
        )
    }

    private func buildSnapshot(
        from metadataList: [ProjectionRuntimeMetadata],
        artifactsBySessionID: [String: ProjectionHydratedArtifacts],
        previousConversations: [String: ProjectedConversationState],
        archivedSessionIDs: Set<String>
    ) -> SessionProjectionSnapshot {
        let conversations = Dictionary(
            uniqueKeysWithValues: metadataList.map { metadata in
                let artifacts = artifactsBySessionID[metadata.sessionID]
                var projected = ProjectionRuntimeBuilder.buildProjectedConversationState(
                    metadata: metadata,
                    artifacts: artifacts
                )
                if let previousConversation = previousConversations[metadata.sessionID] {
                    projected.sessionCommandSubmissionStates = previousConversation.sessionCommandSubmissionStates
                    projected.approvals = ProjectionRuntimeBuilder.mergeApprovalSubmissionStates(
                        current: projected.approvals,
                        previous: previousConversation.approvals
                    )
                    projected.choices = ProjectionRuntimeBuilder.mergeChoiceSubmissionStates(
                        current: projected.choices,
                        previous: previousConversation.choices
                    )
                }
                if archivedSessionIDs.contains(metadata.sessionID) {
                    projected.status = .archived
                    projected.lastTransition = .statusChanged
                }
                return (
                    metadata.sessionID,
                    projected
                )
            }
        )

        return SessionProjectionSnapshot(
            conversations: conversations,
            capabilities: capabilities
        )
    }

    private func buildUISessions(
        snapshot: SessionProjectionSnapshot,
        hiddenSessionIDs: Set<String>
    ) -> [String: ProjectedSessionViewState] {
        Dictionary(
            uniqueKeysWithValues: snapshot.conversations.compactMap { sessionID, conversation -> (String, ProjectedSessionViewState)? in
                guard !hiddenSessionIDs.contains(sessionID) else { return nil }
                guard let metadata = runtimeMetadataBySessionID[sessionID] else { return nil }
                let artifacts = artifactsBySessionID[sessionID]
                    ?? ProjectionRuntimeBuilder.fallbackArtifacts(from: conversation, adapterID: conversation.adapterID)
                let prompt = metadata.activePrompt
                    ?? ProjectionRuntimeBuilder.prompt(from: conversation, sessionID: sessionID, agentID: metadata.agentID)
                let displayTitle = conversation.title
                    ?? artifacts.conversationInfo.summary
                    ?? artifacts.conversationInfo.firstUserMessage
                    ?? URL(fileURLWithPath: metadata.cwd).lastPathComponent
                let pendingToolName = prompt.flatMap(\.toolName)
                    ?? prompt?.toolUseID.flatMap { toolUseID in
                        conversation.tools.first(where: { $0.id == toolUseID })?.name
                    }
                let pendingToolInput = prompt.flatMap(\.toolInputPreview)
                    ?? prompt?.toolUseID.flatMap { toolUseID in
                        conversation.tools.first(where: { $0.id == toolUseID })
                            .flatMap { tool in
                                ProjectionRuntimeBuilder.toolInputPreview(from: tool)
                            }
                    }

                return (
                    sessionID,
                    ProjectedSessionViewState(
                        sessionID: sessionID,
                        adapterID: conversation.adapterID,
                        familyID: conversation.familyID,
                        agentID: metadata.agentID,
                        title: displayTitle,
                        cwd: metadata.cwd,
                        pid: metadata.pid,
                        tty: metadata.tty,
                        isInTmux: metadata.isInTmux,
                        phase: metadata.phase,
                        prompt: prompt,
                        pendingInteractionCount: prompt == nil ? 0 : 1,
                        lastActivity: metadata.lastActivity,
                        createdAt: metadata.createdAt,
                        messages: conversation.messages,
                        tools: conversation.tools,
                        timeline: artifacts.timeline,
                        agentDescriptions: artifacts.agentDescriptions,
                        firstUserMessage: artifacts.conversationInfo.firstUserMessage,
                        lastUserMessage: artifacts.conversationInfo.lastUserMessage,
                        lastUserMessageDate: artifacts.conversationInfo.lastUserMessageDate,
                        lastMessage: artifacts.conversationInfo.lastMessage,
                        lastMessageRole: artifacts.conversationInfo.lastMessageRole,
                        lastToolName: artifacts.conversationInfo.lastToolName,
                        pendingToolName: pendingToolName,
                        pendingToolInput: pendingToolInput
                    )
                )
            }
        )
    }

    private func determineTmuxState(pid: Int?, tty: String?) -> Bool {
        if let pid {
            let tree = ProcessTreeBuilder.shared.buildTree()
            return ProcessTreeBuilder.shared.isInTmux(pid: pid, tree: tree)
        }
        return tty != nil
    }
}

private enum ProjectionRuntimeBuilder {
    struct BuiltArtifacts: Sendable {
        let timeline: [ProjectedTimelineItemState]
        let messages: [ProjectedMessageState]
        let tools: [ProjectedToolState]
        let agentDescriptions: [String: String]
    }

    static func filteredMessages(
        from messages: [ChatMessage],
        after clearBoundary: Date?
    ) -> [ChatMessage] {
        guard let clearBoundary else { return messages }
        return messages.filter { $0.timestamp > clearBoundary }
    }

    static func visibleToolIDs(in messages: [ChatMessage]) -> Set<String> {
        Set(
            messages.flatMap { message in
                message.content.compactMap { block -> String? in
                    guard case .toolUse(let tool) = block else { return nil }
                    return tool.id
                }
            }
        )
    }

    static func buildConversationInfo(from messages: [ChatMessage]) -> ConversationInfo {
        let userMessages = messages.compactMap { message -> (String, Date)? in
            guard message.role == .user else { return nil }
            let text = message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return (text, message.timestamp)
        }

        let lastVisible = messages.reversed().compactMap { message -> (String?, String?, String?)? in
            for block in message.content.reversed() {
                switch block {
                case .text(let text):
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    return (trimmed, message.role.rawValue, nil)
                case .thinking(let text):
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    return (trimmed, ChatRole.assistant.rawValue, nil)
                case .toolUse(let tool):
                    return (tool.preview.isEmpty ? nil : tool.preview, "tool", tool.name)
                case .interrupted:
                    return ("[Request interrupted by user]", ChatRole.assistant.rawValue, nil)
                }
            }
            return nil
        }
        .first

        return ConversationInfo(
            summary: userMessages.first?.0,
            lastMessage: lastVisible?.0,
            lastMessageRole: lastVisible?.1,
            lastToolName: lastVisible?.2,
            firstUserMessage: userMessages.first?.0,
            lastUserMessage: userMessages.last?.0,
            lastUserMessageDate: userMessages.last?.1
        )
    }

    static func emptyArtifacts(
        summary: String?,
        lastUpdatedAt: Date
    ) -> ProjectionHydratedArtifacts {
        ProjectionHydratedArtifacts(
            conversationInfo: ConversationInfo(
                summary: summary,
                lastMessage: nil,
                lastMessageRole: nil,
                lastToolName: nil,
                firstUserMessage: summary,
                lastUserMessage: nil,
                lastUserMessageDate: nil
            ),
            timeline: [],
            messages: [],
            tools: [],
            agentDescriptions: [:],
            lastUpdatedAt: lastUpdatedAt
        )
    }

    static func clearedArtifacts(from base: ProjectionHydratedArtifacts) -> ProjectionHydratedArtifacts {
        ProjectionHydratedArtifacts(
            conversationInfo: ConversationInfo(
                summary: base.conversationInfo.summary,
                lastMessage: nil,
                lastMessageRole: nil,
                lastToolName: nil,
                firstUserMessage: base.conversationInfo.firstUserMessage,
                lastUserMessage: nil,
                lastUserMessageDate: nil
            ),
            timeline: [],
            messages: [],
            tools: [],
            agentDescriptions: base.agentDescriptions,
            lastUpdatedAt: base.lastUpdatedAt
        )
    }

    static func mergeApprovalSubmissionStates(
        current: [ProjectedApprovalState],
        previous: [ProjectedApprovalState]
    ) -> [ProjectedApprovalState] {
        current.map { approval in
            guard let previousApproval = previous.first(where: { $0.id == approval.id }) else {
                return approval
            }

            var merged = approval
            merged.submissionState = previousApproval.submissionState
            merged.resolvedBy = previousApproval.resolvedBy ?? approval.resolvedBy
            merged.updatedAt = max(previousApproval.updatedAt, approval.updatedAt)
            return merged
        }
    }

    static func mergeChoiceSubmissionStates(
        current: [ProjectedChoiceState],
        previous: [ProjectedChoiceState]
    ) -> [ProjectedChoiceState] {
        current.map { choice in
            guard let previousChoice = previous.first(where: { $0.id == choice.id }) else {
                return choice
            }

            var merged = choice
            merged.submissionState = previousChoice.submissionState
            merged.submittedBy = previousChoice.submittedBy ?? choice.submittedBy
            merged.resolvedBy = previousChoice.resolvedBy ?? choice.resolvedBy
            merged.updatedAt = max(previousChoice.updatedAt, choice.updatedAt)
            return merged
        }
    }

    static func buildArtifacts(
        messages: [ChatMessage],
        completedToolIDs: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData],
        cwd: String,
        adapterID: RuntimeAdapterID
    ) -> BuiltArtifacts {
        var timeline: [ProjectedTimelineItemState] = []
        var projectedMessages: [ProjectedMessageState] = []
        var projectedTools: [ProjectedToolState] = []
        var agentDescriptions: [String: String] = [:]
        var seenMessageIDs = Set<String>()

        for message in messages {
            for (index, block) in message.content.enumerated() {
                switch block {
                case .text(let text):
                    let itemID = "\(message.id)-text-\(index)"
                    guard seenMessageIDs.insert(itemID).inserted else { continue }
                    let role: CanonicalMessageRole = message.role == .user ? .user : .assistant
                    projectedMessages.append(
                        ProjectedMessageState(
                            id: itemID,
                            turnID: nil,
                            role: role,
                            format: .markdown,
                            text: text,
                            isFinal: true,
                            sourceKind: .transcript,
                            updatedAt: message.timestamp
                        )
                    )
                    timeline.append(
                        ProjectedTimelineItemState(
                            id: itemID,
                            content: message.role == .user ? .user(text) : .assistant(text),
                            timestamp: message.timestamp
                        )
                    )

                case .thinking(let text):
                    let itemID = "\(message.id)-thinking-\(index)"
                    guard seenMessageIDs.insert(itemID).inserted else { continue }
                    projectedMessages.append(
                        ProjectedMessageState(
                            id: itemID,
                            turnID: nil,
                            role: .assistant,
                            format: .text,
                            text: text,
                            isFinal: false,
                            sourceKind: .transcript,
                            updatedAt: message.timestamp
                        )
                    )
                    timeline.append(
                        ProjectedTimelineItemState(
                            id: itemID,
                            content: .thinking(text),
                            timestamp: message.timestamp
                        )
                    )

                case .interrupted:
                    let itemID = "\(message.id)-interrupted-\(index)"
                    guard seenMessageIDs.insert(itemID).inserted else { continue }
                    timeline.append(
                        ProjectedTimelineItemState(
                            id: itemID,
                            content: .interrupted,
                            timestamp: message.timestamp
                        )
                    )

                case .toolUse(let tool):
                    let status: ToolStatus
                    if completedToolIDs.contains(tool.id) {
                        if toolResults[tool.id]?.isInterrupted == true {
                            status = .interrupted
                        } else if toolResults[tool.id]?.isError == true {
                            status = .error
                        } else {
                            status = .success
                        }
                    } else {
                        status = .running
                    }

                    var resultText: String?
                    if let parserResult = toolResults[tool.id] {
                        resultText = parserResult.stdout
                        if resultText?.isEmpty != false { resultText = parserResult.stderr }
                        if resultText?.isEmpty != false { resultText = parserResult.content }
                    }

                    var subagentTools: [SubagentToolCall] = []
                    if let structuredResult = structuredResults[tool.id],
                       case .task(let taskResult) = structuredResult,
                       !taskResult.agentId.isEmpty {
                        if let descriptionBinding = RuntimeSemanticRegistry
                            .semanticPlane(for: adapterID)?
                            .agentDescription(
                                name: tool.name,
                                input: tool.input,
                                structuredResult: structuredResult
                            ) {
                            agentDescriptions[descriptionBinding.agentID] = descriptionBinding.description
                        }

                        let subagentToolInfos = ConversationParser.parseSubagentToolsSync(
                            agentId: taskResult.agentId,
                            cwd: cwd
                        )
                        subagentTools = subagentToolInfos.map { info in
                            SubagentToolCall(
                                id: info.id,
                                name: info.name,
                                input: info.input,
                                status: info.isCompleted ? .success : .running,
                                timestamp: parseTimestamp(info.timestamp) ?? message.timestamp
                            )
                        }
                    }

                    let toolCall = ToolCallItem(
                        name: tool.name,
                        input: tool.input,
                        status: status,
                        result: resultText,
                        structuredResult: structuredResults[tool.id],
                        subagentTools: subagentTools,
                        headerDetailText: RuntimeSemanticRegistry
                            .semanticPlane(for: adapterID)?
                            .toolHeaderDetail(
                            name: tool.name,
                            input: tool.input,
                            structuredResult: structuredResults[tool.id],
                            agentDescriptions: agentDescriptions
                        ),
                        pendingDetailsText: RuntimeSemanticRegistry
                            .semanticPlane(for: adapterID)?
                            .toolPendingDetails(
                            name: tool.name,
                            input: tool.input,
                            status: status
                        )
                    )

                    projectedTools.append(
                        ProjectedToolState(
                            id: tool.id,
                            name: tool.name,
                            kind: canonicalToolKind(for: tool.name),
                            input: tool.input.mapValues(AnyCodable.init),
                            output: projectedToolOutput(from: toolCall),
                            state: projectedToolState(for: status),
                            errorKind: status == .error ? .runtimeError : nil,
                            updatedAt: message.timestamp
                        )
                    )
                    timeline.append(
                        ProjectedTimelineItemState(
                            id: tool.id,
                            content: .tool(toolCall),
                            timestamp: message.timestamp
                        )
                    )
                }
            }
        }

        timeline.sort {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.id < $1.id
        }
        projectedMessages.sort {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
            return $0.id < $1.id
        }
        projectedTools.sort {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
            return $0.id < $1.id
        }

        return BuiltArtifacts(
            timeline: timeline,
            messages: projectedMessages,
            tools: projectedTools,
            agentDescriptions: agentDescriptions
        )
    }

    static func fallbackArtifacts(
        from conversation: ProjectedConversationState,
        adapterID: RuntimeAdapterID
    ) -> ProjectionHydratedArtifacts {
        let timelineMessages = conversation.messages.map { message -> ProjectedTimelineItemState in
            let content: ProjectedTimelineItemContent
            switch message.role {
            case .user:
                content = .user(message.text)
            case .assistant, .system, .tool:
                content = .assistant(message.text)
            }
            return ProjectedTimelineItemState(
                id: message.id,
                content: content,
                timestamp: message.updatedAt
            )
        }

        let timelineTools = conversation.tools.map { tool -> ProjectedTimelineItemState in
            let flattenedInput = tool.input.compactMapValues { any in
                switch any.value {
                case let value as String:
                    return value
                case let value as Int:
                    return String(value)
                case let value as Double:
                    return String(value)
                case let value as Bool:
                    return value ? "true" : "false"
                default:
                    return nil
                }
            }
            let toolCall = ToolCallItem(
                name: tool.name,
                input: flattenedInput,
                status: toolStatus(from: tool.state),
                result: tool.output["text"]?.value as? String,
                structuredResult: nil,
                subagentTools: [],
                headerDetailText: RuntimeSemanticRegistry
                    .semanticPlane(for: adapterID)?
                    .toolHeaderDetail(
                    name: tool.name,
                    input: flattenedInput,
                    structuredResult: nil,
                    agentDescriptions: [:]
                ),
                pendingDetailsText: RuntimeSemanticRegistry
                    .semanticPlane(for: adapterID)?
                    .toolPendingDetails(
                    name: tool.name,
                    input: flattenedInput,
                    status: toolStatus(from: tool.state)
                )
            )
            return ProjectedTimelineItemState(
                id: tool.id,
                content: .tool(toolCall),
                timestamp: tool.updatedAt
            )
        }

        let timeline = (timelineMessages + timelineTools).sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.id < $1.id
        }

        let sortedMessages = conversation.messages.sorted { $0.updatedAt < $1.updatedAt }
        let lastMessage = sortedMessages.last?.text ?? conversation.tools.sorted { $0.updatedAt < $1.updatedAt }.last?.name
        let lastMessageRole = sortedMessages.last?.role.rawValue
        let lastToolName = conversation.tools.sorted { $0.updatedAt < $1.updatedAt }.last?.name
        let firstUserMessage = sortedMessages.first(where: { $0.role == .user })?.text ?? conversation.title
        let lastUserMessage = sortedMessages.last(where: { $0.role == .user })?.text
        let lastUserMessageDate = sortedMessages.last(where: { $0.role == .user })?.updatedAt

        return ProjectionHydratedArtifacts(
            conversationInfo: ConversationInfo(
                summary: conversation.title,
                lastMessage: lastMessage,
                lastMessageRole: lastMessageRole,
                lastToolName: lastToolName,
                firstUserMessage: firstUserMessage,
                lastUserMessage: lastUserMessage,
                lastUserMessageDate: lastUserMessageDate
            ),
            timeline: timeline,
            messages: conversation.messages,
            tools: conversation.tools,
            agentDescriptions: [:],
            lastUpdatedAt: conversation.lastUpdatedAt
        )
    }

    static func buildProjectedConversationState(
        metadata: ProjectionRuntimeMetadata,
        artifacts: ProjectionHydratedArtifacts?
    ) -> ProjectedConversationState {
        let approvalState = metadata.activePrompt.flatMap { prompt -> ProjectedApprovalState? in
            guard prompt.kind == .approval else { return nil }
            return ProjectedApprovalState(
                id: prompt.id,
                toolID: prompt.toolUseID,
                kind: .tool,
                reason: prompt.question,
                options: [.allowOnce, .deny, .cancel],
                scope: .once,
                strength: .strong,
                domainState: .requested,
                submissionState: .idle,
                resolvedBy: nil,
                updatedAt: prompt.createdAt
            )
        }

        let choiceState = metadata.activePrompt.flatMap { prompt -> ProjectedChoiceState? in
            guard prompt.kind == .choice else { return nil }
            return ProjectedChoiceState(
                id: prompt.id,
                toolID: prompt.toolUseID,
                kind: .options,
                prompt: prompt.question,
                schema: [:],
                options: prompt.options.map { AnyCodable($0.label) },
                domainState: .requested,
                submissionState: .idle,
                submittedBy: nil,
                resolvedBy: nil,
                valueShape: prompt.isMultiQuestion ? .form : .options,
                updatedAt: prompt.createdAt
            )
        }

        let title = artifacts?.conversationInfo.summary
            ?? artifacts?.conversationInfo.firstUserMessage
            ?? URL(fileURLWithPath: metadata.cwd).lastPathComponent

        return ProjectedConversationState(
            id: metadata.sessionID,
            adapterID: metadata.runtimeIdentity.adapterID,
            familyID: metadata.runtimeIdentity.familyID,
            sourceKind: .hook,
            title: title,
            cwd: metadata.cwd,
            status: projectedConversationStatus(from: metadata.phase),
            lastTransition: .statusChanged,
            turn: CanonicalTurnDescriptor(id: nil, status: projectedTurnStatus(from: metadata.phase)),
            messages: artifacts?.messages ?? [],
            tools: artifacts?.tools ?? [],
            approvals: approvalState.map { [$0] } ?? [],
            choices: choiceState.map { [$0] } ?? [],
            plans: [],
            sessionCommandSubmissionStates: [:],
            lastUpdatedAt: artifacts?.lastUpdatedAt ?? metadata.lastActivity
        )
    }

    static func prompt(
        from conversation: ProjectedConversationState?,
        sessionID: String,
        agentID: String
    ) -> ProjectedPromptState? {
        guard let conversation else { return nil }

        if let approval = conversation.approvals.first(where: { $0.domainState == .requested }) {
            let tool = approval.toolID.flatMap { toolID in
                conversation.tools.first(where: { $0.id == toolID })
            }
            let promptText = approval.reason ?? "Allow this tool to run?"
            let question = ProjectedInteractionQuestionState(
                id: "permission-\(approval.id)",
                header: "Permission required",
                question: promptText,
                options: RuntimeSemanticSupport.approvalOptions()
            )
            return ProjectedPromptState(
                id: approval.id,
                sessionID: sessionID,
                toolUseID: approval.toolID ?? approval.id,
                toolName: tool?.name,
                toolInputPreview: tool.flatMap { tool in
                    ProjectionRuntimeBuilder.toolInputPreview(from: tool)
                },
                sourceAgentID: agentID,
                kind: .approval,
                title: "Permission required",
                questions: [question],
                preferredOptionID: "allow",
                createdAt: approval.updatedAt,
                responseCapability: .nativeHookAvailable,
                submissionEncoding: .optionValue,
                programmaticStrategy: .none,
                sourceToolInputJSON: nil
            )
        }

        if let choice = conversation.choices.first(where: {
            $0.domainState == .requested || $0.submissionState == .submissionPending
        }) {
            let options = choice.options.enumerated().compactMap { index, option -> ProjectedInteractionOptionState? in
                guard let label = option.value as? String, !label.isEmpty else { return nil }
                return ProjectedInteractionOptionState(
                    id: "\(index)-\(label)",
                    label: label,
                    submissionValue: String(index + 1),
                    detail: nil,
                    role: index == 0 ? .primary : .secondary
                )
            }
            let question = ProjectedInteractionQuestionState(
                id: choice.id,
                header: "Choose",
                question: choice.prompt ?? "Choose an option",
                options: options
            )
            return ProjectedPromptState(
                id: choice.id,
                sessionID: sessionID,
                toolUseID: choice.toolID ?? choice.id,
                toolName: choice.toolID.flatMap { toolID in
                    conversation.tools.first(where: { $0.id == toolID })?.name
                },
                toolInputPreview: choice.toolID.flatMap { toolID in
                    conversation.tools.first(where: { $0.id == toolID }).flatMap { tool in
                        ProjectionRuntimeBuilder.toolInputPreview(from: tool)
                    }
                },
                sourceAgentID: agentID,
                kind: .choice,
                title: "Choose an option",
                questions: [question],
                preferredOptionID: options.first?.id,
                createdAt: choice.updatedAt,
                responseCapability: .nativeHookAvailable,
                submissionEncoding: .optionLabel,
                programmaticStrategy: .none,
                sourceToolInputJSON: nil
            )
        }

        return nil
    }

    static func runtimePhase(
        from event: HookEvent,
        current: ProjectedSessionRuntimePhase
    ) -> ProjectedSessionRuntimePhase {
        if event.event == HookEventType.preCompact.rawValue || event.status == "compacting" {
            return .compacting
        }
        if event.status == "ended" || event.event == HookEventType.sessionEnd.rawValue {
            return .ended
        }
        switch event.status {
        case "running_tool", "processing", "starting":
            return .processing
        case "waiting_for_input":
            return .waitingForInput
        case "waiting_for_approval":
            return .waitingForApproval
        case "idle":
            return .idle
        default:
            return current
        }
    }

    static func runtimePhase(
        from conversation: ProjectedConversationState?,
        activePrompt: ProjectedPromptState?
    ) -> ProjectedSessionRuntimePhase {
        if let activePrompt {
            return activePrompt.kind == .approval ? .waitingForApproval : .waitingForInput
        }
        switch conversation?.status {
        case .active:
            return .processing
        case .completed, .archived:
            return .ended
        case .idle, .errored, .unknown, .none:
            return .idle
        }
    }

    static func buildPrompt(
        from event: HookEvent,
        sessionID: String,
        runtimeIdentity: RuntimeIdentity
    ) -> ProjectedPromptState? {
        RuntimeSemanticRegistry.semanticPlane(for: runtimeIdentity.adapterID)?
            .promptState(from: event, sessionID: sessionID, createdAt: Date())
    }

    static func projectedConversationStatus(from phase: ProjectedSessionRuntimePhase) -> CanonicalConversationStatus {
        switch phase {
        case .processing, .compacting, .waitingForApproval, .waitingForInput:
            return .active
        case .ended:
            return .completed
        case .idle:
            return .idle
        }
    }

    static func projectedTurnStatus(from phase: ProjectedSessionRuntimePhase) -> CanonicalTurnStatus {
        switch phase {
        case .processing, .compacting, .waitingForApproval, .waitingForInput:
            return .inProgress
        case .ended:
            return .completed
        case .idle:
            return .unknown
        }
    }

    static func projectedToolState(for status: ToolStatus) -> ProjectedToolLifecycleState {
        switch status {
        case .running:
            return .running
        case .waitingForApproval:
            return .started
        case .success:
            return .completed
        case .error:
            return .failed
        case .interrupted:
            return .cancelled
        }
    }

    static func projectedToolOutput(from tool: ToolCallItem) -> [String: AnyCodable] {
        var output: [String: AnyCodable] = [:]
        if let result = tool.result {
            output["text"] = AnyCodable(result)
        }
        return output
    }

    static func canonicalToolKind(for name: String) -> CanonicalToolKind {
        switch name.lowercased() {
        case "bash", "bashoutput", "killshell":
            return .bash
        case "read", "write", "edit", "patch":
            return .file
        case "webfetch", "websearch":
            return .search
        default:
            return .other
        }
    }

    static func toolStatus(from state: ProjectedToolLifecycleState) -> ToolStatus {
        switch state {
        case .started, .running:
            return .running
        case .completed:
            return .success
        case .failed, .declined:
            return .error
        case .cancelled, .timedOut:
            return .interrupted
        }
    }

    static func toolInputPreview(from tool: ProjectedToolState) -> String? {
        formatToolInputPreview(from: tool.input)
    }

    static func toolInputPreview(from tool: ToolCallItem) -> String? {
        tool.inputPreview.isEmpty ? nil : tool.inputPreview
    }

    static func formatToolInputPreview(from toolInput: [String: AnyCodable]) -> String? {
        let parts = toolInput.map { key, value -> String in
            let valueString: String
            switch value.value {
            case let string as String:
                valueString = string.count > 120 ? String(string.prefix(120)) + "..." : string
            case let number as Int:
                valueString = String(number)
            case let number as Double:
                valueString = String(number)
            case let bool as Bool:
                valueString = bool ? "true" : "false"
            case let dict as [String: Any]:
                valueString = formatJSONObject(dict)
            case let array as [Any]:
                valueString = formatJSONArray(array)
            default:
                valueString = "..."
            }
            return "\(key): \(valueString)"
        }
        let joined = parts.sorted().joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    static func formatToolInputPreview(from toolInput: [String: AnyCodable]?) -> String? {
        guard let toolInput else { return nil }
        return formatToolInputPreview(from: toolInput)
    }

    static func encodeToolInputJSON(_ payload: [String: AnyCodable]) -> String? {
        guard let data = try? JSONEncoder().encode(payload) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func parseTimestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        return CanonicalTimestampCoding.date(from: value)
    }

    static func formatJSONObject(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]),
              var string = String(data: data, encoding: .utf8) else {
            return "..."
        }
        if string.count > 160 {
            string = String(string.prefix(160)) + "..."
        }
        return string
    }

    static func formatJSONArray(_ array: [Any]) -> String {
        guard JSONSerialization.isValidJSONObject(array),
              let data = try? JSONSerialization.data(withJSONObject: array, options: [.fragmentsAllowed]),
              var string = String(data: data, encoding: .utf8) else {
            return "..."
        }
        if string.count > 160 {
            string = String(string.prefix(160)) + "..."
        }
        return string
    }

}

private extension Array where Element: Sendable {
    func asyncMap<T: Sendable>(
        _ transform: @Sendable @escaping (Element) async -> T
    ) async -> [T] {
        await withTaskGroup(of: (Int, T).self) { group in
            for (index, element) in enumerated() {
                group.addTask {
                    (index, await transform(element))
                }
            }

            var values = Array<T?>(repeating: nil, count: count)
            for await (index, value) in group {
                values[index] = value
            }

            return values.compactMap { $0 }
        }
    }
}
