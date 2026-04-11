import XCTest

final class ClaudeIslandUITests: XCTestCase {
    private let uiTimeout: TimeInterval = 20
    private let fixtureTimestamp = "2026-04-05T03:00:00.000Z"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testProjectedFixtureLaunchShowsEmptyInstancesState() throws {
        let app = try launchApp(withFixtureJSON: emptyFixtureJSON())

        assertExists(app.staticTexts["No sessions"])
        assertExists(app.staticTexts["Run claude, codex, or gemini"])
    }

    func testProjectedFixtureLaunchShowsPopulatedInstancesState() throws {
        let app = try launchApp(withFixtureJSON: populatedInstancesFixtureJSON())

        assertExists(app.otherElements["session.prompt.conversation-list"])
    }

    func testProjectedFixtureLaunchShowsPopulatedChatState() throws {
        let app = try launchApp(
            withFixtureJSON: populatedChatFixtureJSON(),
            bootSessionID: "conversation-chat"
        )

        assertExists(app.staticTexts["Hello from fixture user"])
        assertExists(app.staticTexts["Hello from fixture assistant"])
        assertExists(app.staticTexts["Bash"])
        assertExists(app.textFields["Open Claude Code in tmux to enable messaging"])
    }

    func testProjectedFixtureLaunchShowsApprovalInteractionInChat() throws {
        let app = try launchApp(
            withFixtureJSON: approvalFixtureJSON(),
            bootSessionID: "conversation-approval"
        )

        assertExists(app.buttons["Deny"])
        assertExists(app.buttons["Allow"])
        assertExists(app.buttons["Bypass"])
    }

    func testProjectedFixtureLaunchShowsChoiceInteractionInChat() throws {
        let app = try launchApp(
            withFixtureJSON: choiceFixtureJSON(),
            bootSessionID: "conversation-choice"
        )

        assertExists(app.buttons["Ship"])
        assertExists(app.buttons["Hold"])
    }

    private func launchApp(
        withFixtureJSON json: String,
        bootSessionID: String? = nil
    ) throws -> XCUIApplication {
        let fixtureURL = try writeFixture(json: json)
        let app = configuredApp(fixtureURL: fixtureURL, bootSessionID: bootSessionID)
        app.launch()
        return app
    }

    private func configuredApp(
        fixtureURL: URL,
        bootSessionID: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["CLAUDE_ISLAND_LAUNCH_MODE"] = "projected_fixture"
        app.launchEnvironment["CLAUDE_ISLAND_PROJECTION_FIXTURE_PATH"] = fixtureURL.path
        if let bootSessionID {
            app.launchEnvironment["CLAUDE_ISLAND_BOOT_SESSION_ID"] = bootSessionID
        }
        return app
    }

    private func assertExists(
        _ element: XCUIElement,
        timeout: TimeInterval? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout ?? uiTimeout),
            "Expected UI element \(element) to appear",
            file: file,
            line: line
        )
    }

    private func element(in app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    private func writeFixture(json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func emptyFixtureJSON() -> String {
        fixtureDocumentJSON(conversations: [], sessions: [])
    }

    private func populatedInstancesFixtureJSON() -> String {
        fixtureDocumentJSON(
            conversations: [
                """
                "conversation-list": {
                  "id": "conversation-list",
                  "adapterID": "claude-code",
                  "familyID": "claude",
                  "sourceKind": "hook",
                  "title": "List Fixture Session",
                  "cwd": "/tmp/list-fixture-session",
                  "status": "idle",
                  "lastTransition": "created",
                  "turn": {
                    "id": "turn-list",
                    "status": "in_progress"
                  },
                  "messages": [
                    {
                      "id": "message-list-user-1",
                      "turnID": "turn-list",
                      "role": "user",
                      "format": "markdown",
                      "text": "List fixture prompt",
                      "isFinal": true,
                      "sourceKind": "transcript",
                      "updatedAt": "\(fixtureTimestamp)"
                    }
                  ],
                  "tools": [
                    {
                      "id": "tool-list-1",
                      "name": "Bash",
                      "kind": "bash",
                      "input": {
                        "command": "echo list fixture"
                      },
                      "output": {
                        "text": "list fixture output"
                      },
                      "state": "completed",
                      "errorKind": null,
                      "updatedAt": "\(fixtureTimestamp)"
                    }
                  ],
                  "approvals": [],
                  "choices": [],
                  "plans": [],
                  "sessionCommandSubmissionStates": {},
                  "lastUpdatedAt": "\(fixtureTimestamp)"
                }
                """
            ],
            sessions: [sessionMetadataJSON(sessionID: "conversation-list")]
        )
    }

    private func populatedChatFixtureJSON() -> String {
        fixtureDocumentJSON(
            conversations: [
                """
                "conversation-chat": {
                  "id": "conversation-chat",
                  "adapterID": "claude-code",
                  "familyID": "claude",
                  "sourceKind": "hook",
                  "title": "Chat Fixture Session",
                  "cwd": "/tmp/chat-fixture-session",
                  "status": "idle",
                  "lastTransition": "created",
                  "turn": {
                    "id": "turn-chat",
                    "status": "in_progress"
                  },
                  "messages": [
                    {
                      "id": "message-user-1",
                      "turnID": "turn-chat",
                      "role": "user",
                      "format": "markdown",
                      "text": "Hello from fixture user",
                      "isFinal": true,
                      "sourceKind": "transcript",
                      "updatedAt": "2026-04-05T03:00:00.000Z"
                    },
                    {
                      "id": "message-assistant-1",
                      "turnID": "turn-chat",
                      "role": "assistant",
                      "format": "markdown",
                      "text": "Hello from fixture assistant",
                      "isFinal": true,
                      "sourceKind": "transcript",
                      "updatedAt": "2026-04-05T03:00:01.000Z"
                    }
                  ],
                  "tools": [
                    {
                      "id": "tool-chat-1",
                      "name": "Bash",
                      "kind": "bash",
                      "input": {
                        "command": "echo chat fixture"
                      },
                      "output": {
                        "text": "chat fixture output"
                      },
                      "state": "completed",
                      "errorKind": null,
                      "updatedAt": "2026-04-05T03:00:02.000Z"
                    }
                  ],
                  "approvals": [],
                  "choices": [],
                  "plans": [],
                  "sessionCommandSubmissionStates": {},
                  "lastUpdatedAt": "2026-04-05T03:00:02.000Z"
                }
                """
            ],
            sessions: [sessionMetadataJSON(sessionID: "conversation-chat")]
        )
    }

    private func approvalFixtureJSON() -> String {
        fixtureDocumentJSON(
            conversations: [
                """
                "conversation-approval": {
                  "id": "conversation-approval",
                  "adapterID": "claude-code",
                  "familyID": "claude",
                  "sourceKind": "hook",
                  "title": "Approval Fixture Session",
                  "cwd": "/tmp/approval-fixture-session",
                  "status": "idle",
                  "lastTransition": "created",
                  "turn": {
                    "id": "turn-approval",
                    "status": "in_progress"
                  },
                  "messages": [
                    {
                      "id": "message-approval-user-1",
                      "turnID": "turn-approval",
                      "role": "user",
                      "format": "markdown",
                      "text": "Run the risky command",
                      "isFinal": true,
                      "sourceKind": "transcript",
                      "updatedAt": "\(fixtureTimestamp)"
                    }
                  ],
                  "tools": [
                    {
                      "id": "tool-approval-1",
                      "name": "Bash",
                      "kind": "bash",
                      "input": {
                        "command": "rm -rf /tmp/approval-fixture"
                      },
                      "output": {},
                      "state": "started",
                      "errorKind": null,
                      "updatedAt": "\(fixtureTimestamp)"
                    }
                  ],
                  "approvals": [
                    {
                      "id": "approval-1",
                      "toolID": "tool-approval-1",
                      "kind": "tool",
                      "reason": "Permission required",
                      "options": ["allow_once", "deny", "cancel"],
                      "scope": "once",
                      "strength": "strong",
                      "domainState": "requested",
                      "submissionState": "idle",
                      "resolvedBy": null,
                      "updatedAt": "\(fixtureTimestamp)"
                    }
                  ],
                  "choices": [],
                  "plans": [],
                  "sessionCommandSubmissionStates": {},
                  "lastUpdatedAt": "\(fixtureTimestamp)"
                }
                """
            ],
            sessions: [sessionMetadataJSON(sessionID: "conversation-approval")]
        )
    }

    private func choiceFixtureJSON() -> String {
        fixtureDocumentJSON(
            conversations: [
                """
                "conversation-choice": {
                  "id": "conversation-choice",
                  "adapterID": "claude-code",
                  "familyID": "claude",
                  "sourceKind": "hook",
                  "title": "Choice Fixture Session",
                  "cwd": "/tmp/choice-fixture-session",
                  "status": "idle",
                  "lastTransition": "created",
                  "turn": {
                    "id": "turn-choice",
                    "status": "in_progress"
                  },
                  "messages": [],
                  "tools": [],
                  "approvals": [],
                  "choices": [
                    {
                      "id": "choice-1",
                      "toolID": "choice-tool-1",
                      "kind": "options",
                      "prompt": "Choose deployment",
                      "schema": {},
                      "options": ["Ship", "Hold"],
                      "domainState": "requested",
                      "submissionState": "idle",
                      "submittedBy": null,
                      "resolvedBy": null,
                      "valueShape": "options",
                      "updatedAt": "\(fixtureTimestamp)"
                    }
                  ],
                  "plans": [],
                  "sessionCommandSubmissionStates": {},
                  "lastUpdatedAt": "\(fixtureTimestamp)"
                }
                """
            ],
            sessions: [sessionMetadataJSON(sessionID: "conversation-choice")]
        )
    }

    private func fixtureDocumentJSON(conversations: [String], sessions: [String]) -> String {
        let conversationsBlock = conversations.joined(separator: ",\n")
        let sessionsBlock = sessions.joined(separator: ",\n")

        return """
        {
          "snapshot": {
            "conversations": {
              \(conversationsBlock)
            },
            "capabilities": {}
          },
          "sessions": [
            \(sessionsBlock)
          ]
        }
        """
    }

    private func sessionMetadataJSON(sessionID: String) -> String {
        """
        {
          "session_id": "\(sessionID)",
          "agent_id": "claude",
          "pid": null,
          "tty": null,
          "is_in_tmux": false,
          "last_activity": "\(fixtureTimestamp)",
          "created_at": "\(fixtureTimestamp)"
        }
        """
    }
}
