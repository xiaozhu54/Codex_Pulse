import Foundation

public actor PulseRuntime {
    private let engine: CodexPulseEngine

    public init(codexHome: URL) {
        self.engine = CodexPulseEngine(codexHome: codexHome)
    }

    public func refresh(_ request: PulseRefreshRequest) -> PulseState {
        do {
            return try engine.refresh(request)
        } catch {
            let selection: SessionSelectionMode = request.pinnedSessionID == nil
                ? .automatic
                : .pinnedUnavailable
            return PulseState(
                snapshot: StatusSnapshot(
                    visibility: request.codexRunning ? .idle : .hidden,
                    sessionID: request.pinnedSessionID,
                    selectionMode: selection,
                    stage: .unavailable,
                    updatedAt: request.now
                ),
                sessions: [],
                sourceHealth: .unavailable
            )
        }
    }
}
