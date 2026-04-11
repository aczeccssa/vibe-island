//
//  HookInstaller.swift
//  ClaudeIsland
//
//  Unified hook installer for all supported agents
//

import Foundation
import os.log

@MainActor
struct HookInstaller {
    private static let logger = Logger(subsystem: "com.claudeisland", category: "HookInstaller")
    private static let hookAgents = RuntimeAdapterCatalog.hookInstallableAgents()

    /// Install hook scripts and update hook settings for all supported agents.
    static func installIfNeeded() {
        for agent in hookAgents where agent.supportsHooks {
            do {
                try agent.installHooks()
            } catch {
                logger.error("Failed to install hooks for \(agent.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Check if hooks are currently installed for all hook-capable agents.
    static func isInstalled() -> Bool {
        let capableAgents = hookAgents.filter { $0.supportsHooks }
        guard !capableAgents.isEmpty else { return false }
        return capableAgents.allSatisfy { $0.areHooksInstalled() }
    }

    /// Uninstall hooks for all hook-capable agents.
    static func uninstall() {
        for agent in hookAgents where agent.supportsHooks {
            do {
                try agent.uninstallHooks()
            } catch {
                logger.error("Failed to uninstall hooks for \(agent.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
