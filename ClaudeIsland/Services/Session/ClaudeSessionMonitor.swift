//
//  ClaudeSessionMonitor.swift
//  ClaudeIsland
//
//  Projection-backed session monitor for SwiftUI.
//

import AppKit
import Combine
import Foundation

struct ProjectedInteractionSubmitResult: Equatable, Sendable {
    let succeeded: Bool
    let confirmed: Bool
    let error: String?

    static func success(confirmed: Bool = true) -> ProjectedInteractionSubmitResult {
        ProjectedInteractionSubmitResult(succeeded: true, confirmed: confirmed, error: nil)
    }

    static func failure(_ error: String) -> ProjectedInteractionSubmitResult {
        ProjectedInteractionSubmitResult(succeeded: false, confirmed: false, error: error)
    }
}

@MainActor
class ClaudeSessionMonitor: ObservableObject {
    @Published var instances: [ProjectedSessionViewState] = []
    @Published var pendingInstances: [ProjectedSessionViewState] = []
    @Published var hydratedSessionIDs: Set<String> = []
    @Published var fixtureBootSessionID: String?
    @Published var isFixtureReady: Bool
    @Published var fixtureLoadError: String?
    @Published var interactionSubmitErrors: [String: String] = [:]
    @Published var submittingInteractionSessionIds: Set<String> = []

    private var observationTask: Task<Void, Never>?

    init() {
        isFixtureReady = !ProjectionLaunchMode.current.isFixture
        fixtureLoadError = nil
        startObservingProjection()
        InterruptWatcherManager.shared.delegate = self
    }

    deinit {
        observationTask?.cancel()
    }

    func startMonitoring() {
        if ProjectionLaunchMode.current.isFixture {
            Task {
                await ProjectionBootstrap.shared.start(mode: .current)
            }
        }
    }

    func stopMonitoring() {
        // AppDelegate owns live runtime shutdown; fixture bootstrap is process-scoped.
    }

    func approvePermission(sessionId: String) {
        Task {
            _ = await submitPermissionDecision(sessionId: sessionId, decisionId: "allow")
        }
    }

    func denyPermission(sessionId: String, reason: String?) {
        Task {
            _ = await submitPermissionDecision(sessionId: sessionId, decisionId: "deny", reason: reason)
        }
    }

    func bypassPermission(sessionId: String) {
        Task {
            _ = await submitPermissionDecision(sessionId: sessionId, decisionId: "always_allow")
        }
    }

    func archiveSession(sessionId: String) {
        Task {
            guard let session = sessionState(for: sessionId) else { return }
            _ = await RuntimeOrchestrator.shared.dispatch(
                CanonicalCommandEnvelope(
                    conversationID: session.sessionID,
                    target: CanonicalCommandTarget(
                        adapterID: session.adapterID,
                        entityType: .session,
                        entityID: session.sessionID
                    ),
                    type: .sessionArchive,
                    mode: .authoritative,
                    idempotencyKey: "session-archive:\(session.sessionID)",
                    payload: .sessionArchive(CanonicalSessionCommandPayload(reason: "ui_archive"))
                )
            )
        }
    }

    func submitInteraction(
        sessionId: String,
        option: ProjectedInteractionOptionState
    ) async -> ProjectedInteractionSubmitResult {
        await submitInteraction(
            sessionId: sessionId,
            selections: [ProjectedPromptSelection(questionID: "question-0", option: option)]
        )
    }

    func submitInteraction(
        sessionId: String,
        selections: [ProjectedPromptSelection]
    ) async -> ProjectedInteractionSubmitResult {
        submittingInteractionSessionIds.insert(sessionId)
        interactionSubmitErrors.removeValue(forKey: sessionId)
        defer {
            submittingInteractionSessionIds.remove(sessionId)
        }

        guard let session = sessionState(for: sessionId) else {
            let result = ProjectedInteractionSubmitResult.failure("Session not found")
            interactionSubmitErrors[sessionId] = result.error
            return result
        }

        guard let prompt = session.prompt, prompt.kind == .choice else {
            let result = ProjectedInteractionSubmitResult.failure("No pending interaction found")
            interactionSubmitErrors[sessionId] = result.error
            return result
        }

        guard let value = prompt.commandValue(for: selections) else {
            let result = ProjectedInteractionSubmitResult.failure("Failed to encode interaction response")
            interactionSubmitErrors[sessionId] = result.error
            return result
        }

        let valueShape: CanonicalChoiceValueShape = prompt.isMultiQuestion ? .form : .options
        let command = CanonicalCommandEnvelope(
            conversationID: session.sessionID,
            target: CanonicalCommandTarget(
                adapterID: session.adapterID,
                entityType: .choice,
                entityID: prompt.id
            ),
            type: .choiceSubmit,
            mode: .authoritative,
            idempotencyKey: "choice-submit:\(session.sessionID):\(prompt.id)",
            payload: .choiceSubmit(
                CanonicalChoiceSubmitCommandPayload(
                    submittedBy: .user,
                    valueShape: valueShape,
                    value: value.mapValues(AnyCodable.init)
                )
            )
        )

        let result = await RuntimeOrchestrator.shared.dispatch(command)
        guard result.status == .accepted else {
            let error = result.notes ?? "Interaction submission failed"
            interactionSubmitErrors[sessionId] = error
            return .failure(error)
        }

        return .success()
    }

    func clearInteractionSubmitError(sessionId: String) {
        interactionSubmitErrors.removeValue(forKey: sessionId)
    }

    func focusSession(sessionId: String) async -> Bool {
        guard let session = sessionState(for: sessionId) else {
            return false
        }

        let result = await RuntimeOrchestrator.shared.dispatch(
            CanonicalCommandEnvelope(
                conversationID: session.sessionID,
                target: CanonicalCommandTarget(
                    adapterID: session.adapterID,
                    entityType: .session,
                    entityID: session.sessionID
                ),
                type: .sessionFocus,
                mode: .authoritative,
                idempotencyKey: "session-focus:\(session.sessionID)",
                payload: .sessionFocus(CanonicalSessionCommandPayload(reason: "ui_focus"))
            )
        )

        return result.status == .accepted
    }

    func loadHistory(sessionId _: String, cwd _: String) {
        Task {
            await ProjectionBootstrap.shared.refresh()
        }
    }

    private func startObservingProjection() {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            guard let self else { return }
            let stream = await ProjectionBootstrap.shared.projectionStore.subscribe()
            for await snapshot in stream {
                if Task.isCancelled { break }
                let sessions = await ProjectionBootstrap.shared.uiSessions()
                let fixturePresentationState = await ProjectionBootstrap.shared.fixturePresentationState()
                await MainActor.run {
                    self.instances = sessions
                    self.pendingInstances = sessions.filter { $0.needsAttention }
                    self.hydratedSessionIDs = Set(snapshot.conversations.keys)
                    self.fixtureBootSessionID = fixturePresentationState?.bootSessionID
                    self.isFixtureReady = fixturePresentationState?.isReady ?? !ProjectionLaunchMode.current.isFixture
                    self.fixtureLoadError = fixturePresentationState?.errorMessage
                }
            }
        }
    }

    private func submitPermissionDecision(
        sessionId: String,
        decisionId: String,
        reason: String? = nil
    ) async -> ProjectedInteractionSubmitResult {
        guard let session = sessionState(for: sessionId),
              let prompt = session.prompt,
              prompt.kind == .approval else {
            return .failure("No pending permission found")
        }

        let decision: CanonicalApprovalDecision
        let scope: CanonicalDecisionScope
        switch decisionId {
        case "allow":
            decision = .allowOnce
            scope = .once
        case "always_allow":
            decision = .allowSession
            scope = .session
        case "deny":
            decision = .deny
            scope = .once
        case "cancel":
            decision = .cancel
            scope = .once
        default:
            return .failure("Unsupported permission decision")
        }

        let command = CanonicalCommandEnvelope(
            conversationID: session.sessionID,
            target: CanonicalCommandTarget(
                adapterID: session.adapterID,
                entityType: .approval,
                entityID: prompt.id
            ),
            type: .approvalResolve,
            mode: .authoritative,
            idempotencyKey: "approval-resolve:\(session.sessionID):\(prompt.id):\(decision.rawValue)",
            payload: .approvalResolve(
                CanonicalApprovalResolveCommandPayload(
                    decision: decision,
                    scope: scope,
                    reason: reason
                )
            )
        )

        let result = await RuntimeOrchestrator.shared.dispatch(command)
        guard result.status == .accepted else {
            let error = result.notes ?? "Permission submission failed"
            interactionSubmitErrors[sessionId] = error
            return .failure(error)
        }

        return .success()
    }

    private func focusSessionWindow(_ session: ProjectedSessionViewState) async -> Bool {
        if session.isInTmux {
            if let pid = session.pid,
               await YabaiController.shared.focusWindow(forClaudePid: pid) {
                return true
            }

            if await YabaiController.shared.focusWindow(forWorkingDirectory: session.cwd) {
                return true
            }
        }

        guard let pid = session.pid else { return false }

        let tree = ProcessTreeBuilder.shared.buildTree()
        guard let hostApp = HostApplicationResolver.shared.resolveHostApplication(forProcess: pid, tree: tree),
              let app = NSRunningApplication(processIdentifier: pid_t(hostApp.activationPID)) else {
            return false
        }

        return app.activate(options: [.activateAllWindows])
    }

    private func sessionState(for sessionId: String) -> ProjectedSessionViewState? {
        instances.first(where: { $0.sessionID == sessionId })
    }
}

extension ClaudeSessionMonitor: JSONLInterruptWatcherDelegate {
    nonisolated func didDetectInterrupt(sessionId: String) {
        Task {
            await ProjectionBootstrap.shared.handleInterruptDetected(sessionID: sessionId)
            await ProjectionBootstrap.shared.refresh()
        }

        Task { @MainActor in
            InterruptWatcherManager.shared.stopWatching(sessionId: sessionId)
        }
    }
}
