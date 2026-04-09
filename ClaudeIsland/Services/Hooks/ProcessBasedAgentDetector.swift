//
//  ProcessBasedAgentDetector.swift
//  ClaudeIsland
//
//  Phase 2 session discovery worker owned by RuntimeOrchestrator.
//

import Darwin
import Foundation
import os.log

actor ProcessBasedAgentDetector {
    static let shared = ProcessBasedAgentDetector()

    typealias TrackedSessionsProvider = @Sendable () async -> [RuntimeTrackedSession]
    typealias SessionDiscoveredHandler = @Sendable (RuntimeDiscoveredSession) async -> Void
    typealias SessionEndedHandler = @Sendable (String) async -> Void

    private let logger = Logger(subsystem: "com.claudeisland", category: "ProcessDetector")
    private let pollIntervalSeconds: UInt64 = 2
    private var pollTask: Task<Void, Never>?
    private var discoveryPlanes: [any RuntimeSessionDiscoveryPlane] = []
    private var trackedSessionsProvider: TrackedSessionsProvider?
    private var onSessionDiscovered: SessionDiscoveredHandler?
    private var onSessionEnded: SessionEndedHandler?

    private init() {}

    func start(
        discoveryPlanes: [any RuntimeSessionDiscoveryPlane],
        trackedSessionsProvider: @escaping TrackedSessionsProvider,
        onSessionDiscovered: @escaping SessionDiscoveredHandler,
        onSessionEnded: @escaping SessionEndedHandler
    ) {
        guard pollTask == nil else { return }

        self.discoveryPlanes = discoveryPlanes
        self.trackedSessionsProvider = trackedSessionsProvider
        self.onSessionDiscovered = onSessionDiscovered
        self.onSessionEnded = onSessionEnded

        logger.info("Process liveness detector started")

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(nanoseconds: (self?.pollIntervalSeconds ?? 2) * 1_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        discoveryPlanes = []
        trackedSessionsProvider = nil
        onSessionDiscovered = nil
        onSessionEnded = nil
        logger.info("Process liveness detector stopped")
    }

    private func poll() async {
        await discoverRunningSessions()

        guard let trackedSessionsProvider, let onSessionEnded else { return }
        let trackedSessions = await trackedSessionsProvider()
        for session in trackedSessions {
            guard let pid = session.pid else { continue }
            guard !isProcessAlive(pid) else { continue }
            logger.info("Tracked session process ended: \(session.sessionID, privacy: .public) pid=\(pid, privacy: .public)")
            await onSessionEnded(session.sessionID)
        }
    }

    private func discoverRunningSessions() async {
        guard let onSessionDiscovered else { return }
        let trackedSessions = await trackedSessionsProvider?() ?? []
        let trackedBySessionID = Dictionary(uniqueKeysWithValues: trackedSessions.map { ($0.sessionID, $0) })

        for plane in discoveryPlanes {
            let discovered = await plane.discoverSessions()
            for session in discovered where !session.cwd.isEmpty {
                if let tracked = trackedBySessionID[session.sessionID],
                   tracked.pid == session.pid {
                    continue
                }
                logger.debug(
                    "Discovered runtime session: adapter=\(session.adapterID.rawValue, privacy: .public) pid=\(String(session.pid ?? 0), privacy: .public) session=\(session.sessionID, privacy: .public)"
                )
                await onSessionDiscovered(session)
            }
        }
    }

    private func isProcessAlive(_ pid: Int) -> Bool {
        if kill(pid_t(pid), 0) == 0 {
            return true
        }

        return errno == EPERM
    }
}
