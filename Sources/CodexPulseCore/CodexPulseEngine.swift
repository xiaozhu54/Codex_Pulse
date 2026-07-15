import Foundation

public enum CodexPulseError: Error, Equatable {
    case codexHomeUnavailable
}

public final class CodexPulseEngine {
    private let codexHome: URL
    private let fileManager: FileManager
    private let speedTracker: LogSpeedTracker
    private let sessionCache = SessionCache()
    private let threadIndexReader: ThreadIndexReader

    public init(codexHome: URL, fileManager: FileManager = .default) {
        self.codexHome = codexHome.standardizedFileURL
        self.fileManager = fileManager
        self.speedTracker = LogSpeedTracker(codexHome: codexHome.standardizedFileURL)
        self.threadIndexReader = ThreadIndexReader(codexHome: codexHome.standardizedFileURL)
    }

    public func snapshot(
        codexRunning: Bool,
        preferences: PulsePreferences,
        now: Date = Date()
    ) throws -> StatusSnapshot {
        guard codexRunning else { return .hidden }
        guard fileManager.fileExists(atPath: codexHome.path) else {
            throw CodexPulseError.codexHomeUnavailable
        }

        let sessions = try discoverSessions(pinnedSessionID: preferences.pinnedSessionID)
        let weekly = sessions
            .filter { $0.weeklyRemaining != nil }
            .max { left, right in
                if left.weeklyIsCodex != right.weeklyIsCodex { return !left.weeklyIsCodex }
                return (left.weeklyUpdatedAt ?? .distantPast) < (right.weeklyUpdatedAt ?? .distantPast)
            }
        let selected: SessionState?
        if let pinned = preferences.pinnedSessionID {
            guard let pinnedState = sessions.first(where: { $0.id == pinned }) else {
                return StatusSnapshot(
                    visibility: .idle,
                    weeklyRemainingPercent: weekly?.weeklyRemaining,
                    weeklyResetsAt: weekly?.weeklyResetsAt,
                    sessionID: pinned,
                    selectionMode: .pinnedUnavailable,
                    stage: .unavailable,
                    dynamicIconEnabled: preferences.dynamicIconEnabled
                )
            }
            selected = pinnedState
        } else {
            selected = sessions.max {
                ($0.latestTaskEventAt ?? .distantPast) < ($1.latestTaskEventAt ?? .distantPast)
            }
        }

        guard let selected else {
            return StatusSnapshot(
                visibility: .idle,
                weeklyRemainingPercent: weekly?.weeklyRemaining,
                weeklyResetsAt: weekly?.weeklyResetsAt,
                dynamicIconEnabled: preferences.dynamicIconEnabled
            )
        }

        let speed = selected.active
            ? speedTracker.speed(threadID: selected.id, now: now)
            : .unavailable
        return selected.snapshot(
            selectionMode: preferences.pinnedSessionID == nil ? .automatic : .pinned,
            dynamicIconEnabled: preferences.dynamicIconEnabled,
            tokenSpeed: speed,
            weeklyRemaining: weekly?.weeklyRemaining,
            weeklyResetsAt: weekly?.weeklyResetsAt
        )
    }

    public func availableSessions(pinnedSessionID: String? = nil) throws -> [SessionSummary] {
        try discoverSessions(pinnedSessionID: pinnedSessionID)
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { state in
                let title = state.title.flatMap { $0.isEmpty ? nil : $0 } ?? "未命名会话"
                return SessionSummary(
                    id: state.id,
                    title: title,
                    model: state.model,
                    isActive: state.active,
                    updatedAt: state.updatedAt
                )
            }
    }

    private func discoverSessions(pinnedSessionID: String?) throws -> [SessionState] {
        let sessionsRoot = codexHome.appendingPathComponent("sessions", isDirectory: true)
        let threadIndex = threadIndexReader.load()
        if !threadIndex.isEmpty {
            let uniqueMetadata = Dictionary(
                threadIndex.values.map { ($0.id, $0) },
                uniquingKeysWith: { current, _ in current }
            )
            var candidates = uniqueMetadata.values
                .filter { !$0.isInternal }
                .sorted { $0.updatedAt > $1.updatedAt }
            if candidates.count > 64 {
                let recent = Array(candidates.prefix(64))
                if let pinnedSessionID,
                   let pinned = uniqueMetadata[pinnedSessionID],
                   !recent.contains(where: { $0.id == pinnedSessionID }) {
                    candidates = recent + [pinned]
                } else {
                    candidates = recent
                }
            }

            var states: [SessionState] = []
            for metadata in candidates {
                let url = URL(fileURLWithPath: metadata.rolloutPath)
                guard fileManager.fileExists(atPath: url.path),
                      var state = try sessionCache.state(for: url)
                else { continue }
                state.apply(metadata: metadata)
                states.append(state)
            }
            return states.filter { !$0.isInternal && ($0.hasRecognizableTaskEvent || $0.id == pinnedSessionID) }
        }

        guard let enumerator = fileManager.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var states: [SessionState] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            if var state = try sessionCache.state(for: url) {
                if let metadata = threadIndex[state.id] ?? threadIndex[url.standardizedFileURL.path] {
                    state.apply(metadata: metadata)
                }
                states.append(state)
            }
        }
        return states.filter { !$0.isInternal && ($0.hasRecognizableTaskEvent || $0.id == pinnedSessionID) }
    }
}
