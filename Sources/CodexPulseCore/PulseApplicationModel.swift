import Foundation

public struct PulseApplicationUpdate: Equatable, Sendable {
    public let viewState: PulseViewState
    public let shouldRefresh: Bool
    public let refreshInterval: TimeInterval?
    public let shouldTerminate: Bool

    public init(
        viewState: PulseViewState,
        shouldRefresh: Bool,
        refreshInterval: TimeInterval?,
        shouldTerminate: Bool
    ) {
        self.viewState = viewState
        self.shouldRefresh = shouldRefresh
        self.refreshInterval = refreshInterval
        self.shouldTerminate = shouldTerminate
    }
}

/// Pure application state machine shared by AppDelegate and behavior tests.
/// System adapters translate NSWorkspace/FSEvents into these small inputs; the
/// model owns the final PulseViewState that AppKit and SwiftUI render.
public struct PulseApplicationModel: Sendable {
    public private(set) var state: PulseState = .hidden
    public private(set) var codexRunning = false

    public init() {}

    public mutating func lifecycleChanged(
        codexRunning: Bool,
        preferences: PulsePreferences,
        codexHomePath: String,
        launchMonitorStatus: LaunchMonitorStatus,
        now: Date = Date()
    ) -> PulseApplicationUpdate {
        self.codexRunning = codexRunning
        state = codexRunning
            ? PulseState(
                snapshot: StatusSnapshot(visibility: .idle, stage: .idle),
                sessions: [],
                sourceHealth: .unavailable
            )
            : .hidden
        return update(
            preferences: preferences,
            codexHomePath: codexHomePath,
            launchMonitorStatus: launchMonitorStatus,
            now: now,
            shouldRefresh: codexRunning,
            shouldTerminate: !codexRunning
        )
    }

    public mutating func accepted(
        _ state: PulseState,
        preferences: PulsePreferences,
        codexHomePath: String,
        launchMonitorStatus: LaunchMonitorStatus,
        now: Date = Date()
    ) -> PulseApplicationUpdate {
        self.state = state
        return update(
            preferences: preferences,
            codexHomePath: codexHomePath,
            launchMonitorStatus: launchMonitorStatus,
            now: now,
            shouldRefresh: false,
            shouldTerminate: false
        )
    }

    public func presented(
        preferences: PulsePreferences,
        codexHomePath: String,
        launchMonitorStatus: LaunchMonitorStatus,
        now: Date = Date()
    ) -> PulseViewState {
        PulsePresenter.present(
            state: state,
            preferences: preferences,
            now: now,
            codexHomePath: codexHomePath,
            launchMonitorStatus: launchMonitorStatus
        )
    }

    public var shouldRefreshForFileEvent: Bool {
        codexRunning && state.snapshot.visibility != .active
    }

    private func update(
        preferences: PulsePreferences,
        codexHomePath: String,
        launchMonitorStatus: LaunchMonitorStatus,
        now: Date,
        shouldRefresh: Bool,
        shouldTerminate: Bool
    ) -> PulseApplicationUpdate {
        PulseApplicationUpdate(
            viewState: presented(
                preferences: preferences,
                codexHomePath: codexHomePath,
                launchMonitorStatus: launchMonitorStatus,
                now: now
            ),
            shouldRefresh: shouldRefresh,
            refreshInterval: PulseRefreshPolicy.interval(
                codexRunning: codexRunning,
                visibility: state.snapshot.visibility
            ),
            shouldTerminate: shouldTerminate
        )
    }
}
