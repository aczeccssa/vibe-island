import Foundation
import XCTest
@testable import Claude_Island

final class ArchitectureInvariantTests: XCTestCase {
    func testCanonicalEventEnvelopePreservesRawVendorPayload() throws {
        let event = try CanonicalEventEnvelope(
            eventID: UUID(uuidString: "70000000-0000-0000-0000-000000000001")!,
            type: .messageFinal,
            occurredAt: CanonicalFixtures.baseDate,
            observedAt: CanonicalFixtures.baseDate.addingTimeInterval(1),
            adapterID: .claudeCode,
            agent: CanonicalFixtures.agent(sourceKind: .hook),
            conversation: CanonicalFixtures.conversation(),
            turn: CanonicalFixtures.turn(status: .completed),
            entity: CanonicalFixtures.entity(messageID: "raw-preserved-message"),
            payload: .messageFinal(
                CanonicalMessageFinalPayload(
                    message: CanonicalFinalMessage(
                        id: "raw-preserved-message",
                        role: .assistant,
                        format: .json,
                        text: "{\"ok\":true}",
                        isFinal: true
                    )
                )
            ),
            raw: CanonicalRawEvent(
                vendorEvent: "message_final",
                vendorPayload: [
                    "string": AnyCodable("value"),
                    "number": AnyCodable(42),
                    "array": AnyCodable(["a", "b"]),
                    "object": AnyCodable(["nested": "yes"])
                ]
            )
        )

        let encoded = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(CanonicalEventEnvelope.self, from: encoded)

        XCTAssertEqual(decoded.raw.vendorPayload["string"], AnyCodable("value"))
        XCTAssertEqual(decoded.raw.vendorPayload["number"], AnyCodable(42))
        XCTAssertEqual(decoded.raw.vendorPayload["array"], AnyCodable(["a", "b"]))
        XCTAssertEqual(decoded.raw.vendorPayload["object"], AnyCodable(["nested": "yes"]))
    }

    func testCanonicalEventEnvelopeDecodingFailsWithoutAdapterID() throws {
        let event = CanonicalFixtures.conversationActiveEvent()
        let encoded = try JSONEncoder().encode(event)
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        json.removeValue(forKey: "adapter_id")

        let mutated = try JSONSerialization.data(withJSONObject: json)

        XCTAssertThrowsError(try JSONDecoder().decode(CanonicalEventEnvelope.self, from: mutated))
    }

    func testCommandRouterDispatchesByAdapterID() async {
        let router = CommandRouter()

        await router.registerHandler(for: .claudeCode) { command in
            CanonicalCommandDispatchResult(
                commandID: command.commandID,
                adapterID: .claudeCode,
                status: .accepted,
                notes: "claude"
            )
        }
        await router.registerHandler(for: .codexCLI) { command in
            CanonicalCommandDispatchResult(
                commandID: command.commandID,
                adapterID: .codexCLI,
                status: .rejected,
                notes: "codex"
            )
        }

        let claudeResult = await router.dispatch(
            CanonicalCommandEnvelope(
                commandID: UUID(uuidString: "70000000-0000-0000-0000-000000000002")!,
                issuedAt: CanonicalFixtures.baseDate,
                conversationID: "conversation-1",
                target: CanonicalCommandTarget(
                    adapterID: .claudeCode,
                    entityType: .session,
                    entityID: "conversation-1"
                ),
                type: .sessionFocus,
                mode: .authoritative,
                idempotencyKey: "claude-route",
                payload: .sessionFocus(CanonicalSessionCommandPayload(reason: "route claude"))
            )
        )
        let codexResult = await router.dispatch(
            CanonicalCommandEnvelope(
                commandID: UUID(uuidString: "70000000-0000-0000-0000-000000000003")!,
                issuedAt: CanonicalFixtures.baseDate,
                conversationID: "conversation-1",
                target: CanonicalCommandTarget(
                    adapterID: .codexCLI,
                    entityType: .session,
                    entityID: "conversation-1"
                ),
                type: .sessionFocus,
                mode: .authoritative,
                idempotencyKey: "codex-route",
                payload: .sessionFocus(CanonicalSessionCommandPayload(reason: "route codex"))
            )
        )

        XCTAssertEqual(claudeResult.adapterID, .claudeCode)
        XCTAssertEqual(claudeResult.status, .accepted)
        XCTAssertEqual(claudeResult.notes, "claude")
        XCTAssertEqual(codexResult.adapterID, .codexCLI)
        XCTAssertEqual(codexResult.status, .rejected)
        XCTAssertEqual(codexResult.notes, "codex")
    }

    func testCanonicalProjectionAndModernUIStateHaveNoSessionStoreDependency() throws {
        let repoRoot = repoRootURL()
        let targetDirectories = [
            repoRoot.appendingPathComponent("ClaudeIsland/Models/Canonical"),
            repoRoot.appendingPathComponent("ClaudeIsland/Services/Projection"),
            repoRoot.appendingPathComponent("ClaudeIsland/UI/State")
        ]

        try assertNoForbiddenTokens(
            in: targetDirectories,
            forbiddenTokens: ["SessionStore", "SessionEvent"]
        )
    }

    func testProjectionAndModernUIStateDoNotBridgeBackToLegacyCarriers() throws {
        let repoRoot = repoRootURL()
        let targetFiles = [
            repoRoot.appendingPathComponent("ClaudeIsland/Services/Projection/SessionProjectionStore.swift"),
            repoRoot.appendingPathComponent("ClaudeIsland/Services/Projection/CompatibilityStateProjector.swift"),
            repoRoot.appendingPathComponent("ClaudeIsland/UI/State/ProjectedUIStateStore.swift")
        ]

        try assertNoForbiddenTokens(
            inFiles: targetFiles,
            forbiddenTokens: [
                "SessionState",
                "ChatHistoryItem",
                "SessionInteractionRequest",
                "PermissionContext"
            ]
        )
    }

    func testSessionProjectionStorePublishSnapshotDoesNotInvokePhase0Diagnostics() throws {
        let repoRoot = repoRootURL()
        let storeFile = repoRoot.appendingPathComponent(
            "ClaudeIsland/Services/Projection/SessionProjectionStore.swift"
        )
        let content = try String(contentsOf: storeFile, encoding: .utf8)

        let methodStart = try XCTUnwrap(content.range(of: "    private func publishSnapshot() {"))
        let methodBody = String(content[methodStart.lowerBound...])

        XCTAssertFalse(
            methodBody.contains("ShadowDiffLogger"),
            "publishSnapshot() must not call ShadowDiffLogger."
        )
        XCTAssertFalse(
            methodBody.contains("ParityLogger"),
            "publishSnapshot() must not call ParityLogger."
        )
    }

    func testProjectionBootstrapOwnsShadowDiffRegistrationInsteadOfStore() throws {
        let repoRoot = repoRootURL()
        let bootstrapFile = repoRoot.appendingPathComponent(
            "ClaudeIsland/Services/Projection/ProjectionBootstrap.swift"
        )
        let content = try String(contentsOf: bootstrapFile, encoding: .utf8)

        XCTAssertTrue(
            content.contains("ShadowDiffLogger.updateProjectedSnapshot"),
            "ProjectionBootstrap must register projected parity snapshots for Phase 0 shadow diff."
        )
    }

    func testAppDelegateTerminationStopsLiveIngressCoordinator() throws {
        let repoRoot = repoRootURL()
        let appDelegateFile = repoRoot.appendingPathComponent("ClaudeIsland/App/AppDelegate.swift")
        let content = try String(contentsOf: appDelegateFile, encoding: .utf8)

        XCTAssertTrue(
            content.contains("AgentEventCoordinator.shared.stop()"),
            "AppDelegate termination path must stop the live ingress coordinator."
        )
    }

    func testCurrentMainPathDoesNotReferencePhase2PlusCutoverSymbols() throws {
        let repoRoot = repoRootURL()
        let targetFiles = [
            repoRoot.appendingPathComponent("ClaudeIsland/App/AppDelegate.swift"),
            repoRoot.appendingPathComponent("ClaudeIsland/Services/Session/ClaudeSessionMonitor.swift"),
            repoRoot.appendingPathComponent("ClaudeIsland/UI/Views/NotchView.swift"),
            repoRoot.appendingPathComponent("ClaudeIsland/UI/Views/ClaudeInstancesView.swift"),
            repoRoot.appendingPathComponent("ClaudeIsland/UI/Views/ChatView.swift"),
            repoRoot.appendingPathComponent("ClaudeIsland/UI/Window/NotchViewController.swift")
        ]

        let forbiddenTokens = [
            "Phase1RuntimeController",
            "ProjectionSessionCompatibility",
            "ProjectedFixtureRootView",
            "AppBootstrapMode",
            "CanonicalCommandEnvelope"
        ]

        for fileURL in targetFiles {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            for token in forbiddenTokens {
                XCTAssertFalse(content.contains(token), "Unexpected \(token) reference in \(fileURL.path)")
            }
        }
    }

    func testCurrentMainPathReadsDoNotUseLegacySessionPublishersOrChatHistoryManager() throws {
        let repoRoot = repoRootURL()
        let targetFiles = [
            repoRoot.appendingPathComponent("ClaudeIsland/Services/Session/ClaudeSessionMonitor.swift"),
            repoRoot.appendingPathComponent("ClaudeIsland/UI/Views/ChatView.swift")
        ]

        let forbiddenTokens = [
            "SessionStore.shared.sessionsPublisher",
            "ChatHistoryManager.shared"
        ]

        for fileURL in targetFiles {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            for token in forbiddenTokens {
                XCTAssertFalse(content.contains(token), "Unexpected \(token) reference in \(fileURL.path)")
            }
        }
    }

    func testPurePhase1BranchDoesNotContainLaterPhaseRuntimeCutoverFiles() {
        let repoRoot = repoRootURL()
        let removedPaths = [
            "ClaudeIsland/Services/EventBus/Phase1RuntimeController.swift",
            "ClaudeIsland/Services/EventBus/ProcessSessionDiscovery.swift",
            "ClaudeIsland/Services/EventBus/RuntimeSessionContextStore.swift",
            "ClaudeIsland/Services/Projection/ProjectionSessionCompatibility.swift",
            "ClaudeIsland/UI/Views/ProjectedFixtureRootView.swift"
        ]

        for relativePath in removedPaths {
            let fileURL = repoRoot.appendingPathComponent(relativePath)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "Unexpected later-phase file at \(fileURL.path)")
        }
    }

    private func repoRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func assertNoForbiddenTokens(
        in directories: [URL],
        forbiddenTokens: [String]
    ) throws {
        let fileManager = FileManager.default
        var inspectedFiles: [URL] = []

        for directory in directories {
            let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: nil
            )
            while let fileURL = enumerator?.nextObject() as? URL {
                guard fileURL.pathExtension == "swift" else { continue }
                inspectedFiles.append(fileURL)
                let content = try String(contentsOf: fileURL, encoding: .utf8)
                for token in forbiddenTokens {
                    XCTAssertFalse(content.contains(token), "Unexpected \(token) reference in \(fileURL.path)")
                }
            }
        }

        XCTAssertFalse(inspectedFiles.isEmpty)
    }

    private func assertNoForbiddenTokens(
        inFiles files: [URL],
        forbiddenTokens: [String]
    ) throws {
        for fileURL in files {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            for token in forbiddenTokens {
                XCTAssertFalse(content.contains(token), "Unexpected \(token) reference in \(fileURL.path)")
            }
        }
    }
}
