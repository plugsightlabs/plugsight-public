// RefreshCoordinator.swift
//
// The lightweight refresh signal between the live event stream and the main
// window's view models. The stream calls `signal()` for every relevant event;
// the coordinator debounces (~1 s trailing edge) and bumps `tick`, which
// MainWindowView observes to reload Timeline/Devices/Settings. This kills the
// load-once-and-freeze pattern without turning every daemon event into an
// immediate triple reload during a burst.

import Foundation
import Combine

@MainActor
public final class RefreshCoordinator: ObservableObject {
    /// Monotonic counter; each bump means "something changed, reload".
    @Published public private(set) var tick: Int = 0

    private let debounceSeconds: Double
    private var pending: Task<Void, Never>?

    public init(debounceSeconds: Double = 1.0) {
        self.debounceSeconds = debounceSeconds
    }

    /// Ask for a refresh. Calls inside the debounce window coalesce into one tick.
    public func signal() {
        guard pending == nil else { return }
        pending = Task { [debounceSeconds] in
            try? await Task.sleep(nanoseconds: UInt64(debounceSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            pending = nil
            tick += 1
        }
    }

    /// Cancel any pending tick (window closing, teardown).
    public func cancelPending() {
        pending?.cancel()
        pending = nil
    }
}
