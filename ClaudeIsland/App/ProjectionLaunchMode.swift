//
//  ProjectionLaunchMode.swift
//  ClaudeIsland
//
//  Launch configuration for live versus projection-fixture boot.
//

import Foundation

enum ProjectionLaunchMode: Equatable, Sendable {
    case live
    case projectedFixture(ProjectionFixtureLaunchConfiguration)

    struct ProjectionFixtureLaunchConfiguration: Equatable, Sendable {
        enum InitialContent: Equatable, Sendable {
            case instances
            case chat(sessionID: String)
        }

        let fixturePath: String
        let initialContent: InitialContent
    }

    static let current: ProjectionLaunchMode = {
        let processInfo = Foundation.ProcessInfo.processInfo
        let environment = processInfo.environment
        let arguments = processInfo.arguments

        let rawMode = environment["CLAUDE_ISLAND_LAUNCH_MODE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let fixturePath = environment["CLAUDE_ISLAND_PROJECTION_FIXTURE_PATH"]
            ?? value(after: "--projection-fixture", in: arguments)

        let bootSessionID = environment["CLAUDE_ISLAND_BOOT_SESSION_ID"]
            ?? value(after: "--boot-session-id", in: arguments)

        let shouldUseFixture = rawMode == "projected_fixture" || fixturePath != nil

        guard shouldUseFixture, let fixturePath, !fixturePath.isEmpty else {
            return .live
        }

        let initialContent: ProjectionFixtureLaunchConfiguration.InitialContent
        if let bootSessionID, !bootSessionID.isEmpty {
            initialContent = .chat(sessionID: bootSessionID)
        } else {
            initialContent = .instances
        }

        return .projectedFixture(
            ProjectionFixtureLaunchConfiguration(
                fixturePath: fixturePath,
                initialContent: initialContent
            )
        )
    }()

    var startsLiveIngress: Bool {
        if case .live = self {
            return true
        }
        return false
    }

    var allowsExternalSideEffects: Bool {
        startsLiveIngress
    }

    var isFixture: Bool {
        !startsLiveIngress
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}
