// OnboardingFlowController.swift
//
// The RUNTIME wiring of N11's pure state machine onto N10's render surface: an
// observable object the live onboarding window binds to. Every user gesture is a
// machine transition followed by a re-projection through asRenderState(), so the
// window renders exactly what the tested machine says and nothing else. The
// completion callback fires ONCE, when the walk finishes, so the host (the app
// shell) can record first-run completion. Fully CI-testable with the fakes in
// Testing/ — no TCC, SMAppService, or window required.

import Combine
import Foundation
import SwiftUI

@MainActor
public final class OnboardingFlowController: ObservableObject {
    @Published public private(set) var renderState: OnboardingState

    private let machine: OnboardingStateMachine
    private let onCompleted: () -> Void
    private var completionDelivered = false

    public init(machine: OnboardingStateMachine, onCompleted: @escaping () -> Void = {}) {
        self.machine = machine
        self.onCompleted = onCompleted
        self.renderState = machine.state.asRenderState()
    }

    public var isComplete: Bool { machine.state.isComplete }

    /// The step's primary button (Get started / Grant / Activate). "Try again"
    /// on a waiting step is the same transition, so it shares this.
    public func primaryAction() { machine.requestCurrentGrant(); sync() }

    /// Skip: available on every step, never punished (04).
    public func skip() { machine.skipCurrent(); sync() }

    /// Live re-check while a step waits for System Settings (04: grants land
    /// without another click). Driven on a heartbeat by the hosting view.
    public func poll() { machine.poll(); sync() }

    private func sync() {
        renderState = machine.state.asRenderState()
        if machine.state.isComplete && !completionDelivered {
            completionDelivered = true
            onCompleted()
        }
    }
}

/// The live onboarding surface: N10's OnboardingView bound to the controller,
/// with a 1s heartbeat driving poll() so grants landing in System Settings
/// complete their step without another click.
public struct OnboardingFlowView: View {
    @ObservedObject private var controller: OnboardingFlowController
    private let heartbeat = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    public init(controller: OnboardingFlowController) { self.controller = controller }

    public var body: some View {
        OnboardingView(
            state: controller.renderState,
            actions: OnboardingActions(
                primary: { controller.primaryAction() },
                skip: { controller.skip() },
                tryAgain: { controller.primaryAction() }))
            .onReceive(heartbeat) { _ in
                if !controller.isComplete { controller.poll() }
            }
    }
}
