//
//  NotchViewController.swift
//  ClaudeIsland
//
//  Hosts the SwiftUI NotchView in AppKit with click-through support
//

import AppKit
import SwiftUI

/// Custom NSHostingView that only accepts mouse events within the panel bounds.
/// Clicks outside the panel pass through to windows behind.
class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    var hitTestRect: () -> CGRect = { .zero }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localRect = hitTestRect()
        // Only accept hits within the panel rect
        guard localRect.contains(point) else {
            return nil  // Pass through to windows behind
        }
        return super.hitTest(point)
    }
}

class NotchViewController: NSViewController {
    private let viewModel: NotchViewModel
    private var hostingView: NSView!

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        if ProjectionLaunchMode.current.isFixture {
            hostingView = NSHostingView(rootView: FixtureWindowRootView(viewModel: viewModel))
            self.view = hostingView
            return
        }

        let passThroughHostingView = PassThroughHostingView(rootView: NotchView(viewModel: viewModel))
        hostingView = passThroughHostingView

        // Calculate the hit-test rect based on panel state
        passThroughHostingView.hitTestRect = { [weak self] in
            guard let self = self else { return .zero }
            let vm = self.viewModel
            let geometry = vm.geometry

            // Window-local coordinates: origin at bottom-left, Y increases upward.
            let windowHeight = geometry.windowHeight
            let windowWidth = geometry.screenRect.width

            switch vm.status {
            case .opened:
                let panelSize = vm.openedSize
                let panelWidth = panelSize.width + 52  // Account for corner radius padding
                let panelHeight = panelSize.height
                return CGRect(
                    x: (windowWidth - panelWidth) / 2,
                    y: windowHeight - panelHeight,
                    width: panelWidth,
                    height: panelHeight
                )
            case .popping:
                if vm.activeInteractionPop != nil {
                    let panelSize = vm.interactionPopSize
                    let panelWidth = panelSize.width + 52
                    let panelHeight = panelSize.height + 24
                    return CGRect(
                        x: (windowWidth - panelWidth) / 2,
                        y: windowHeight - panelHeight - 8,
                        width: panelWidth,
                        height: panelHeight
                    )
                }

                fallthrough
            case .closed:
                // When closed, use the notch rect
                let notchRect = geometry.deviceNotchRect
                // Add some padding for easier interaction
                return CGRect(
                    x: (windowWidth - notchRect.width) / 2 - 10,
                    y: windowHeight - notchRect.height - 5,
                    width: notchRect.width + 20,
                    height: notchRect.height + 10
                )
            }
        }

        self.view = hostingView
    }
}

private struct FixtureWindowRootView: View {
    @ObservedObject var viewModel: NotchViewModel
    @StateObject private var sessionMonitor = ClaudeSessionMonitor()

    var body: some View {
        Group {
            if let explicitChatSession = explicitChatSession {
                ChatView(
                    sessionId: explicitChatSession.sessionID,
                    initialSession: explicitChatSession,
                    sessionMonitor: sessionMonitor,
                    viewModel: viewModel
                )
                .accessibilityIdentifier("chat.view")
            } else {
                AgentInstancesView(
                    sessionMonitor: sessionMonitor,
                    viewModel: viewModel
                )
                .accessibilityIdentifier("instances.view")
            }
        }
        .frame(width: viewModel.openedSize.width, height: viewModel.openedSize.height)
        .padding(12)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .preferredColorScheme(.dark)
        .onAppear {
            viewModel.notchOpen(reason: .boot)
            sessionMonitor.startMonitoring()
        }
    }

    private var explicitChatSession: ProjectedSessionViewState? {
        if case .chat(let sessionID) = viewModel.contentType {
            return sessionMonitor.instances.first(where: { $0.sessionID == sessionID })
        }
        guard let sessionID = sessionMonitor.fixtureBootSessionID else {
            return nil
        }
        return sessionMonitor.instances.first(where: { $0.sessionID == sessionID })
    }
}
