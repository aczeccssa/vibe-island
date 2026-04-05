//
//  AdapterCapabilitySnapshot.swift
//  ClaudeIsland
//
//  Phase 1 adapter capability contracts.
//

import Foundation

enum CanonicalSemanticArea: String, CaseIterable, Codable, Sendable {
    case conversationLifecycle = "conversation_lifecycle"
    case messageDelta = "message_delta"
    case messageFinal = "message_final"
    case toolLifecycle = "tool_lifecycle"
    case approvalRequest = "approval_request"
    case approvalResolution = "approval_resolution"
    case userChoiceRequest = "user_choice_request"
    case userChoiceSubmission = "user_choice_submission"
    case userChoiceResolution = "user_choice_resolution"
    case planUpdates = "plan_updates"
    case sessionFocus = "session_focus"
    case sessionArchive = "session_archive"
    case sessionInterrupt = "session_interrupt"
    case sessionClear = "session_clear"
    case desktopFocusVisibilityAssist = "desktop_focus_visibility_assist"

    static let requiredSessionControlAreas: Set<CanonicalSemanticArea> = [
        .sessionFocus,
        .sessionArchive,
        .sessionInterrupt,
        .sessionClear
    ]
}

enum AdapterCapabilityLevel: String, Codable, Sendable {
    case authoritative
    case desktopFallback = "desktop_fallback"
    case observableOnly = "observable_only"
    case syntheticHint = "synthetic_hint"
    case unsupported
}

enum AdapterCapabilitySource: String, Codable, Sendable {
    case api
    case stream
    case hook
    case transcript
    case replay
    case accessibility
    case synthetic
    case localState = "local_state"
    case none
}

enum AdapterCapabilityControl: String, Codable, Sendable {
    case programmatic
    case synchronousHook = "synchronous_hook"
    case localFallback = "local_fallback"
    case none
}

struct AdapterCapabilitySnapshot: Codable, Equatable, Sendable {
    let adapterID: RuntimeAdapterID
    let semanticArea: CanonicalSemanticArea
    let level: AdapterCapabilityLevel
    let source: AdapterCapabilitySource
    let control: AdapterCapabilityControl
    let notes: String?

    private enum CodingKeys: String, CodingKey {
        case adapterID = "adapter_id"
        case semanticArea = "semantic_area"
        case level
        case source
        case control
        case notes
    }
}
