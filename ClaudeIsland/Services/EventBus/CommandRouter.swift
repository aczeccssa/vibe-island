//
//  CommandRouter.swift
//  ClaudeIsland
//
//  Phase 1 canonical command router skeleton.
//

import Foundation
import os.log

typealias CanonicalCommandHandler = @Sendable (CanonicalCommandEnvelope) async -> CanonicalCommandDispatchResult

actor CommandRouter {
    private static let logger = Logger(subsystem: "com.claudeisland", category: "CommandRouter")
    private var handlers: [RuntimeAdapterID: CanonicalCommandHandler] = [:]

    func registerHandler(
        for adapterID: RuntimeAdapterID,
        handler: @escaping CanonicalCommandHandler
    ) {
        handlers[adapterID] = handler
    }

    func unregisterHandler(for adapterID: RuntimeAdapterID) {
        handlers.removeValue(forKey: adapterID)
    }

    func dispatch(_ command: CanonicalCommandEnvelope) async -> CanonicalCommandDispatchResult {
        guard let handler = handlers[command.target.adapterID] else {
            Self.logger.warning(
                "No command handler registered for adapter \(command.target.adapterID.rawValue, privacy: .public) command \(command.type.rawValue, privacy: .public)"
            )
            return CanonicalCommandDispatchResult(
                commandID: command.commandID,
                adapterID: command.target.adapterID,
                status: .unsupported,
                notes: "No command handler is registered for \(command.target.adapterID.rawValue)."
            )
        }

        return await handler(command)
    }
}
