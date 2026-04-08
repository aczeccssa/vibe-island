//
//  AIAgentProtocol.swift
//  ClaudeIsland
//
//  Phase 2 runtime protocol split.
//

import AppKit
import Foundation
import os.log

enum AgentEventSourceMode: String, Sendable {
    case hook
    case hybrid
    case processOnly
}

enum HookEventType: String, Sendable, CaseIterable {
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case permissionRequest = "PermissionRequest"
    case notification = "Notification"
    case stop = "Stop"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"
    case sessionStart = "SessionStart"
    case sessionEnd = "SessionEnd"
    case preCompact = "PreCompact"
    case interactionRequest = "InteractionRequest"
    case interactionResolved = "InteractionResolved"
}

struct RuntimeAdapterDescriptor: Equatable, Sendable {
    let adapterID: RuntimeAdapterID
    let familyID: RuntimeFamilyID
    let legacyAgentID: String?
    let displayName: String
    let shortDisplayName: String
    let priority: Int
    let supportsHooks: Bool
    let supportedEvents: Set<HookEventType>
    let eventSourceMode: AgentEventSourceMode
}

enum RuntimeIngressMode: String, Sendable {
    case attached
    case ambient
}

enum RuntimeInteractionKind: String, Sendable {
    case approval
    case choice
}

struct RuntimeDiscoveredSession: Equatable, Sendable {
    let adapterID: RuntimeAdapterID
    let legacyAgentID: String
    let sessionID: String
    let cwd: String
    let pid: Int?
    let tty: String?
}

struct RuntimeTrackedSession: Equatable, Sendable {
    let sessionID: String
    let pid: Int?
}

struct RuntimeManagedInteraction: Equatable, Sendable {
    let kind: RuntimeInteractionKind
    let adapterID: RuntimeAdapterID
    let conversationID: String
    let interactionID: String
    let observedAt: Date
    let reason: String?
}

protocol RuntimeObservationPlane: Sendable {
    var adapterID: RuntimeAdapterID { get }
    func supports(hookEvent: HookEvent) -> Bool
}

protocol RuntimeRecoveryPlane: Sendable {
    var adapterID: RuntimeAdapterID { get }
    func refreshProjectionState() async
}

protocol RuntimeControlPlane: Sendable {
    var adapterID: RuntimeAdapterID { get }
    func registerCommands(on router: CommandRouter) async
}

protocol RuntimeCapabilityPlane: Sendable {
    var adapterID: RuntimeAdapterID { get }
    func capabilitySnapshot(for mode: RuntimeIngressMode) -> [CanonicalSemanticArea: AdapterCapabilitySnapshot]
    func timeoutOverride(for kind: RuntimeInteractionKind) -> TimeInterval?
}

protocol RuntimeSessionDiscoveryPlane: Sendable {
    var adapterID: RuntimeAdapterID { get }
    func discoverSessions() async -> [RuntimeDiscoveredSession]
}

protocol RuntimeSemanticPlane: Sendable {
    var adapterID: RuntimeAdapterID { get }
    func managedInteractionKind(for hookEvent: HookEvent) -> RuntimeInteractionKind?
    func promptState(from hookEvent: HookEvent, sessionID: String, createdAt: Date) -> ProjectedPromptState?
    func shouldStartInterruptWatcher(for hookEvent: HookEvent) -> Bool
    func agentDescription(
        name: String,
        input: [String: String],
        structuredResult: ToolResultData?
    ) -> (agentID: String, description: String)?
    func toolHeaderDetail(
        name: String,
        input: [String: String],
        structuredResult: ToolResultData?,
        agentDescriptions: [String: String]
    ) -> String?
    func toolPendingDetails(
        name: String,
        input: [String: String],
        status: ToolStatus
    ) -> String?
}

extension RuntimeSemanticPlane {
    func managedInteractionKind(for _: HookEvent) -> RuntimeInteractionKind? { nil }
    func promptState(from _: HookEvent, sessionID _: String, createdAt _: Date) -> ProjectedPromptState? { nil }
    func shouldStartInterruptWatcher(for _: HookEvent) -> Bool { false }
    func agentDescription(
        name _: String,
        input _: [String: String],
        structuredResult _: ToolResultData?
    ) -> (agentID: String, description: String)? {
        nil
    }
    func toolHeaderDetail(
        name _: String,
        input _: [String: String],
        structuredResult _: ToolResultData?,
        agentDescriptions _: [String: String]
    ) -> String? {
        nil
    }
    func toolPendingDetails(
        name _: String,
        input _: [String: String],
        status _: ToolStatus
    ) -> String? {
        nil
    }
}

struct RuntimeAdapterPlanes: Sendable {
    let observation: any RuntimeObservationPlane
    let recovery: any RuntimeRecoveryPlane
    let control: any RuntimeControlPlane
    let capability: any RuntimeCapabilityPlane
    let semantic: any RuntimeSemanticPlane
    let sessionDiscovery: (any RuntimeSessionDiscoveryPlane)?
}

protocol RuntimeAdapter: Sendable {
    var descriptor: RuntimeAdapterDescriptor { get }
    func makePlanes() -> RuntimeAdapterPlanes
}

protocol HookInstallableAgent: Sendable {
    var id: String { get }
    var hookSettingsPath: String { get }
    var hookScriptInstallName: String? { get }
    var hookCommandPath: String? { get }
    var supportedEvents: Set<HookEventType> { get }
    var supportsHooks: Bool { get }
    func hookScriptResourceName() -> String
    func hookConfig() -> [[String: Any]]
    func areHooksInstalled() -> Bool
    func installHooks() throws
    func uninstallHooks() throws
    func postInstallHooks() throws
    func postUninstallHooks() throws
}

enum HookPythonLocator {
    private static let logger = Logger(subsystem: "com.claudeisland", category: "HookPython")

    static func detectPython() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["python3"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return "python3"
            }
            logger.notice("python3 not found via /usr/bin/which, falling back to python")
        } catch {
            logger.error("Failed to probe python3 via /usr/bin/which: \(error.localizedDescription, privacy: .public)")
        }

        return "python"
    }
}

private enum HookInstallSupport {
    static func settingsDirectory(for path: String) -> String {
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        var directoryPath = expandedPath(path)
        if directoryPath.hasSuffix("/\(fileName)") {
            directoryPath = String(directoryPath.dropLast(fileName.count + 1))
        }
        return directoryPath
    }

    static func expandedPath(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    static func expandedSettingsURL(for agent: any HookInstallableAgent) -> URL {
        URL(fileURLWithPath: expandedPath(agent.hookSettingsPath))
    }

    static func hookScriptsDirectory(for agent: any HookInstallableAgent) -> URL {
        let hooksDirectory = expandedPath(settingsDirectory(for: agent.hookSettingsPath))
        return URL(fileURLWithPath: hooksDirectory).appendingPathComponent("hooks")
    }

    static func managedCommandMarkers(for agent: any HookInstallableAgent) -> [String] {
        var markers: [String] = []
        if let installName = agent.hookScriptInstallName {
            markers.append(installName)
        }
        markers.append("vibe-island-\(agent.id).py")
        return markers
    }

    static func isManagedCommand(_ command: String, for agent: any HookInstallableAgent) -> Bool {
        if command.contains("vibe-island-bridge"), command.contains("--source \(agent.id)") {
            return true
        }

        return managedCommandMarkers(for: agent).contains { marker in
            command.contains(marker)
        }
    }

    static func stripManagedHooks(from hooks: [String: Any], agent: any HookInstallableAgent) -> [String: Any] {
        var cleanedHooks: [String: Any] = [:]

        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else {
                cleanedHooks[event] = value
                continue
            }

            let cleanedEntries = entries.compactMap { entry -> [String: Any]? in
                guard let entryHooks = entry["hooks"] as? [[String: Any]] else {
                    return entry
                }

                let remainingHooks = entryHooks.filter { hook in
                    let command = hook["command"] as? String ?? ""
                    return !isManagedCommand(command, for: agent)
                }

                guard !remainingHooks.isEmpty else { return nil }

                var updatedEntry = entry
                updatedEntry["hooks"] = remainingHooks
                return updatedEntry
            }

            if !cleanedEntries.isEmpty {
                cleanedHooks[event] = cleanedEntries
            }
        }

        return cleanedHooks
    }

    static func containsManagedHook(in entries: [[String: Any]], agent: any HookInstallableAgent) -> Bool {
        entries.contains { entry in
            guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return false }
            return entryHooks.contains { hook in
                let command = hook["command"] as? String ?? ""
                return isManagedCommand(command, for: agent)
            }
        }
    }

    static func writeHookScriptIfNeeded(for agent: any HookInstallableAgent) throws {
        guard let installName = agent.hookScriptInstallName,
              !agent.hookScriptResourceName().isEmpty else {
            return
        }

        let hooksDirectory = hookScriptsDirectory(for: agent)
        try FileManager.default.createDirectory(at: hooksDirectory, withIntermediateDirectories: true)

        let destination = hooksDirectory.appendingPathComponent(installName)
        if let bundled = Bundle.main.url(forResource: agent.hookScriptResourceName(), withExtension: "py") {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: bundled, to: destination)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: destination.path
            )
        }
    }

    static func install(_ agent: any HookInstallableAgent) throws {
        try writeHookScriptIfNeeded(for: agent)

        let settingsURL = expandedSettingsURL(for: agent)
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        var hooks = json["hooks"] as? [String: Any] ?? [:]
        hooks = stripManagedHooks(from: hooks, agent: agent)

        for config in agent.hookConfig() {
            guard let event = config["event"] as? String,
                  let hookArray = config["config"] as? [[String: Any]] else {
                continue
            }

            var entries = hooks[event] as? [[String: Any]] ?? []
            entries.append(contentsOf: hookArray)
            hooks[event] = entries
        }

        json["hooks"] = hooks

        let data = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: settingsURL)
    }

    static func uninstall(_ agent: any HookInstallableAgent) throws {
        if let installName = agent.hookScriptInstallName {
            let scriptURL = hookScriptsDirectory(for: agent).appendingPathComponent(installName)
            try? FileManager.default.removeItem(at: scriptURL)
        }

        let settingsURL = expandedSettingsURL(for: agent)
        guard let data = try? Data(contentsOf: settingsURL),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return
        }

        let cleanedHooks = stripManagedHooks(from: hooks, agent: agent)
        if cleanedHooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = cleanedHooks
        }

        let updatedData = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )
        try updatedData.write(to: settingsURL)
    }

    static func areInstalled(_ agent: any HookInstallableAgent) -> Bool {
        guard agent.supportsHooks else { return false }

        let settingsURL = expandedSettingsURL(for: agent)
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }

        for event in agent.supportedEvents {
            guard let entries = hooks[event.rawValue] as? [[String: Any]],
                  containsManagedHook(in: entries, agent: agent) else {
                return false
            }
        }

        return true
    }
}

extension HookInstallableAgent {
    func hookScriptResourceName() -> String { "" }

    var hookScriptInstallName: String? {
        let resourceName = hookScriptResourceName()
        return resourceName.isEmpty ? nil : "vibe-island-\(id).py"
    }

    var hookCommandPath: String? {
        guard let installName = hookScriptInstallName else { return nil }
        let python = HookPythonLocator.detectPython()
        let hooksDirectory = HookInstallSupport.settingsDirectory(for: hookSettingsPath)
        return "\(python) \(hooksDirectory)/hooks/\(installName)"
    }

    func hookConfig() -> [[String: Any]] { [] }
    func postInstallHooks() throws {}
    func postUninstallHooks() throws {}

    func installedHookEvents() -> Set<HookEventType> {
        Set(hookConfig().compactMap { entry in
            guard let eventName = entry["event"] as? String else { return nil }
            return HookEventType(rawValue: eventName)
        })
    }

    func validateHookContract() throws {
        guard supportsHooks else { return }

        let declaredEvents = supportedEvents
        let installedEvents = installedHookEvents()
        guard declaredEvents == installedEvents else {
            let missingInstall = declaredEvents.subtracting(installedEvents).map(\.rawValue).sorted()
            let missingDeclare = installedEvents.subtracting(declaredEvents).map(\.rawValue).sorted()
            let details = [
                missingInstall.isEmpty ? nil : "declaredOnly=\(missingInstall.joined(separator: ","))",
                missingDeclare.isEmpty ? nil : "installedOnly=\(missingDeclare.joined(separator: ","))"
            ]
            .compactMap { $0 }
            .joined(separator: " ")

            throw AgentError.hookInstallationFailed(
                "Hook contract mismatch for \(id): \(details)"
            )
        }
    }

    func areHooksInstalled() -> Bool {
        HookInstallSupport.areInstalled(self)
    }

    func installHooks() throws {
        try validateHookContract()
        try HookInstallSupport.install(self)
        try postInstallHooks()
    }

    func uninstallHooks() throws {
        try HookInstallSupport.uninstall(self)
        try postUninstallHooks()
    }
}

private struct RuntimeNoopRecoveryPlane: RuntimeRecoveryPlane {
    let adapterID: RuntimeAdapterID

    func refreshProjectionState() async {
        await ProjectionBootstrap.shared.refresh()
    }
}

private struct RuntimeProjectionControlPlane: RuntimeControlPlane {
    let adapterID: RuntimeAdapterID
    let supportsInteractivePrompts: Bool

    func registerCommands(on router: CommandRouter) async {
        await router.registerHandler(for: adapterID) { command in
            await RuntimeCommandExecutor.execute(
                command,
                adapterID: adapterID,
                supportsInteractivePrompts: supportsInteractivePrompts
            )
        }
    }
}

private enum RuntimeCommandExecutor {
    private static let logger = Logger(subsystem: "com.claudeisland", category: "RuntimeCommandExecutor")

    private enum RuntimeTerminalAction {
        case interrupt
        case clear

        var ttyPayload: Data {
            switch self {
            case .interrupt:
                return Data([0x03])
            case .clear:
                return Data([0x0C])
            }
        }

        var tmuxAcceptedNotes: String {
            switch self {
            case .interrupt:
                return "Interrupt signal sent via tmux."
            case .clear:
                return "Clear-surface command sent via tmux."
            }
        }

        var ttyAcceptedNotes: String {
            switch self {
            case .interrupt:
                return "Interrupt signal sent via tty."
            case .clear:
                return "Clear-surface control sequence sent via tty."
            }
        }
    }

    static func execute(
        _ command: CanonicalCommandEnvelope,
        adapterID: RuntimeAdapterID,
        supportsInteractivePrompts: Bool
    ) async -> CanonicalCommandDispatchResult {
        switch command.payload {
        case .approvalResolve(let payload):
            guard supportsInteractivePrompts else {
                return unsupported(command, notes: "Approval commands are unsupported for \(adapterID.rawValue).")
            }
            return await resolveApproval(command, payload: payload)
        case .choiceSubmit(let payload):
            guard supportsInteractivePrompts else {
                return unsupported(command, notes: "Choice commands are unsupported for \(adapterID.rawValue).")
            }
            return await submitChoice(command, payload: payload)
        case .sessionFocus:
            return await focusSession(command)
        case .sessionArchive:
            return await archiveSession(command)
        case .sessionInterrupt:
            return await interruptSession(command)
        case .sessionClear(let payload):
            return await clearSession(command, payload: payload)
        }
    }

    private static func resolveApproval(
        _ command: CanonicalCommandEnvelope,
        payload: CanonicalApprovalResolveCommandPayload
    ) async -> CanonicalCommandDispatchResult {
        guard let session = await ProjectionBootstrap.shared.uiSession(id: command.conversationID),
              let prompt = session.prompt,
              prompt.kind == .approval,
              prompt.id == command.target.entityID,
              let toolUseID = prompt.toolUseID else {
            return rejected(command, notes: "No matching approval prompt is active for this session.")
        }

        let decision: String
        switch payload.decision {
        case .allowOnce:
            decision = "allow"
        case .allowSession:
            decision = "always_allow"
        case .deny, .cancel:
            decision = "deny"
        case .unknown:
            return rejected(command, notes: "Approval decision is unknown.")
        }

        let didSendResponse = await HookSocketServer.shared.respondToPermission(
            toolUseId: toolUseID,
            decision: decision,
            reason: payload.reason
        )

        guard didSendResponse else {
            return rejected(command, notes: "No pending approval socket matched this request.")
        }

        return accepted(command, notes: "Approval response sent via hook socket.")
    }

    private static func submitChoice(
        _ command: CanonicalCommandEnvelope,
        payload: CanonicalChoiceSubmitCommandPayload
    ) async -> CanonicalCommandDispatchResult {
        guard let session = await ProjectionBootstrap.shared.uiSession(id: command.conversationID),
              let prompt = session.prompt,
              prompt.kind == .choice,
              prompt.id == command.target.entityID,
              let toolUseID = prompt.toolUseID else {
            return rejected(command, notes: "No matching interaction prompt is active for this session.")
        }

        switch prompt.responseCapability {
        case .nativeHookAvailable:
            break
        case .keyboardFallbackAvailable, .directTextAvailable, .detectOnly:
            return unsupported(command, notes: "Only native hook-backed interaction submission is supported in the canonical path.")
        }

        let updatedInput = payload.value.mapValues(\.value)
        let writeResult = await HookSocketServer.shared.respondToInteraction(
            toolUseId: toolUseID,
            updatedInput: updatedInput
        )

        switch writeResult {
        case .success:
            return accepted(command, notes: "Interaction response sent via hook socket.")
        case .missingPendingInteraction:
            return rejected(command, notes: writeResult.errorDescription ?? "No pending interaction matched this tool_use_id.")
        case .encodingFailed, .writeFailed:
            return rejected(command, notes: writeResult.errorDescription ?? "Failed to submit interaction response.")
        }
    }

    private static func focusSession(_ command: CanonicalCommandEnvelope) async -> CanonicalCommandDispatchResult {
        guard let session = await ProjectionBootstrap.shared.uiSession(id: command.conversationID) else {
            return rejected(command, notes: "No projected session context is available for focus.")
        }

        let didFocus: Bool
        if session.isInTmux {
            if let pid = session.pid,
               await YabaiController.shared.focusWindow(forClaudePid: pid) {
                didFocus = true
            } else if await YabaiController.shared.focusWindow(forWorkingDirectory: session.cwd) {
                didFocus = true
            } else {
                didFocus = activateHostApp(for: session)
            }
        } else {
            didFocus = activateHostApp(for: session)
        }

        guard didFocus else {
            return rejected(command, notes: "Failed to focus the host application.")
        }

        return accepted(command, notes: "Focused host application.")
    }

    private static func archiveSession(_ command: CanonicalCommandEnvelope) async -> CanonicalCommandDispatchResult {
        await ProjectionBootstrap.shared.archiveSession(command.conversationID)
        return accepted(command, notes: "Archived projected session.")
    }

    private static func interruptSession(_ command: CanonicalCommandEnvelope) async -> CanonicalCommandDispatchResult {
        guard let session = await ProjectionBootstrap.shared.uiSession(id: command.conversationID) else {
            return rejected(command, notes: "No projected session context is available for interrupt.")
        }

        guard let notes = await performTerminalAction(.interrupt, for: session) else {
            return rejected(command, notes: "No runtime terminal control path is available for interrupt.")
        }

        return accepted(command, notes: notes)
    }

    private static func clearSession(
        _ command: CanonicalCommandEnvelope,
        payload: CanonicalSessionClearCommandPayload
    ) async -> CanonicalCommandDispatchResult {
        guard let session = await ProjectionBootstrap.shared.uiSession(id: command.conversationID) else {
            return rejected(command, notes: "No projected session context is available for clear.")
        }

        if let notes = await performTerminalAction(.clear, for: session) {
            await ProjectionBootstrap.shared.clearSessionSurface(command.conversationID)
            return accepted(command, notes: "\(notes) Projected session surface reset.")
        }

        guard payload.allowProjectionFallback else {
            return rejected(
                command,
                notes: "No runtime clear path is available. Retry only with explicit projection fallback enabled."
            )
        }

        await ProjectionBootstrap.shared.clearSessionSurface(command.conversationID)
        return accepted(command, notes: "Cleared projected session surface via explicit projection fallback.")
    }

    private static func performTerminalAction(
        _ action: RuntimeTerminalAction,
        for session: ProjectedSessionViewState
    ) async -> String? {
        if session.isInTmux,
           let target = await resolveTmuxTarget(for: session) {
            let succeeded: Bool
            switch action {
            case .interrupt:
                succeeded = await TmuxController.shared.interrupt(target: target)
            case .clear:
                succeeded = await TmuxController.shared.clearSurface(target: target)
            }

            if succeeded {
                return action.tmuxAcceptedNotes
            }

            logger.error(
                "Tmux terminal action failed for session \(session.sessionID, privacy: .public) action=\(String(describing: action), privacy: .public)"
            )
        } else if session.isInTmux {
            logger.error("No tmux target resolved for session \(session.sessionID, privacy: .public)")
        }

        if await writeTTYPayload(action.ttyPayload, tty: session.tty) {
            return action.ttyAcceptedNotes
        }

        logger.error("No terminal control path succeeded for session \(session.sessionID, privacy: .public)")
        return nil
    }

    private static func resolveTmuxTarget(for session: ProjectedSessionViewState) async -> TmuxTarget? {
        if let pid = session.pid,
           let target = await TmuxController.shared.findTmuxTarget(forClaudePid: pid) {
            return target
        }

        return await TmuxController.shared.findTmuxTarget(forWorkingDirectory: session.cwd)
    }

    private static func writeTTYPayload(_ payload: Data, tty: String?) async -> Bool {
        guard let tty else {
            logger.error("TTY write skipped because the projected session has no tty.")
            return false
        }

        let ttyPath = tty.hasPrefix("/") ? tty : "/dev/\(tty)"
        guard FileManager.default.fileExists(atPath: ttyPath) else {
            logger.error("TTY path does not exist: \(ttyPath, privacy: .public)")
            return false
        }

        do {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: ttyPath))
            defer { try? handle.close() }
            try handle.write(contentsOf: payload)
            return true
        } catch {
            logger.error("Failed to write tty payload to \(ttyPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func activateHostApp(for session: ProjectedSessionViewState) -> Bool {
        guard let pid = session.pid else { return false }

        let tree = ProcessTreeBuilder.shared.buildTree()
        guard let hostApp = HostApplicationResolver.shared.resolveHostApplication(forProcess: pid, tree: tree),
              let app = NSRunningApplication(processIdentifier: pid_t(hostApp.activationPID)) else {
            return false
        }

        return app.activate(options: [.activateAllWindows])
    }

    private static func accepted(
        _ command: CanonicalCommandEnvelope,
        notes: String
    ) -> CanonicalCommandDispatchResult {
        CanonicalCommandDispatchResult(
            commandID: command.commandID,
            adapterID: command.target.adapterID,
            status: .accepted,
            notes: notes
        )
    }

    private static func rejected(
        _ command: CanonicalCommandEnvelope,
        notes: String
    ) -> CanonicalCommandDispatchResult {
        CanonicalCommandDispatchResult(
            commandID: command.commandID,
            adapterID: command.target.adapterID,
            status: .rejected,
            notes: notes
        )
    }

    private static func unsupported(
        _ command: CanonicalCommandEnvelope,
        notes: String
    ) -> CanonicalCommandDispatchResult {
        CanonicalCommandDispatchResult(
            commandID: command.commandID,
            adapterID: command.target.adapterID,
            status: .unsupported,
            notes: notes
        )
    }
}

private struct RuntimeStaticCapabilityPlane: RuntimeCapabilityPlane {
    let adapterID: RuntimeAdapterID
    let defaultLevel: AdapterCapabilityLevel
    let supportedAreas: [CanonicalSemanticArea]
    let source: AdapterCapabilitySource
    let control: AdapterCapabilityControl
    let timeoutOverrides: [RuntimeInteractionKind: TimeInterval]

    func capabilitySnapshot(for mode: RuntimeIngressMode) -> [CanonicalSemanticArea: AdapterCapabilitySnapshot] {
        Dictionary(
            uniqueKeysWithValues: supportedAreas.map { area in
                (
                    area,
                    AdapterCapabilitySnapshot(
                        adapterID: adapterID,
                        semanticArea: area,
                        level: defaultLevel,
                        source: source,
                        control: control,
                        notes: "Phase 2 \(mode.rawValue) capability placeholder"
                    )
                )
            }
        )
    }

    func timeoutOverride(for kind: RuntimeInteractionKind) -> TimeInterval? {
        timeoutOverrides[kind]
    }
}

private struct RuntimeHookObservationPlane: RuntimeObservationPlane {
    let adapterID: RuntimeAdapterID
    let legacyAgentID: String?

    func supports(hookEvent: HookEvent) -> Bool {
        guard let legacyAgentID else { return false }
        return hookEvent.agentId == legacyAgentID
    }
}

private struct RuntimeUnavailableDiscoveryPlane: RuntimeSessionDiscoveryPlane {
    let adapterID: RuntimeAdapterID

    func discoverSessions() async -> [RuntimeDiscoveredSession] {
        []
    }
}

enum RuntimeSemanticRegistry {
    private static let planes: [RuntimeAdapterID: any RuntimeSemanticPlane] = {
        let adapters: [any RuntimeAdapter] = [
            ClaudeCodeRuntimeAdapter(),
            CodexCLIRuntimeAdapter(),
            CodexAppRuntimeAdapter(),
            GeminiCLIRuntimeAdapter(),
            OpencodeRuntimeAdapter()
        ]

        var planesByID: [RuntimeAdapterID: any RuntimeSemanticPlane] = [:]
        for adapter in adapters {
            let planes = adapter.makePlanes()
            planesByID[adapter.descriptor.adapterID] = planes.semantic
        }
        return planesByID
    }()

    static func semanticPlane(for adapterID: RuntimeAdapterID) -> (any RuntimeSemanticPlane)? {
        planes[adapterID]
    }
}

enum RuntimeSemanticSupport {
    static func approvalOptions() -> [ProjectedInteractionOptionState] {
        [
            ProjectedInteractionOptionState(
                id: "deny",
                label: "Deny",
                submissionValue: "deny",
                detail: nil,
                role: .destructive
            ),
            ProjectedInteractionOptionState(
                id: "allow",
                label: "Allow",
                submissionValue: "allow",
                detail: nil,
                role: .primary
            ),
            ProjectedInteractionOptionState(
                id: "always_allow",
                label: "Bypass",
                submissionValue: "always_allow",
                detail: "Don't ask again",
                role: .bypass
            )
        ]
    }

    static func buildApprovalPrompt(
        sessionID: String,
        toolUseID: String,
        toolName: String,
        toolInput: [String: AnyCodable]?,
        createdAt: Date,
        sourceAgentID: String
    ) -> ProjectedPromptState {
        let preview = toolInput.flatMap(formatToolInputPreview(from:))
        let questionText: String
        if let preview, !preview.isEmpty {
            questionText = "Allow \(toolName) to run?\n\(preview)"
        } else {
            questionText = "Allow \(toolName) to run?"
        }
        let question = ProjectedInteractionQuestionState(
            id: "permission-\(toolUseID)",
            header: "Permission required",
            question: questionText,
            options: approvalOptions()
        )

        return ProjectedPromptState(
            id: toolUseID,
            sessionID: sessionID,
            toolUseID: toolUseID,
            toolName: toolName,
            toolInputPreview: preview,
            sourceAgentID: sourceAgentID,
            kind: .approval,
            title: "Permission required",
            questions: [question],
            preferredOptionID: "allow",
            createdAt: createdAt,
            responseCapability: .nativeHookAvailable,
            submissionEncoding: .optionValue,
            programmaticStrategy: .none,
            sourceToolInputJSON: nil
        )
    }

    static func buildChoicePrompt(
        sessionID: String,
        toolUseID: String,
        toolName: String?,
        toolInput: [String: AnyCodable],
        createdAt: Date,
        sourceAgentID: String,
        programmaticStrategy: ProjectedPromptProgrammaticStrategy
    ) -> ProjectedPromptState? {
        guard let rawQuestions = toolInput["questions"]?.value,
              let parsed = ExternalAgentToolSupport.parseAskUserQuestions(rawQuestions) else {
            return nil
        }

        let questions = buildQuestions(from: parsed.questions)
        guard !questions.isEmpty else { return nil }

        return ProjectedPromptState(
            id: toolUseID,
            sessionID: sessionID,
            toolUseID: toolUseID,
            toolName: toolName,
            toolInputPreview: formatToolInputPreview(from: toolInput),
            sourceAgentID: sourceAgentID,
            kind: .choice,
            title: questions.first?.header ?? "Choose an option",
            questions: questions,
            preferredOptionID: questions.first?.options.first(where: { $0.role == .primary })?.id,
            createdAt: createdAt,
            responseCapability: .nativeHookAvailable,
            submissionEncoding: .optionLabel,
            programmaticStrategy: programmaticStrategy,
            sourceToolInputJSON: encodeToolInputJSON(toolInput)
        )
    }

    static func buildHeuristicChoicePrompt(
        sessionID: String,
        toolUseID: String,
        toolName: String?,
        text: String,
        createdAt: Date,
        sourceAgentID: String
    ) -> ProjectedPromptState? {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count >= 3 else { return nil }

        let parsedOptions = lines.compactMap { line -> String? in
            let numbered = line.replacingOccurrences(
                of: #"^[›>→➜]?\s*\d+\.\s+"#,
                with: "",
                options: .regularExpression
            )
            if numbered != line, !numbered.isEmpty {
                return numbered
            }

            let bulleted = line.replacingOccurrences(
                of: #"^[›>→➜]?\s*[-*•]\s+"#,
                with: "",
                options: .regularExpression
            )
            if bulleted != line, !bulleted.isEmpty {
                return bulleted
            }

            return nil
        }
        guard parsedOptions.count >= 2 else { return nil }

        let question = lines.first(where: { line in
            let lower = line.lowercased()
            return line.hasSuffix("?")
                || lower.contains("choose")
                || lower.contains("select")
                || lower.contains("which")
                || lower.contains("pick")
        }) ?? lines.first ?? "Choose an option"

        let options = parsedOptions.enumerated().map { index, label in
            ProjectedInteractionOptionState(
                id: "\(index)-\(label)",
                label: label,
                submissionValue: String(index + 1),
                detail: nil,
                role: index == 0 ? .primary : .secondary
            )
        }

        return ProjectedPromptState(
            id: toolUseID,
            sessionID: sessionID,
            toolUseID: toolUseID,
            toolName: toolName,
            toolInputPreview: text,
            sourceAgentID: sourceAgentID,
            kind: .choice,
            title: "Choose an option",
            questions: [
                ProjectedInteractionQuestionState(
                    id: "question-0",
                    header: nil,
                    question: question,
                    options: options
                )
            ],
            preferredOptionID: options.first?.id,
            createdAt: createdAt,
            responseCapability: .keyboardFallbackAvailable,
            submissionEncoding: .optionValue,
            programmaticStrategy: .none,
            sourceToolInputJSON: nil
        )
    }

    static func buildQuestions(from rawQuestions: [QuestionItem]) -> [ProjectedInteractionQuestionState] {
        rawQuestions.compactMap { rawQuestion in
            let options = rawQuestion.options.enumerated().compactMap { index, option -> ProjectedInteractionOptionState? in
                let trimmedLabel = option.label.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedLabel.isEmpty else { return nil }
                let normalizedLabel = trimmedLabel.lowercased()
                let role: ProjectedInteractionOptionRole
                if normalizedLabel.contains("bypass") {
                    role = .bypass
                } else if normalizedLabel.contains("deny")
                    || normalizedLabel.contains("reject")
                    || normalizedLabel.contains("cancel")
                    || normalizedLabel.contains("skip") {
                    role = .destructive
                } else if index == 0 {
                    role = .primary
                } else {
                    role = .secondary
                }

                return ProjectedInteractionOptionState(
                    id: "\(index)-\(trimmedLabel)",
                    label: trimmedLabel.replacingOccurrences(of: "(Recommended)", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    submissionValue: String(index + 1),
                    detail: option.description,
                    role: role
                )
            }

            guard !options.isEmpty else { return nil }
            return ProjectedInteractionQuestionState(
                id: rawQuestion.id,
                header: rawQuestion.header,
                question: rawQuestion.question,
                options: options
            )
        }
    }

    static func toolHeaderDetailForClaude(
        name: String,
        input: [String: String],
        agentDescriptions: [String: String]
    ) -> String? {
        switch name {
        case "Task":
            return firstNonEmpty(input["description"])
        case "AgentOutputTool":
            guard let agentId = input["agentId"] else { return nil }
            let description = firstNonEmpty(agentDescriptions[agentId], input["description"])
            guard let description else { return nil }
            let blocking = input["block"] == "true"
            return blocking ? "Waiting: \(description)" : description
        default:
            return nil
        }
    }

    static func permissionPendingDetails(input: [String: String]) -> String? {
        let interestingKeys = [
            "command", "justification", "description", "reason",
            "permission_request_text", "request_text", "path", "file_path",
            "source_tool_input_json"
        ]

        let lines = interestingKeys.compactMap { key -> String? in
            guard let value = firstNonEmpty(input[key]) else { return nil }
            return "\(key): \(value)"
        }

        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    static func interactionPendingDetails(
        question: String?,
        options: String?
    ) -> String? {
        guard let question = firstNonEmpty(question) else { return nil }
        return firstNonEmpty(options).map { "\(question)\n\($0)" } ?? question
    }

    static func formattedQuestionDetails(from rawQuestions: String) -> String? {
        guard let data = rawQuestions.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        let lines = json.compactMap { question -> String? in
            guard let text = question["question"] as? String else { return nil }
            let options = (question["options"] as? [[String: Any]] ?? []).compactMap { option -> String? in
                guard let label = option["label"] as? String else { return nil }
                if let description = option["description"] as? String,
                   !description.isEmpty {
                    return "- \(label): \(description)"
                }
                return "- \(label)"
            }
            return ([text] + options).joined(separator: "\n")
        }

        let joined = lines.joined(separator: "\n\n")
        return joined.isEmpty ? nil : joined
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

    static func encodeToolInputJSON(_ payload: [String: AnyCodable]) -> String? {
        guard let data = try? JSONEncoder().encode(payload) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func formatJSONObject(_ object: [String: Any]) -> String {
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

    private static func formatJSONArray(_ array: [Any]) -> String {
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

    static func firstNonEmpty(_ values: String?...) -> String? {
        values.first { value in
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return false
            }
            return !trimmed.isEmpty
        } ?? nil
    }
}

struct ClaudeCodeRuntimeAdapter: RuntimeAdapter, RuntimeObservationPlane, RuntimeRecoveryPlane, RuntimeControlPlane, RuntimeCapabilityPlane, RuntimeSemanticPlane {
    let rawAgent = ClaudeCodeAgent()

    var descriptor: RuntimeAdapterDescriptor {
        RuntimeAdapterDescriptor(
            adapterID: .claudeCode,
            familyID: .claude,
            legacyAgentID: rawAgent.id,
            displayName: rawAgent.name,
            shortDisplayName: "Claude Code",
            priority: rawAgent.priority,
            supportsHooks: rawAgent.supportsHooks,
            supportedEvents: rawAgent.supportedEvents,
            eventSourceMode: rawAgent.eventSourceMode
        )
    }

    func makePlanes() -> RuntimeAdapterPlanes {
        RuntimeAdapterPlanes(
            observation: self,
            recovery: self,
            control: self,
            capability: self,
            semantic: self,
            sessionDiscovery: nil
        )
    }

    var adapterID: RuntimeAdapterID { descriptor.adapterID }

    func supports(hookEvent: HookEvent) -> Bool { hookEvent.agentId == rawAgent.id }
    func refreshProjectionState() async { await ProjectionBootstrap.shared.refresh() }
    func registerCommands(on router: CommandRouter) async {
        await RuntimeProjectionControlPlane(
            adapterID: adapterID,
            supportsInteractivePrompts: true
        ).registerCommands(on: router)
    }
    func capabilitySnapshot(for mode: RuntimeIngressMode) -> [CanonicalSemanticArea: AdapterCapabilitySnapshot] {
        RuntimeStaticCapabilityPlane(
            adapterID: adapterID,
            defaultLevel: .desktopFallback,
            supportedAreas: [.conversationLifecycle, .messageFinal, .toolLifecycle, .approvalRequest, .sessionFocus, .sessionArchive, .sessionInterrupt, .sessionClear],
            source: .hook,
            control: .localFallback,
            timeoutOverrides: [:]
        ).capabilitySnapshot(for: mode)
    }
    func timeoutOverride(for kind: RuntimeInteractionKind) -> TimeInterval? { nil }

    func managedInteractionKind(for hookEvent: HookEvent) -> RuntimeInteractionKind? {
        if hookEvent.event == HookEventType.permissionRequest.rawValue {
            return .approval
        }
        if hookEvent.event == HookEventType.preToolUse.rawValue,
           hookEvent.tool == "AskUserQuestion" {
            return .choice
        }
        return nil
    }

    func promptState(from hookEvent: HookEvent, sessionID: String, createdAt: Date) -> ProjectedPromptState? {
        guard let toolUseID = hookEvent.toolUseId else { return nil }

        switch managedInteractionKind(for: hookEvent) {
        case .approval:
            return RuntimeSemanticSupport.buildApprovalPrompt(
                sessionID: sessionID,
                toolUseID: toolUseID,
                toolName: hookEvent.tool ?? "unknown",
                toolInput: hookEvent.toolInput,
                createdAt: createdAt,
                sourceAgentID: rawAgent.id
            )
        case .choice:
            if let toolInput = hookEvent.toolInput,
               let prompt = RuntimeSemanticSupport.buildChoicePrompt(
                    sessionID: sessionID,
                    toolUseID: toolUseID,
                    toolName: hookEvent.tool,
                    toolInput: toolInput,
                    createdAt: createdAt,
                    sourceAgentID: rawAgent.id,
                    programmaticStrategy: .claudeAskUserQuestion
               ) {
                return prompt
            }

            if let message = hookEvent.message {
                return RuntimeSemanticSupport.buildHeuristicChoicePrompt(
                    sessionID: sessionID,
                    toolUseID: toolUseID,
                    toolName: hookEvent.tool,
                    text: message,
                    createdAt: createdAt,
                    sourceAgentID: rawAgent.id
                )
            }
            return nil
        case .none:
            return nil
        }
    }

    func agentDescription(
        name: String,
        input: [String: String],
        structuredResult: ToolResultData?
    ) -> (agentID: String, description: String)? {
        guard name == "Task",
              case .task(let taskResult) = structuredResult,
              !taskResult.agentId.isEmpty,
              let description = RuntimeSemanticSupport.firstNonEmpty(input["description"]) else {
            return nil
        }

        return (taskResult.agentId, description)
    }

    func toolHeaderDetail(
        name: String,
        input: [String: String],
        structuredResult _: ToolResultData?,
        agentDescriptions: [String: String]
    ) -> String? {
        RuntimeSemanticSupport.toolHeaderDetailForClaude(
            name: name,
            input: input,
            agentDescriptions: agentDescriptions
        )
    }

    func toolPendingDetails(
        name: String,
        input: [String: String],
        status: ToolStatus
    ) -> String? {
        guard status == .running || status == .waitingForApproval else {
            return nil
        }

        if name == "AskUserQuestion" {
            return RuntimeSemanticSupport.interactionPendingDetails(
                question: RuntimeSemanticSupport.firstNonEmpty(input["interaction_question"], input["question"]),
                options: RuntimeSemanticSupport.firstNonEmpty(input["interaction_options"])
            )
        }

        guard status == .waitingForApproval else { return nil }
        return RuntimeSemanticSupport.permissionPendingDetails(input: input)
    }

    func shouldStartInterruptWatcher(for hookEvent: HookEvent) -> Bool {
        switch hookEvent.status {
        case "running_tool", "processing", "starting":
            return true
        default:
            return false
        }
    }
}

struct CodexCLIRuntimeAdapter: RuntimeAdapter, RuntimeObservationPlane, RuntimeRecoveryPlane, RuntimeControlPlane, RuntimeCapabilityPlane, RuntimeSessionDiscoveryPlane, RuntimeSemanticPlane {
    let rawAgent = CodexAgent()

    var descriptor: RuntimeAdapterDescriptor {
        RuntimeAdapterDescriptor(
            adapterID: .codexCLI,
            familyID: .codex,
            legacyAgentID: rawAgent.id,
            displayName: "OpenAI Codex CLI",
            shortDisplayName: "Codex CLI",
            priority: rawAgent.priority,
            supportsHooks: rawAgent.supportsHooks,
            supportedEvents: rawAgent.supportedEvents,
            eventSourceMode: rawAgent.eventSourceMode
        )
    }

    func makePlanes() -> RuntimeAdapterPlanes {
        RuntimeAdapterPlanes(
            observation: self,
            recovery: self,
            control: self,
            capability: self,
            semantic: self,
            sessionDiscovery: self
        )
    }

    var adapterID: RuntimeAdapterID { descriptor.adapterID }

    func supports(hookEvent: HookEvent) -> Bool { hookEvent.agentId == rawAgent.id }
    func refreshProjectionState() async { await ProjectionBootstrap.shared.refresh() }
    func registerCommands(on router: CommandRouter) async {
        await RuntimeProjectionControlPlane(
            adapterID: adapterID,
            supportsInteractivePrompts: true
        ).registerCommands(on: router)
    }
    func capabilitySnapshot(for mode: RuntimeIngressMode) -> [CanonicalSemanticArea: AdapterCapabilitySnapshot] {
        var capabilities = RuntimeStaticCapabilityPlane(
            adapterID: adapterID,
            defaultLevel: mode == .attached ? .authoritative : .desktopFallback,
            supportedAreas: [.conversationLifecycle, .messageFinal, .toolLifecycle, .approvalRequest, .userChoiceRequest, .sessionFocus, .sessionArchive, .sessionInterrupt, .sessionClear],
            source: mode == .attached ? .hook : .localState,
            control: .localFallback,
            timeoutOverrides: [:]
        ).capabilitySnapshot(for: mode)

        let desktopFallbackControls = RuntimeStaticCapabilityPlane(
            adapterID: adapterID,
            defaultLevel: .desktopFallback,
            supportedAreas: [.sessionFocus, .sessionArchive, .sessionInterrupt, .sessionClear],
            source: .localState,
            control: .localFallback,
            timeoutOverrides: [:]
        ).capabilitySnapshot(for: mode)

        capabilities.merge(desktopFallbackControls) { _, updated in updated }
        return capabilities
    }
    func timeoutOverride(for kind: RuntimeInteractionKind) -> TimeInterval? { nil }

    func discoverSessions() async -> [RuntimeDiscoveredSession] {
        rawAgent.detectRunningSessions()
            .filter { $0.variant != .app }
            .map {
                RuntimeDiscoveredSession(
                    adapterID: .codexCLI,
                    legacyAgentID: rawAgent.id,
                    sessionID: $0.sessionId,
                    cwd: $0.cwd,
                    pid: $0.pid,
                    tty: nil
                )
            }
    }

    func managedInteractionKind(for hookEvent: HookEvent) -> RuntimeInteractionKind? {
        if hookEvent.event == HookEventType.permissionRequest.rawValue {
            return .approval
        }
        if hookEvent.event == HookEventType.preToolUse.rawValue,
           hookEvent.status == "waiting_for_approval" {
            return .approval
        }
        if hookEvent.event == HookEventType.preToolUse.rawValue,
           hookEvent.tool == "request_user_input" {
            return .choice
        }
        return nil
    }

    func promptState(from hookEvent: HookEvent, sessionID: String, createdAt: Date) -> ProjectedPromptState? {
        guard let toolUseID = hookEvent.toolUseId else { return nil }

        switch managedInteractionKind(for: hookEvent) {
        case .approval:
            return RuntimeSemanticSupport.buildApprovalPrompt(
                sessionID: sessionID,
                toolUseID: toolUseID,
                toolName: hookEvent.tool ?? "unknown",
                toolInput: hookEvent.toolInput,
                createdAt: createdAt,
                sourceAgentID: rawAgent.id
            )
        case .choice:
            if let toolInput = hookEvent.toolInput,
               let prompt = RuntimeSemanticSupport.buildChoicePrompt(
                    sessionID: sessionID,
                    toolUseID: toolUseID,
                    toolName: hookEvent.tool,
                    toolInput: toolInput,
                    createdAt: createdAt,
                    sourceAgentID: rawAgent.id,
                    programmaticStrategy: .none
               ) {
                return prompt
            }
            if let message = hookEvent.message {
                return RuntimeSemanticSupport.buildHeuristicChoicePrompt(
                    sessionID: sessionID,
                    toolUseID: toolUseID,
                    toolName: hookEvent.tool,
                    text: message,
                    createdAt: createdAt,
                    sourceAgentID: rawAgent.id
                )
            }
            return nil
        case .none:
            return nil
        }
    }

    func toolPendingDetails(
        name: String,
        input: [String: String],
        status: ToolStatus
    ) -> String? {
        guard status == .running || status == .waitingForApproval else {
            return nil
        }

        if name == "request_user_input",
           let rawQuestions = input["questions"] {
            return RuntimeSemanticSupport.formattedQuestionDetails(from: rawQuestions)
        }

        guard status == .waitingForApproval else { return nil }
        return RuntimeSemanticSupport.permissionPendingDetails(input: input)
    }
}

struct CodexAppRuntimeAdapter: RuntimeAdapter, RuntimeObservationPlane, RuntimeRecoveryPlane, RuntimeControlPlane, RuntimeCapabilityPlane, RuntimeSessionDiscoveryPlane, RuntimeSemanticPlane {
    let rawAgent = CodexAgent()

    var descriptor: RuntimeAdapterDescriptor {
        RuntimeAdapterDescriptor(
            adapterID: .codexApp,
            familyID: .codex,
            legacyAgentID: nil,
            displayName: "OpenAI Codex App",
            shortDisplayName: "Codex App",
            priority: rawAgent.priority + 1,
            supportsHooks: false,
            supportedEvents: [],
            eventSourceMode: .processOnly
        )
    }

    func makePlanes() -> RuntimeAdapterPlanes {
        RuntimeAdapterPlanes(
            observation: self,
            recovery: self,
            control: self,
            capability: self,
            semantic: self,
            sessionDiscovery: self
        )
    }

    var adapterID: RuntimeAdapterID { descriptor.adapterID }

    func supports(hookEvent _: HookEvent) -> Bool { false }
    func refreshProjectionState() async { await ProjectionBootstrap.shared.refresh() }
    func registerCommands(on router: CommandRouter) async {
        await RuntimeProjectionControlPlane(
            adapterID: adapterID,
            supportsInteractivePrompts: false
        ).registerCommands(on: router)
    }
    func capabilitySnapshot(for mode: RuntimeIngressMode) -> [CanonicalSemanticArea: AdapterCapabilitySnapshot] {
        RuntimeStaticCapabilityPlane(
            adapterID: adapterID,
            defaultLevel: .observableOnly,
            supportedAreas: [.conversationLifecycle, .messageFinal],
            source: mode == .attached ? .stream : .localState,
            control: .none,
            timeoutOverrides: [:]
        ).capabilitySnapshot(for: mode)
    }
    func timeoutOverride(for kind: RuntimeInteractionKind) -> TimeInterval? { nil }

    func discoverSessions() async -> [RuntimeDiscoveredSession] {
        rawAgent.detectRunningSessions()
            .filter { $0.variant == .app }
            .map {
                RuntimeDiscoveredSession(
                    adapterID: .codexApp,
                    legacyAgentID: rawAgent.id,
                    sessionID: $0.sessionId,
                    cwd: $0.cwd,
                    pid: $0.pid,
                    tty: nil
                )
            }
    }
}

struct GeminiCLIRuntimeAdapter: RuntimeAdapter, RuntimeObservationPlane, RuntimeRecoveryPlane, RuntimeControlPlane, RuntimeCapabilityPlane, RuntimeSessionDiscoveryPlane, RuntimeSemanticPlane {
    let rawAgent = GeminiCLIAgent()

    var descriptor: RuntimeAdapterDescriptor {
        RuntimeAdapterDescriptor(
            adapterID: .geminiCLI,
            familyID: .gemini,
            legacyAgentID: rawAgent.id,
            displayName: rawAgent.name,
            shortDisplayName: "Gemini CLI",
            priority: rawAgent.priority,
            supportsHooks: rawAgent.supportsHooks,
            supportedEvents: rawAgent.supportedEvents,
            eventSourceMode: rawAgent.eventSourceMode
        )
    }

    func makePlanes() -> RuntimeAdapterPlanes {
        RuntimeAdapterPlanes(
            observation: self,
            recovery: self,
            control: self,
            capability: self,
            semantic: self,
            sessionDiscovery: self
        )
    }

    var adapterID: RuntimeAdapterID { descriptor.adapterID }

    func supports(hookEvent: HookEvent) -> Bool { hookEvent.agentId == rawAgent.id }
    func refreshProjectionState() async { await ProjectionBootstrap.shared.refresh() }
    func registerCommands(on router: CommandRouter) async {
        await RuntimeProjectionControlPlane(
            adapterID: adapterID,
            supportsInteractivePrompts: true
        ).registerCommands(on: router)
    }
    func capabilitySnapshot(for mode: RuntimeIngressMode) -> [CanonicalSemanticArea: AdapterCapabilitySnapshot] {
        RuntimeStaticCapabilityPlane(
            adapterID: adapterID,
            defaultLevel: .desktopFallback,
            supportedAreas: [.conversationLifecycle, .messageFinal, .toolLifecycle, .approvalRequest, .userChoiceRequest],
            source: mode == .attached ? .hook : .localState,
            control: .localFallback,
            timeoutOverrides: [:]
        ).capabilitySnapshot(for: mode)
    }
    func timeoutOverride(for kind: RuntimeInteractionKind) -> TimeInterval? { nil }

    func discoverSessions() async -> [RuntimeDiscoveredSession] {
        rawAgent.detectRunningSessions().map {
            RuntimeDiscoveredSession(
                adapterID: .geminiCLI,
                legacyAgentID: rawAgent.id,
                sessionID: $0.sessionId,
                cwd: $0.cwd,
                pid: $0.pid,
                tty: nil
            )
        }
    }

    func managedInteractionKind(for hookEvent: HookEvent) -> RuntimeInteractionKind? {
        if hookEvent.event == HookEventType.permissionRequest.rawValue {
            return .approval
        }
        if hookEvent.event == HookEventType.preToolUse.rawValue,
           hookEvent.tool == "ask_user" {
            return .choice
        }
        return nil
    }

    func promptState(from hookEvent: HookEvent, sessionID: String, createdAt: Date) -> ProjectedPromptState? {
        guard let toolUseID = hookEvent.toolUseId else { return nil }

        switch managedInteractionKind(for: hookEvent) {
        case .approval:
            return RuntimeSemanticSupport.buildApprovalPrompt(
                sessionID: sessionID,
                toolUseID: toolUseID,
                toolName: hookEvent.tool ?? "unknown",
                toolInput: hookEvent.toolInput,
                createdAt: createdAt,
                sourceAgentID: rawAgent.id
            )
        case .choice:
            if let toolInput = hookEvent.toolInput,
               let prompt = RuntimeSemanticSupport.buildChoicePrompt(
                    sessionID: sessionID,
                    toolUseID: toolUseID,
                    toolName: hookEvent.tool,
                    toolInput: toolInput,
                    createdAt: createdAt,
                    sourceAgentID: rawAgent.id,
                    programmaticStrategy: .none
               ) {
                return prompt
            }
            if let message = hookEvent.message {
                return RuntimeSemanticSupport.buildHeuristicChoicePrompt(
                    sessionID: sessionID,
                    toolUseID: toolUseID,
                    toolName: hookEvent.tool,
                    text: message,
                    createdAt: createdAt,
                    sourceAgentID: rawAgent.id
                )
            }
            return nil
        case .none:
            return nil
        }
    }

    func toolPendingDetails(
        name: String,
        input: [String: String],
        status: ToolStatus
    ) -> String? {
        guard status == .running || status == .waitingForApproval else {
            return nil
        }

        if name == "ask_user",
           let rawQuestions = input["questions"] {
            return RuntimeSemanticSupport.formattedQuestionDetails(from: rawQuestions)
        }

        guard status == .waitingForApproval else { return nil }
        return RuntimeSemanticSupport.permissionPendingDetails(input: input)
    }
}

struct OpencodeRuntimeAdapter: RuntimeAdapter, RuntimeObservationPlane, RuntimeRecoveryPlane, RuntimeControlPlane, RuntimeCapabilityPlane, RuntimeSemanticPlane {
    var descriptor: RuntimeAdapterDescriptor {
        RuntimeAdapterDescriptor(
            adapterID: .opencode,
            familyID: .opencode,
            legacyAgentID: "opencode",
            displayName: "OpenCode",
            shortDisplayName: "OpenCode",
            priority: 99,
            supportsHooks: false,
            supportedEvents: [],
            eventSourceMode: .processOnly
        )
    }

    func makePlanes() -> RuntimeAdapterPlanes {
        RuntimeAdapterPlanes(
            observation: self,
            recovery: self,
            control: self,
            capability: self,
            semantic: self,
            sessionDiscovery: nil
        )
    }

    var adapterID: RuntimeAdapterID { descriptor.adapterID }

    func supports(hookEvent _: HookEvent) -> Bool { false }
    func refreshProjectionState() async { await ProjectionBootstrap.shared.refresh() }
    func registerCommands(on router: CommandRouter) async {
        await RuntimeProjectionControlPlane(
            adapterID: adapterID,
            supportsInteractivePrompts: false
        ).registerCommands(on: router)
    }
    func capabilitySnapshot(for mode: RuntimeIngressMode) -> [CanonicalSemanticArea: AdapterCapabilitySnapshot] {
        RuntimeStaticCapabilityPlane(
            adapterID: adapterID,
            defaultLevel: .unsupported,
            supportedAreas: [],
            source: .localState,
            control: .none,
            timeoutOverrides: [:]
        ).capabilitySnapshot(for: mode)
    }
    func timeoutOverride(for kind: RuntimeInteractionKind) -> TimeInterval? { nil }
}
