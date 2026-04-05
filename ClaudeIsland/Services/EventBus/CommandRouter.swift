//
//  CommandRouter.swift
//  ClaudeIsland
//
//  Phase 1 canonical command router skeleton.
//

import Foundation

typealias CanonicalCommandHandler = @Sendable (CanonicalCommandEnvelope) async -> CanonicalCommandDispatchResult

actor CommandRouter {
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
