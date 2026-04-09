//
//  RuntimeIdentity.swift
//  ClaudeIsland
//
//  Phase 0 runtime identity scaffolding. This is additive only and must not
//  change current runtime behavior until later adapter/bus phases cut over.
//

import Foundation

enum RuntimeAdapterID: String, CaseIterable, Codable, Hashable, Sendable {
    case claudeCode = "claude-code"
    case codexCLI = "codex-cli"
    case codexApp = "codex-app"
    case geminiCLI = "gemini-cli"
    case opencode = "opencode"
}

enum RuntimeFamilyID: String, CaseIterable, Codable, Hashable, Sendable {
    case claude
    case codex
    case gemini
    case opencode
}

enum RuntimeModeHint: String, Codable, Hashable, Sendable {
    case cli
    case app
    case unknown
}

struct RuntimeIdentity: Codable, Equatable, Hashable, Sendable {
    let adapterID: RuntimeAdapterID
    let familyID: RuntimeFamilyID
    let modeHint: RuntimeModeHint
}

extension RuntimeIdentity {
    static func fromLegacyAgentID(_ agentID: String) -> RuntimeIdentity? {
        switch agentID {
        case "claude":
            return RuntimeIdentity(adapterID: .claudeCode, familyID: .claude, modeHint: .cli)
        case "codex":
            return RuntimeIdentity(adapterID: .codexCLI, familyID: .codex, modeHint: .unknown)
        case "codex-app":
            return RuntimeIdentity(adapterID: .codexApp, familyID: .codex, modeHint: .app)
        case "gemini":
            return RuntimeIdentity(adapterID: .geminiCLI, familyID: .gemini, modeHint: .cli)
        case "opencode":
            return RuntimeIdentity(adapterID: .opencode, familyID: .opencode, modeHint: .unknown)
        default:
            return nil
        }
    }

    static func forCodexVariant(_ variant: CodexAgent.CodexVariant) -> RuntimeIdentity {
        switch variant {
        case .cli:
            return RuntimeIdentity(adapterID: .codexCLI, familyID: .codex, modeHint: .cli)
        case .app:
            return RuntimeIdentity(adapterID: .codexApp, familyID: .codex, modeHint: .app)
        case .unknown:
            return RuntimeIdentity(adapterID: .codexCLI, familyID: .codex, modeHint: .unknown)
        }
    }
}

extension CodexAgent.CodexVariant {
    var runtimeIdentity: RuntimeIdentity {
        RuntimeIdentity.forCodexVariant(self)
    }
}
