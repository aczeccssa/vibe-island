//
//  ProjectionCompatibilityStore.swift
//  ClaudeIsland
//
//  MainActor-published projection-backed compatibility sessions for current UI.
//

import Combine
import Foundation

@MainActor
final class ProjectionCompatibilityStore: ObservableObject {
    static let shared = ProjectionCompatibilityStore()

    @Published private(set) var sessions: [SessionState] = []
    @Published private(set) var hydratedSessionIDs: Set<String> = []
    @Published private(set) var fixtureBootSessionID: String?

    private init() {}

    func update(
        sessions: [SessionState],
        hydratedSessionIDs: Set<String>,
        fixtureBootSessionID: String?
    ) {
        self.fixtureBootSessionID = fixtureBootSessionID
        self.hydratedSessionIDs = hydratedSessionIDs
        self.sessions = sessions
    }

    func clear() {
        sessions = []
        hydratedSessionIDs = []
        fixtureBootSessionID = nil
    }
}
