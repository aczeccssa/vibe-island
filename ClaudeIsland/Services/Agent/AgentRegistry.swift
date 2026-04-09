//
//  AgentRegistry.swift
//  ClaudeIsland
//
//  Phase 2 metadata-only adapter registry.
//

import Combine
import Foundation

nonisolated private func adapterIDForLegacyAgentID(_ legacyAgentID: String) -> RuntimeAdapterID? {
    switch legacyAgentID {
    case "claude":
        return .claudeCode
    case "codex":
        return .codexCLI
    case "codex-app":
        return .codexApp
    case "gemini":
        return .geminiCLI
    case "opencode":
        return .opencode
    default:
        return nil
    }
}

@MainActor
final class AgentRegistry: ObservableObject {
    static let shared = AgentRegistry()

    @Published private(set) var descriptors: [RuntimeAdapterID: RuntimeAdapterDescriptor] = [:]
    @Published private(set) var primaryAdapterID: RuntimeAdapterID?

    private init() {
        registerDefaultDescriptors()
    }

    private func registerDefaultDescriptors() {
        let adapters: [any RuntimeAdapter] = [
            ClaudeCodeRuntimeAdapter(),
            CodexCLIRuntimeAdapter(),
            CodexAppRuntimeAdapter(),
            GeminiCLIRuntimeAdapter(),
            OpencodeRuntimeAdapter()
        ]

        descriptors = Dictionary(uniqueKeysWithValues: adapters.map { ($0.descriptor.adapterID, $0.descriptor) })
    }

    func descriptor(for adapterID: RuntimeAdapterID) -> RuntimeAdapterDescriptor? {
        descriptors[adapterID]
    }

    func allDescriptors() -> [RuntimeAdapterDescriptor] {
        descriptors.values.sorted { lhs, rhs in
            if lhs.priority != rhs.priority {
                return lhs.priority < rhs.priority
            }
            return lhs.displayName < rhs.displayName
        }
    }

    func updatePrimaryAgent(withSessionFrom legacyAgentID: String) {
        primaryAdapterID = adapterIDForLegacyAgentID(legacyAgentID)
    }

    func updatePrimaryAdapter(_ adapterID: RuntimeAdapterID?) {
        primaryAdapterID = adapterID
    }

    func displayName(for legacyAgentID: String?) -> String {
        guard let adapterID = legacyAgentID.flatMap(adapterIDForLegacyAgentID),
              let descriptor = descriptors[adapterID] else {
            return descriptors[.claudeCode]?.displayName ?? "Claude Code"
        }
        return descriptor.displayName
    }

    func shortDisplayName(for legacyAgentID: String?) -> String {
        guard let adapterID = legacyAgentID.flatMap(adapterIDForLegacyAgentID),
              let descriptor = descriptors[adapterID] else {
            return descriptors[.claudeCode]?.shortDisplayName ?? "Claude Code"
        }
        return descriptor.shortDisplayName
    }

    func shortDisplayName(for adapterID: RuntimeAdapterID?) -> String {
        guard let adapterID, let descriptor = descriptors[adapterID] else {
            return descriptors[.claudeCode]?.shortDisplayName ?? "Claude Code"
        }
        return descriptor.shortDisplayName
    }

    var primaryLegacyAgentID: String? {
        descriptors[primaryAdapterID ?? .claudeCode]?.legacyAgentID
    }

    nonisolated static func adapterID(forLegacyAgentID legacyAgentID: String) -> RuntimeAdapterID? {
        adapterIDForLegacyAgentID(legacyAgentID)
    }
}

enum AgentError: Error {
    case unknownAgent(String)
    case hookInstallationFailed(String)
}
