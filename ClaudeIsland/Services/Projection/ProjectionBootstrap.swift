//
//  ProjectionBootstrap.swift
//  ClaudeIsland
//
//  Minimal Phase 1 projection runtime bootstrap for live ingress and fixtures.
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
    var phase: SessionPhase
    var activeInteraction: SessionInteractionRequest?
    var lastActivity: Date
    let createdAt: Date
}

private struct ProjectionHydratedArtifacts: Sendable {
    let conversationInfo: ConversationInfo
    let chatItems: [ChatHistoryItem]
    let subagentState: SubagentState
    let lastUpdatedAt: Date
}

actor ProjectionBootstrap {
    static let shared = ProjectionBootstrap()

    nonisolated let eventBus = CanonicalEventBus()
    nonisolated let projectionStore = SessionProjectionStore()

    private var startedMode: ProjectionLaunchMode?
    private var runtimeMetadataBySessionID: [String: ProjectionRuntimeMetadata] = [:]
    private var suppressedSessionIDs: Set<String> = []

    private init() {}

    func start(mode: ProjectionLaunchMode = .current) async {
        guard startedMode == nil else { return }
        startedMode = mode

        switch mode {
        case .live:
            await rebuildProjectionState()
        case .projectedFixture(let configuration):
            await loadFixture(at: configuration.fixturePath, initialContent: configuration.initialContent)
        }
    }

    func stop() async {
        startedMode = nil
        runtimeMetadataBySessionID.removeAll()
        suppressedSessionIDs.removeAll()
        await projectionStore.reset()
        await MainActor.run {
            ProjectionCompatibilityStore.shared.clear()
        }
    }

    func handleHookEvent(_ event: HookEvent) async {
        guard activeModeStartsLiveIngress else { return }

        let runtimeIdentity = event.legacyRuntimeIdentity
            ?? RuntimeIdentity(adapterID: .claudeCode, familyID: .claude, modeHint: .unknown)
        let currentPhase = event.determinePhase()
        let now = Date()
        let isInTmux: Bool

        if let pid = event.pid {
            let tree = ProcessTreeBuilder.shared.buildTree()
            isInTmux = ProcessTreeBuilder.shared.isInTmux(pid: pid, tree: tree)
        } else {
            isInTmux = event.tty != nil
        }

        if var existing = runtimeMetadataBySessionID[event.sessionId] {
            existing.agentID = event.agentId
            existing.runtimeIdentity = runtimeIdentity
            existing.cwd = event.cwd
            existing.pid = event.pid ?? existing.pid
            existing.tty = event.tty?.replacingOccurrences(of: "/dev/", with: "") ?? existing.tty
            existing.isInTmux = isInTmux || existing.isInTmux
            existing.phase = currentPhase
            existing.activeInteraction = buildActiveInteraction(
                from: event,
                sessionID: event.sessionId,
                isInTmux: isInTmux,
                tty: existing.tty
            ) ?? existing.activeInteraction
            existing.lastActivity = now
            runtimeMetadataBySessionID[event.sessionId] = existing
        } else {
            runtimeMetadataBySessionID[event.sessionId] = ProjectionRuntimeMetadata(
                sessionID: event.sessionId,
                agentID: event.agentId,
                runtimeIdentity: runtimeIdentity,
                cwd: event.cwd,
                pid: event.pid,
                tty: event.tty?.replacingOccurrences(of: "/dev/", with: ""),
                isInTmux: isInTmux,
                phase: currentPhase,
                activeInteraction: buildActiveInteraction(
                    from: event,
                    sessionID: event.sessionId,
                    isInTmux: isInTmux,
                    tty: event.tty?.replacingOccurrences(of: "/dev/", with: "")
                ),
                lastActivity: now,
                createdAt: now
            )
        }

        if let toolUseID = event.toolUseId,
           event.event == HookEventType.postToolUse.rawValue || event.event == HookEventType.interactionResolved.rawValue,
           runtimeMetadataBySessionID[event.sessionId]?.activeInteraction?.toolUseId == toolUseID {
            runtimeMetadataBySessionID[event.sessionId]?.activeInteraction = nil
        }

        if event.event == HookEventType.stop.rawValue {
            runtimeMetadataBySessionID[event.sessionId]?.activeInteraction = nil
        }

        if event.status == "ended" || event.event == HookEventType.stop.rawValue {
            runtimeMetadataBySessionID.removeValue(forKey: event.sessionId)
            suppressedSessionIDs.remove(event.sessionId)
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
        let isInTmux: Bool
        if let pid {
            let tree = ProcessTreeBuilder.shared.buildTree()
            isInTmux = ProcessTreeBuilder.shared.isInTmux(pid: pid, tree: tree)
        } else {
            isInTmux = tty != nil
        }

        let now = Date()
        if var existing = runtimeMetadataBySessionID[sessionID] {
            existing.agentID = agentID
            existing.runtimeIdentity = runtimeIdentity
            existing.cwd = cwd
            existing.pid = pid ?? existing.pid
            existing.tty = tty?.replacingOccurrences(of: "/dev/", with: "") ?? existing.tty
            existing.isInTmux = isInTmux || existing.isInTmux
            existing.phase = existing.phase == .idle ? .processing : existing.phase
            existing.lastActivity = now
            runtimeMetadataBySessionID[sessionID] = existing
        } else {
            runtimeMetadataBySessionID[sessionID] = ProjectionRuntimeMetadata(
                sessionID: sessionID,
                agentID: agentID,
                runtimeIdentity: runtimeIdentity,
                cwd: cwd,
                pid: pid,
                tty: tty?.replacingOccurrences(of: "/dev/", with: ""),
                isInTmux: isInTmux,
                phase: .processing,
                activeInteraction: nil,
                lastActivity: now,
                createdAt: now
            )
        }

        await rebuildProjectionState()
    }

    func handleProcessEnded(sessionID: String) async {
        guard activeModeStartsLiveIngress else { return }
        runtimeMetadataBySessionID.removeValue(forKey: sessionID)
        suppressedSessionIDs.remove(sessionID)
        await rebuildProjectionState()
    }

    func handleInterruptDetected(sessionID: String) async {
        guard activeModeStartsLiveIngress else { return }
        guard var metadata = runtimeMetadataBySessionID[sessionID] else { return }
        metadata.phase = .idle
        metadata.lastActivity = Date()
        runtimeMetadataBySessionID[sessionID] = metadata
        await rebuildProjectionState()
    }

    func archiveSession(_ sessionID: String) async {
        suppressedSessionIDs.insert(sessionID)
        await rebuildProjectionState()
    }

    func restoreSession(_ sessionID: String) async {
        suppressedSessionIDs.remove(sessionID)
        await rebuildProjectionState()
    }

    func refresh() async {
        guard startedMode != nil else { return }
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
                    return (
                        metadata.sessionID,
                        ProjectionRuntimeMetadata(
                            sessionID: metadata.sessionID,
                            agentID: metadata.agentID,
                            runtimeIdentity: runtimeIdentity,
                            cwd: fixture.snapshot.conversations[metadata.sessionID]?.cwd ?? "",
                            pid: metadata.pid,
                            tty: metadata.tty,
                            isInTmux: metadata.isInTmux,
                            phase: fixture.snapshot.conversations[metadata.sessionID].map {
                                switch $0.status {
                                case .active:
                                    return .processing
                                case .completed, .archived:
                                    return .ended
                                case .idle, .errored, .unknown:
                                    return .idle
                                }
                            } ?? .idle,
                            activeInteraction: nil,
                            lastActivity: metadata.lastActivity,
                            createdAt: metadata.createdAt ?? metadata.lastActivity
                        )
                    )
                }
            )

            await projectionStore.replaceSnapshot(fixture.snapshot)

            let sessions = buildCompatibilitySessions(
                snapshot: fixture.snapshot,
                artifactsBySessionID: [:]
            )
            let compatibility = CompatibilityStateProjector.project(fixture.snapshot)
            ShadowDiffLogger.updateProjectedSnapshot(compatibility.paritySnapshot)
            let fixtureBootSessionID: String?
            switch initialContent {
            case .instances:
                fixtureBootSessionID = nil
            case .chat(let sessionID):
                fixtureBootSessionID = sessionID
            }
            await MainActor.run {
                ProjectionCompatibilityStore.shared.update(
                    sessions: sessions,
                    hydratedSessionIDs: Set(fixture.snapshot.conversations.keys),
                    fixtureBootSessionID: fixtureBootSessionID
                )
            }
        } catch {
            await projectionStore.reset()
            await MainActor.run {
                ProjectionCompatibilityStore.shared.clear()
            }
        }
    }

    private func rebuildProjectionState() async {
        let activeMetadata = runtimeMetadataBySessionID
            .filter { !suppressedSessionIDs.contains($0.key) }
            .map(\.value)

        let artifactsBySessionID = Dictionary(
            uniqueKeysWithValues: await activeMetadata.asyncMap { metadata in
                let artifacts = await hydrateArtifacts(for: metadata)
                return (metadata.sessionID, artifacts)
            }
        )

        let snapshot = buildSnapshot(
            from: activeMetadata,
            artifactsBySessionID: artifactsBySessionID
        )
        await projectionStore.replaceSnapshot(snapshot)

        let sessions = buildCompatibilitySessions(
            snapshot: snapshot,
            artifactsBySessionID: artifactsBySessionID
        )
        let compatibility = CompatibilityStateProjector.project(snapshot)
        ShadowDiffLogger.updateProjectedSnapshot(compatibility.paritySnapshot)
        await MainActor.run {
            ProjectionCompatibilityStore.shared.update(
                sessions: sessions,
                hydratedSessionIDs: Set(snapshot.conversations.keys),
                fixtureBootSessionID: nil
            )
        }
    }

    private func hydrateArtifacts(for metadata: ProjectionRuntimeMetadata) async -> ProjectionHydratedArtifacts {
        let messages = await ConversationParser.shared.parseFullConversation(
            sessionId: metadata.sessionID,
            cwd: metadata.cwd
        )
        let completedToolIDs = await ConversationParser.shared.completedToolIds(for: metadata.sessionID)
        let toolResults = await ConversationParser.shared.toolResults(for: metadata.sessionID)
        let structuredResults = await ConversationParser.shared.structuredResults(for: metadata.sessionID)
        let conversationInfo = await ConversationParser.shared.parse(
            sessionId: metadata.sessionID,
            cwd: metadata.cwd
        )

        var chatItems: [ChatHistoryItem] = []
        var existingIDs = Set<String>()
        var toolTracker = ToolTracker()
        var subagentState = SubagentState()

        for message in messages {
            for (index, block) in message.content.enumerated() {
                guard let item = ProjectionCompatibilityBuilder.createChatItem(
                    from: block,
                    message: message,
                    blockIndex: index,
                    existingIDs: existingIDs,
                    completedTools: completedToolIDs,
                    toolResults: toolResults,
                    structuredResults: structuredResults,
                    toolTracker: &toolTracker
                ) else {
                    continue
                }
                existingIDs.insert(item.id)
                chatItems.append(item)
            }
        }

        ProjectionCompatibilityBuilder.populateSubagentArtifacts(
            chatItems: &chatItems,
            subagentState: &subagentState,
            cwd: metadata.cwd,
            structuredResults: structuredResults
        )

        return ProjectionHydratedArtifacts(
            conversationInfo: conversationInfo,
            chatItems: chatItems.sorted { $0.timestamp < $1.timestamp },
            subagentState: subagentState,
            lastUpdatedAt: max(chatItems.last?.timestamp ?? metadata.lastActivity, metadata.lastActivity)
        )
    }

    private func buildSnapshot(
        from metadataList: [ProjectionRuntimeMetadata],
        artifactsBySessionID: [String: ProjectionHydratedArtifacts]
    ) -> SessionProjectionSnapshot {
        let conversations = Dictionary(
            uniqueKeysWithValues: metadataList.map { metadata in
                let artifacts = artifactsBySessionID[metadata.sessionID]
                return (
                    metadata.sessionID,
                    ProjectionCompatibilityBuilder.buildProjectedConversationState(
                        metadata: metadata,
                        artifacts: artifacts
                    )
                )
            }
        )

        let capabilities = Dictionary(
            uniqueKeysWithValues: Dictionary(
                uniqueKeysWithValues: metadataList.map { ($0.runtimeIdentity.adapterID.rawValue, $0.runtimeIdentity.adapterID) }
            ).values.map { adapterID in
                (
                    adapterID,
                    ProjectionCompatibilityBuilder.defaultCapabilities(
                        for: adapterID
                    )
                )
            }
        )

        return SessionProjectionSnapshot(
            conversations: conversations,
            capabilities: capabilities
        )
    }

    private func buildCompatibilitySessions(
        snapshot: SessionProjectionSnapshot,
        artifactsBySessionID: [String: ProjectionHydratedArtifacts]
    ) -> [SessionState] {
        snapshot.conversations.keys.compactMap { sessionID in
            guard let metadata = runtimeMetadataBySessionID[sessionID],
                  let conversation = snapshot.conversations[sessionID] else {
                return nil
            }
            return ProjectionCompatibilityBuilder.buildCompatibilitySessionState(
                metadata: metadata,
                conversation: conversation,
                artifacts: artifactsBySessionID[sessionID]
            )
        }
        .sorted { lhs, rhs in
            if lhs.needsAttention != rhs.needsAttention {
                return lhs.needsAttention && !rhs.needsAttention
            }
            let leftDate = lhs.lastUserMessageDate ?? lhs.lastActivity
            let rightDate = rhs.lastUserMessageDate ?? rhs.lastActivity
            return leftDate > rightDate
        }
    }
}

private enum ProjectionCompatibilityBuilder {
    static func buildProjectedConversationState(
        metadata: ProjectionRuntimeMetadata,
        artifacts: ProjectionHydratedArtifacts?
    ) -> ProjectedConversationState {
        let toolStates = buildProjectedTools(from: artifacts?.chatItems ?? [])
        let approvalState = buildApprovalState(from: metadata)
        let choiceState = buildChoiceState(from: metadata)
        let projectedMessages = buildProjectedMessages(from: artifacts?.chatItems ?? [])

        return ProjectedConversationState(
            id: metadata.sessionID,
            adapterID: metadata.runtimeIdentity.adapterID,
            familyID: metadata.runtimeIdentity.familyID,
            sourceKind: .hook,
            title: artifacts?.conversationInfo.summary ?? artifacts?.conversationInfo.firstUserMessage ?? URL(fileURLWithPath: metadata.cwd).lastPathComponent,
            cwd: metadata.cwd,
            status: projectedConversationStatus(from: metadata.phase),
            lastTransition: .statusChanged,
            turn: CanonicalTurnDescriptor(id: nil, status: projectedTurnStatus(from: metadata.phase)),
            messages: projectedMessages,
            tools: toolStates,
            approvals: approvalState.map { [$0] } ?? [],
            choices: choiceState.map { [$0] } ?? [],
            plans: [],
            sessionCommandSubmissionStates: [:],
            lastUpdatedAt: artifacts?.lastUpdatedAt ?? metadata.lastActivity
        )
    }

    static func buildCompatibilitySessionState(
        metadata: ProjectionRuntimeMetadata,
        conversation: ProjectedConversationState,
        artifacts: ProjectionHydratedArtifacts?
    ) -> SessionState {
        let permissionContext = buildPermissionContext(from: conversation)
        let activeInteraction = buildActiveInteraction(
            metadata: metadata,
            from: conversation,
            permissionContext: permissionContext,
            sessionID: metadata.sessionID,
            agentID: metadata.agentID,
            isInTmux: metadata.isInTmux,
            tty: metadata.tty
        )

        var phase = metadata.phase
        if let permissionContext {
            phase = .waitingForApproval(permissionContext)
        } else if activeInteraction != nil {
            phase = .waitingForInput
        } else if phase.isWaitingForApproval {
            phase = .processing
        }

        var chatItems = artifacts?.chatItems ?? fallbackChatItems(from: conversation)
        if let interaction = activeInteraction {
            appendCompatibilityInteractionItems(
                interaction: interaction,
                permissionContext: permissionContext,
                sessionID: metadata.sessionID,
                into: &chatItems
            )
        }
        chatItems.sort { $0.timestamp < $1.timestamp }

        let fallbackConversationInfo = fallbackConversationInfo(
            from: conversation,
            cwd: metadata.cwd
        )
        let lastUserMessage = artifacts?.conversationInfo.lastUserMessage ?? fallbackConversationInfo.lastUserMessage
        let firstUserMessage = artifacts?.conversationInfo.firstUserMessage ?? fallbackConversationInfo.firstUserMessage

        var toolTracker = ToolTracker()
        toolTracker.inProgress = Dictionary(
            uniqueKeysWithValues: conversation.tools.compactMap { tool -> (String, ToolInProgress)? in
                guard tool.state == .started || tool.state == .running else { return nil }
                return (
                    tool.id,
                    ToolInProgress(
                        id: tool.id,
                        name: tool.name,
                        startTime: tool.updatedAt,
                        phase: tool.state == .started ? .starting : .running
                    )
                )
            }
        )
        toolTracker.seenIds = Set(conversation.tools.map(\.id))
        toolTracker.lastSyncTime = artifacts?.lastUpdatedAt

        return SessionState(
            sessionId: metadata.sessionID,
            cwd: metadata.cwd,
            projectName: URL(fileURLWithPath: metadata.cwd).lastPathComponent,
            agentId: metadata.agentID,
            pid: metadata.pid,
            tty: metadata.tty,
            isInTmux: metadata.isInTmux,
            phase: phase,
            chatItems: chatItems,
            toolTracker: toolTracker,
            subagentState: artifacts?.subagentState ?? SubagentState(),
            conversationInfo: ConversationInfo(
                summary: artifacts?.conversationInfo.summary ?? fallbackConversationInfo.summary,
                lastMessage: artifacts?.conversationInfo.lastMessage ?? fallbackConversationInfo.lastMessage,
                lastMessageRole: artifacts?.conversationInfo.lastMessageRole ?? fallbackConversationInfo.lastMessageRole,
                lastToolName: artifacts?.conversationInfo.lastToolName ?? fallbackConversationInfo.lastToolName,
                firstUserMessage: firstUserMessage,
                lastUserMessage: lastUserMessage,
                lastUserMessageDate: artifacts?.conversationInfo.lastUserMessageDate ?? fallbackConversationInfo.lastUserMessageDate
            ),
            normalizedInteraction: activeInteraction?.origin == .normalizedHook ? activeInteraction : nil,
            activeInteraction: activeInteraction,
            pendingInteractionCount: activeInteraction == nil ? 0 : 1,
            lastActivity: metadata.lastActivity,
            createdAt: metadata.createdAt
        )
    }

    static func createChatItem(
        from block: MessageBlock,
        message: ChatMessage,
        blockIndex: Int,
        existingIDs: Set<String>,
        completedTools: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData],
        toolTracker: inout ToolTracker
    ) -> ChatHistoryItem? {
        switch block {
        case .text(let text):
            let itemID = "\(message.id)-text-\(blockIndex)"
            guard !existingIDs.contains(itemID) else { return nil }
            if message.role == .user {
                return ChatHistoryItem(id: itemID, type: .user(text), timestamp: message.timestamp)
            }
            return ChatHistoryItem(id: itemID, type: .assistant(text), timestamp: message.timestamp)

        case .toolUse(let tool):
            guard toolTracker.markSeen(tool.id) else { return nil }

            let isCompleted = completedTools.contains(tool.id)
            let status: ToolStatus = isCompleted ? .success : .running

            var resultText: String?
            if isCompleted, let parserResult = toolResults[tool.id] {
                if let stdout = parserResult.stdout, !stdout.isEmpty {
                    resultText = stdout
                } else if let stderr = parserResult.stderr, !stderr.isEmpty {
                    resultText = stderr
                } else if let content = parserResult.content, !content.isEmpty {
                    resultText = content
                }
            }

            return ChatHistoryItem(
                id: tool.id,
                type: .toolCall(
                    ToolCallItem(
                        name: tool.name,
                        input: tool.input,
                        status: status,
                        result: resultText,
                        structuredResult: structuredResults[tool.id],
                        subagentTools: []
                    )
                ),
                timestamp: message.timestamp
            )

        case .thinking(let text):
            let itemID = "\(message.id)-thinking-\(blockIndex)"
            guard !existingIDs.contains(itemID) else { return nil }
            return ChatHistoryItem(id: itemID, type: .thinking(text), timestamp: message.timestamp)

        case .interrupted:
            let itemID = "\(message.id)-interrupted-\(blockIndex)"
            guard !existingIDs.contains(itemID) else { return nil }
            return ChatHistoryItem(id: itemID, type: .interrupted, timestamp: message.timestamp)
        }
    }

    static func populateSubagentArtifacts(
        chatItems: inout [ChatHistoryItem],
        subagentState: inout SubagentState,
        cwd: String,
        structuredResults: [String: ToolResultData]
    ) {
        for index in 0..<chatItems.count {
            guard case .toolCall(var tool) = chatItems[index].type,
                  tool.name == "Task",
                  let structuredResult = structuredResults[chatItems[index].id],
                  case .task(let taskResult) = structuredResult,
                  !taskResult.agentId.isEmpty else {
                continue
            }

            if let description = tool.input["description"] {
                subagentState.agentDescriptions[taskResult.agentId] = description
            }

            let subagentToolInfos = ConversationParser.parseSubagentToolsSync(
                agentId: taskResult.agentId,
                cwd: cwd
            )
            tool.subagentTools = subagentToolInfos.map { info in
                SubagentToolCall(
                    id: info.id,
                    name: info.name,
                    input: info.input,
                    status: info.isCompleted ? .success : .running,
                    timestamp: parseTimestamp(info.timestamp) ?? Date()
                )
            }

            chatItems[index] = ChatHistoryItem(
                id: chatItems[index].id,
                type: .toolCall(tool),
                timestamp: chatItems[index].timestamp
            )
        }
    }

    static func defaultCapabilities(
        for adapterID: RuntimeAdapterID
    ) -> [CanonicalSemanticArea: AdapterCapabilitySnapshot] {
        let supportedAreas: [CanonicalSemanticArea] = [
            .conversationLifecycle,
            .messageFinal,
            .toolLifecycle,
            .approvalRequest,
            .userChoiceRequest,
            .sessionFocus,
            .sessionArchive
        ]

        return Dictionary(
            uniqueKeysWithValues: supportedAreas.map { area in
                (
                    area,
                    AdapterCapabilitySnapshot(
                        adapterID: adapterID,
                        semanticArea: area,
                        level: .desktopFallback,
                        source: .localState,
                        control: .localFallback,
                        notes: "Phase 1 bootstrap compatibility capability"
                    )
                )
            }
        )
    }

    private static func buildProjectedMessages(from chatItems: [ChatHistoryItem]) -> [ProjectedMessageState] {
        chatItems.compactMap { item -> ProjectedMessageState? in
            switch item.type {
            case .user(let text):
                return ProjectedMessageState(
                    id: item.id,
                    turnID: nil,
                    role: .user,
                    format: .markdown,
                    text: text,
                    isFinal: true,
                    sourceKind: .transcript,
                    updatedAt: item.timestamp
                )
            case .assistant(let text):
                return ProjectedMessageState(
                    id: item.id,
                    turnID: nil,
                    role: .assistant,
                    format: .markdown,
                    text: text,
                    isFinal: true,
                    sourceKind: .transcript,
                    updatedAt: item.timestamp
                )
            case .thinking(let text):
                return ProjectedMessageState(
                    id: item.id,
                    turnID: nil,
                    role: .assistant,
                    format: .text,
                    text: text,
                    isFinal: false,
                    sourceKind: .transcript,
                    updatedAt: item.timestamp
                )
            case .interrupted, .toolCall:
                return nil
            }
        }
    }

    private static func buildProjectedTools(from chatItems: [ChatHistoryItem]) -> [ProjectedToolState] {
        chatItems.compactMap { item -> ProjectedToolState? in
            guard case .toolCall(let tool) = item.type else { return nil }
            return ProjectedToolState(
                id: item.id,
                name: tool.name,
                kind: canonicalToolKind(for: tool.name),
                input: tool.input.mapValues(AnyCodable.init),
                output: projectedToolOutput(from: tool),
                state: projectedToolState(for: tool.status),
                errorKind: tool.status == .error ? .runtimeError : nil,
                updatedAt: item.timestamp
            )
        }
    }

    private static func buildPermissionContext(from conversation: ProjectedConversationState) -> PermissionContext? {
        guard let approval = conversation.approvals.first(where: { $0.domainState == .requested }) else {
            return nil
        }

        let toolInput = conversation.tools.first(where: { $0.id == approval.toolID })?.input
        return PermissionContext(
            toolUseId: approval.toolID ?? approval.id,
            toolName: conversation.tools.first(where: { $0.id == approval.toolID })?.name ?? "unknown",
            toolInput: toolInput,
            receivedAt: approval.updatedAt
        )
    }

    private static func buildApprovalState(from metadata: ProjectionRuntimeMetadata) -> ProjectedApprovalState? {
        guard case .waitingForApproval(let permission) = metadata.phase else {
            return nil
        }

        return ProjectedApprovalState(
            id: permission.toolUseId,
            toolID: permission.toolUseId,
            kind: .tool,
            reason: "Permission required",
            options: [.allowOnce, .deny, .cancel],
            scope: .once,
            strength: .strong,
            domainState: .requested,
            submissionState: .idle,
            resolvedBy: nil,
            updatedAt: permission.receivedAt
        )
    }

    private static func buildChoiceState(from metadata: ProjectionRuntimeMetadata) -> ProjectedChoiceState? {
        guard metadata.phase == .waitingForInput else { return nil }

        let interaction = metadata.activeInteraction
        return ProjectedChoiceState(
            id: interaction?.toolUseId ?? "\(metadata.sessionID)-interaction",
            toolID: interaction?.toolUseId,
            kind: .options,
            prompt: interaction?.question,
            schema: [:],
            options: interaction?.options.map { AnyCodable($0.label) } ?? [],
            domainState: .requested,
            submissionState: .idle,
            submittedBy: nil,
            resolvedBy: nil,
            valueShape: .options,
            updatedAt: metadata.lastActivity
        )
    }

    private static func buildActiveInteraction(
        metadata: ProjectionRuntimeMetadata,
        from conversation: ProjectedConversationState,
        permissionContext: PermissionContext?,
        sessionID: String,
        agentID: String,
        isInTmux: Bool,
        tty: String?
    ) -> SessionInteractionRequest? {
        let submitMode = SessionInteractionRequest.submitMode(isInTmux: isInTmux, tty: tty)

        if let permissionContext {
            return SessionInteractionRequest.from(
                permission: permissionContext,
                sessionId: sessionID,
                agentId: agentID,
                submitMode: submitMode
            )
        }

        guard let choice = conversation.choices.first(where: {
            $0.domainState == .requested || $0.submissionState == .submissionPending
        }) else {
            return nil
        }

        if let activeInteraction = metadata.activeInteraction {
            return activeInteraction
        }

        let options = choice.options.compactMap { any -> QuestionOption? in
            guard let label = any.value as? String else { return nil }
            return QuestionOption(label: label, description: nil)
        }

        let result = AskUserQuestionResult(
            questions: [
                QuestionItem(
                    id: choice.id,
                    question: choice.prompt ?? "Choose an option",
                    header: "Choose",
                    options: options
                )
            ],
            answers: [:]
        )

        return SessionInteractionRequest.from(
            askUserQuestionResult: result,
            sessionId: sessionID,
            toolUseId: choice.toolID ?? choice.id,
            createdAt: choice.updatedAt,
            agentId: agentID,
            submitMode: submitMode
        )
    }

    private static func appendCompatibilityInteractionItems(
        interaction: SessionInteractionRequest,
        permissionContext: PermissionContext?,
        sessionID: String,
        into chatItems: inout [ChatHistoryItem]
    ) {
        let syntheticPrefix = "live-interaction-\(sessionID)-"
        let detailItemID = "\(syntheticPrefix)\(interaction.id)"
        let detailItem = ChatHistoryItem(
            id: detailItemID,
            type: .assistant(formattedInteractionSummary(interaction)),
            timestamp: interaction.createdAt
        )

        chatItems.removeAll { $0.id.hasPrefix(syntheticPrefix) }
        chatItems.append(detailItem)

        guard let toolUseID = interaction.toolUseId else { return }
        if let index = chatItems.firstIndex(where: { $0.id == toolUseID }),
           case .toolCall(var tool) = chatItems[index].type {
            let enrichedInput = enrichedInteractionInput(for: interaction)
            let mergedInput = tool.input.merging(enrichedInput) { _, new in new }
            if permissionContext?.toolUseId == toolUseID {
                tool.status = .waitingForApproval
            }
            chatItems[index] = ChatHistoryItem(
                id: toolUseID,
                type: .toolCall(
                    ToolCallItem(
                        name: tool.name,
                        input: mergedInput,
                        status: tool.status,
                        result: tool.result,
                        structuredResult: tool.structuredResult,
                        resolvedFromToolUseId: tool.resolvedFromToolUseId,
                        subagentTools: tool.subagentTools
                    )
                ),
                timestamp: chatItems[index].timestamp
            )
        }
    }

    private static func formattedInteractionSummary(_ interaction: SessionInteractionRequest) -> String {
        var lines: [String] = []
        for question in interaction.questions {
            if let header = question.header, !header.isEmpty {
                lines.append(header)
            }
            lines.append(question.question)
            for option in question.options {
                if let detail = option.detail, !detail.isEmpty {
                    lines.append("- \(option.label): \(detail)")
                } else {
                    lines.append("- \(option.label)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func enrichedInteractionInput(for interaction: SessionInteractionRequest) -> [String: String] {
        var input: [String: String] = [:]
        input["interaction_question"] = interaction.question
        input["interaction_title"] = interaction.title
        input["source_agent"] = interaction.sourceAgent
        if let sourceToolInputJSON = interaction.sourceToolInputJSON {
            input["source_tool_input_json"] = sourceToolInputJSON
        }
        return input
    }

    private static func projectedConversationStatus(from phase: SessionPhase) -> CanonicalConversationStatus {
        switch phase {
        case .processing, .compacting, .waitingForApproval, .waitingForInput:
            return .active
        case .ended:
            return .completed
        case .idle:
            return .idle
        }
    }

    private static func projectedTurnStatus(from phase: SessionPhase) -> CanonicalTurnStatus {
        switch phase {
        case .processing, .compacting, .waitingForApproval, .waitingForInput:
            return .inProgress
        case .ended:
            return .completed
        case .idle:
            return .unknown
        }
    }

    private static func projectedToolState(for status: ToolStatus) -> ProjectedToolLifecycleState {
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

    private static func projectedToolOutput(from tool: ToolCallItem) -> [String: AnyCodable] {
        var output: [String: AnyCodable] = [:]
        if let result = tool.result {
            output["text"] = AnyCodable(result)
        }
        return output
    }

    private static func canonicalToolKind(for name: String) -> CanonicalToolKind {
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

    private static func parseTimestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        return CanonicalTimestampCoding.date(from: value)
    }

    private static func fallbackChatItems(from conversation: ProjectedConversationState) -> [ChatHistoryItem] {
        let messageItems = conversation.messages.map { message -> ChatHistoryItem in
            let type: ChatHistoryItemType
            switch message.role {
            case .user:
                type = .user(message.text)
            case .assistant, .system, .tool:
                type = .assistant(message.text)
            }
            return ChatHistoryItem(id: message.id, type: type, timestamp: message.updatedAt)
        }

        let toolItems = conversation.tools.map { tool -> ChatHistoryItem in
            let status: ToolStatus
            switch tool.state {
            case .started, .running:
                status = .running
            case .completed:
                status = .success
            case .failed, .declined:
                status = .error
            case .cancelled, .timedOut:
                status = .interrupted
            }
            let result = tool.output["text"]?.value as? String
            return ChatHistoryItem(
                id: tool.id,
                type: .toolCall(
                    ToolCallItem(
                        name: tool.name,
                        input: tool.input.compactMapValues { any in
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
                        },
                        status: status,
                        result: result,
                        structuredResult: nil,
                        subagentTools: []
                    )
                ),
                timestamp: tool.updatedAt
            )
        }

        return (messageItems + toolItems).sorted { $0.timestamp < $1.timestamp }
    }

    private static func fallbackConversationInfo(
        from conversation: ProjectedConversationState,
        cwd: String
    ) -> ConversationInfo {
        let sortedMessages = conversation.messages.sorted { $0.updatedAt < $1.updatedAt }
        let lastMessage = sortedMessages.last?.text ?? conversation.tools.sorted { $0.updatedAt < $1.updatedAt }.last?.name
        let lastMessageRole = sortedMessages.last?.role.rawValue
        let lastToolName = conversation.tools.sorted { $0.updatedAt < $1.updatedAt }.last?.name
        let firstUserMessage = sortedMessages.first(where: { $0.role == .user })?.text ?? URL(fileURLWithPath: cwd).lastPathComponent
        let lastUserMessage = sortedMessages.last(where: { $0.role == .user })?.text
        let lastUserMessageDate = sortedMessages.last(where: { $0.role == .user })?.updatedAt

        return ConversationInfo(
            summary: conversation.title,
            lastMessage: lastMessage,
            lastMessageRole: lastMessageRole,
            lastToolName: lastToolName,
            firstUserMessage: firstUserMessage,
            lastUserMessage: lastUserMessage,
            lastUserMessageDate: lastUserMessageDate
        )
    }
}

private extension Array {
    func asyncMap<T: Sendable>(
        _ transform: @Sendable (Element) async -> T
    ) async -> [T] {
        var values: [T] = []
        values.reserveCapacity(count)
        for element in self {
            values.append(await transform(element))
        }
        return values
    }
}

private extension ProjectionBootstrap {
    func buildActiveInteraction(
        from event: HookEvent,
        sessionID: String,
        isInTmux: Bool,
        tty: String?
    ) -> SessionInteractionRequest? {
        let submitMode = SessionInteractionRequest.submitMode(isInTmux: isInTmux, tty: tty)
        switch event.agentId {
        case "codex":
            guard event.event == HookEventType.preToolUse.rawValue,
                  event.tool == "request_user_input",
                  let toolUseID = event.toolUseId else {
                return nil
            }
            return SessionInteractionRequest.fromToolInputPayload(
                sessionId: sessionID,
                toolUseId: toolUseID,
                payload: event.toolInput ?? [:],
                timestamp: Date(),
                sourceAgent: event.agentId,
                submitMode: .programmatic,
                transportPreference: .programmaticOnly
            )
        case "claude":
            guard event.event == HookEventType.preToolUse.rawValue,
                  event.tool == "AskUserQuestion",
                  let toolUseID = event.toolUseId else {
                return nil
            }
            return SessionInteractionRequest.fromClaudeAskUserQuestion(
                sessionId: sessionID,
                toolUseId: toolUseID,
                payload: event.toolInput ?? [:],
                timestamp: Date(),
                sourceAgent: event.agentId,
                submitMode: .programmatic
            )
        case "gemini":
            guard event.event == HookEventType.preToolUse.rawValue,
                  event.tool == "ask_user",
                  let toolUseID = event.toolUseId else {
                return nil
            }
            let payload = (event.toolInput ?? [:]).reduce(into: [String: Any]()) { partialResult, item in
                partialResult[item.key] = item.value.value
            }
            return SessionInteractionRequest.fromJSONObjectPayload(
                sessionId: sessionID,
                toolUseId: toolUseID,
                payload: payload,
                timestamp: Date(),
                sourceAgent: event.agentId,
                submitMode: .programmatic,
                transportPreference: .programmaticOnly
            )
        default:
            if event.event == HookEventType.interactionRequest.rawValue {
                if let toolInput = event.toolInput {
                    return SessionInteractionRequest.fromToolInputPayload(
                        sessionId: sessionID,
                        toolUseId: event.toolUseId ?? "\(sessionID)-interaction",
                        payload: toolInput,
                        timestamp: Date(),
                        sourceAgent: event.agentId,
                        submitMode: submitMode
                    )
                }
                if let message = event.message {
                    return SessionInteractionRequest.fromHeuristicText(
                        sessionId: sessionID,
                        interactionId: event.toolUseId ?? "\(sessionID)-interaction",
                        sourceAgent: event.agentId,
                        text: message,
                        timestamp: Date(),
                        submitMode: submitMode
                    )
                }
            }
            return nil
        }
    }
}
