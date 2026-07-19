import Foundation

public enum CodexPulseError: Error, Equatable {
    case codexHomeUnavailable
}

public final class CodexPulseEngine {
    private let repository: CodexObservationRepository

    public init(codexHome: URL, fileManager: FileManager = .default) {
        self.repository = CodexObservationRepository(codexHome: codexHome, fileManager: fileManager)
    }

    public func refresh(_ request: PulseRefreshRequest) throws -> PulseState {
        guard request.codexRunning else { return .hidden }
        let batch = try repository.refresh(
            pinnedSessionID: request.pinnedSessionID,
            now: request.now
        )
        let weeklyState = batch.allSessions
            .filter { $0.weeklyRemaining != nil }
            .sorted { left, right in
                if left.weeklyIsCodex != right.weeklyIsCodex { return left.weeklyIsCodex }
                return (left.weeklyUpdatedAt ?? .distantPast) > (right.weeklyUpdatedAt ?? .distantPast)
            }
            .first
        let weekly = MetricValue(
            value: weeklyState?.weeklyRemaining,
            availability: weeklyState?.weeklyRemaining == nil ? .unavailable : .available,
            observedAt: weeklyState?.weeklyUpdatedAt,
            source: .sessionJournal,
            issue: weeklyState?.weeklyRemaining == nil ? batch.sourceHealth.sessionJournal.issue : nil
        )
        let reset = MetricValue(
            value: weeklyState?.weeklyResetsAt,
            availability: weeklyState?.weeklyResetsAt == nil ? .unavailable : .available,
            observedAt: weeklyState?.weeklyUpdatedAt,
            source: .sessionJournal,
            issue: weeklyState?.weeklyResetsAt == nil ? batch.sourceHealth.sessionJournal.issue : nil
        )
        let sessions = summaries(batch.selectableSessions)

        let selected: SessionState?
        let selectionMode: SessionSelectionMode
        if let pinned = request.pinnedSessionID {
            selectionMode = batch.selectableSessions.contains(where: { $0.id == pinned })
                ? .pinned
                : .pinnedUnavailable
            selected = batch.selectableSessions.first(where: { $0.id == pinned })
        } else {
            selectionMode = .automatic
            selected = batch.selectableSessions.max {
                ($0.latestTaskEventAt ?? .distantPast) < ($1.latestTaskEventAt ?? .distantPast)
            }
        }

        guard let selected else {
            let snapshot = StatusSnapshot(
                visibility: .idle,
                weekly: weekly,
                weeklyResetsAt: reset,
                sessionID: request.pinnedSessionID,
                selectionMode: selectionMode,
                stage: selectionMode == .pinnedUnavailable ? .unavailable : .idle,
                updatedAt: weekly.observedAt
            )
            return PulseState(snapshot: snapshot, sessions: sessions, sourceHealth: batch.sourceHealth)
        }

        let speed = selected.active
            ? batch.responseMetrics[selected.id] ?? MetricValue(
                value: nil,
                availability: .unavailable,
                source: .responseLog,
                issue: batch.sourceHealth.responseLog.issue
            )
            : MetricValue<TokenSpeed>(
                value: nil,
                availability: .unavailable,
                source: .responseLog
            )
        let snapshot = selected.snapshot(
            selectionMode: selectionMode,
            tokenSpeed: speed,
            weekly: weekly,
            weeklyResetsAt: reset,
            // The selected SessionState exists only after its journal was read
            // successfully. A different broken journal must not stale otherwise
            // trustworthy fields from this session.
            sessionJournalStatus: .available,
            threadIndexStatus: batch.sourceHealth.threadIndex
        )
        return PulseState(snapshot: snapshot, sessions: sessions, sourceHealth: batch.sourceHealth)
    }

    private func summaries(_ states: [SessionState]) -> [SessionSummary] {
        states.sorted { $0.updatedAt > $1.updatedAt }.map { state in
            SessionSummary(
                id: state.id,
                title: state.title.flatMap { $0.isEmpty ? nil : $0 } ?? "未命名会话",
                model: state.model,
                isActive: state.active,
                updatedAt: state.updatedAt
            )
        }
    }

}
