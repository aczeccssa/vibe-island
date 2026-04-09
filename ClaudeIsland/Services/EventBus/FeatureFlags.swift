//
//  FeatureFlags.swift
//  ClaudeIsland
//
//  Phase 0 feature flags. All flags default to off and are read-only
//  scaffolding until later cutover phases opt into them explicitly.
//

import Foundation

struct EventBusFeatureFlags: Sendable {
    let enableClaudeCodeAdapterPath: Bool
    let enableCodexCLIAdapterPath: Bool
    let enableCodexAppAdapterPath: Bool
    let enableGeminiCLIAdapterPath: Bool
    let enableOpencodeAdapterPath: Bool
    let enableCanonicalProjectionPath: Bool
    let enableParityLogging: Bool
    let enableShadowDiffLogging: Bool

    init(
        environment: [String: String] = Foundation.ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) {
        enableClaudeCodeAdapterPath = Self.readFlag(
            environmentKey: "VIBE_ISLAND_ENABLE_CLAUDE_CODE_ADAPTER_PATH",
            defaultsKey: "eventBus.enableClaudeCodeAdapterPath",
            environment: environment,
            defaults: defaults
        )
        enableCodexCLIAdapterPath = Self.readFlag(
            environmentKey: "VIBE_ISLAND_ENABLE_CODEX_CLI_ADAPTER_PATH",
            defaultsKey: "eventBus.enableCodexCLIAdapterPath",
            environment: environment,
            defaults: defaults
        )
        enableCodexAppAdapterPath = Self.readFlag(
            environmentKey: "VIBE_ISLAND_ENABLE_CODEX_APP_ADAPTER_PATH",
            defaultsKey: "eventBus.enableCodexAppAdapterPath",
            environment: environment,
            defaults: defaults
        )
        enableGeminiCLIAdapterPath = Self.readFlag(
            environmentKey: "VIBE_ISLAND_ENABLE_GEMINI_CLI_ADAPTER_PATH",
            defaultsKey: "eventBus.enableGeminiCLIAdapterPath",
            environment: environment,
            defaults: defaults
        )
        enableOpencodeAdapterPath = Self.readFlag(
            environmentKey: "VIBE_ISLAND_ENABLE_OPENCODE_ADAPTER_PATH",
            defaultsKey: "eventBus.enableOpencodeAdapterPath",
            environment: environment,
            defaults: defaults
        )
        enableCanonicalProjectionPath = Self.readFlag(
            environmentKey: "VIBE_ISLAND_ENABLE_CANONICAL_PROJECTION_PATH",
            defaultsKey: "eventBus.enableCanonicalProjectionPath",
            environment: environment,
            defaults: defaults
        )
        enableParityLogging = Self.readFlag(
            environmentKey: "VIBE_ISLAND_ENABLE_PARITY_LOGGING",
            defaultsKey: "eventBus.enableParityLogging",
            environment: environment,
            defaults: defaults
        )
        enableShadowDiffLogging = Self.readFlag(
            environmentKey: "VIBE_ISLAND_ENABLE_SHADOW_DIFF_LOGGING",
            defaultsKey: "eventBus.enableShadowDiffLogging",
            environment: environment,
            defaults: defaults
        )
    }

    static func snapshot() -> EventBusFeatureFlags {
        EventBusFeatureFlags()
    }

    var hasExplicitLivePathSelection: Bool {
        enableCanonicalProjectionPath
        || enableClaudeCodeAdapterPath
        || enableCodexCLIAdapterPath
        || enableCodexAppAdapterPath
        || enableGeminiCLIAdapterPath
        || enableOpencodeAdapterPath
    }

    private static func readFlag(
        environmentKey: String,
        defaultsKey: String,
        environment: [String: String],
        defaults: UserDefaults
    ) -> Bool {
        if let raw = environment[environmentKey] {
            return parseBool(raw)
        }
        guard defaults.object(forKey: defaultsKey) != nil else {
            return false
        }
        return defaults.bool(forKey: defaultsKey)
    }

    private static func parseBool(_ raw: String) -> Bool {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }
}
