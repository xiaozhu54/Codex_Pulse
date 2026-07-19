import Foundation

struct CodexObservationBatch {
    let allSessions: [SessionState]
    let selectableSessions: [SessionState]
    let responseMetrics: [String: MetricValue<TokenSpeed>]
    let sourceHealth: SourceHealth
}

final class CodexObservationRepository {
    private let codexHome: URL
    private let fileManager: FileManager
    private let sessionCache = SessionCache()
    private let threadIndexReader: ThreadIndexReader
    private let responseLogAdapter: ResponseLogAdapter

    init(codexHome: URL, fileManager: FileManager = .default) {
        self.codexHome = codexHome.standardizedFileURL
        self.fileManager = fileManager
        self.threadIndexReader = ThreadIndexReader(codexHome: codexHome.standardizedFileURL)
        self.responseLogAdapter = ResponseLogAdapter(codexHome: codexHome.standardizedFileURL)
    }

    func refresh(pinnedSessionID: String?, now: Date) throws -> CodexObservationBatch {
        guard fileManager.fileExists(atPath: codexHome.path) else {
            throw CodexPulseError.codexHomeUnavailable
        }
        let (allSessions, sessionStatus) = try discoverSessions(pinnedSessionID: pinnedSessionID)
        let selectable = allSessions.filter {
            !$0.isInternal && ($0.hasRecognizableTaskEvent || $0.id == pinnedSessionID)
        }
        let responseMetrics = responseLogAdapter.metrics(now: now)
        return CodexObservationBatch(
            allSessions: allSessions,
            selectableSessions: selectable,
            responseMetrics: responseMetrics,
            sourceHealth: SourceHealth(
                sessionJournal: sessionStatus,
                threadIndex: threadIndexReader.status,
                responseLog: responseLogAdapter.status
            )
        )
    }

    private func discoverSessions(pinnedSessionID: String?) throws -> ([SessionState], SourceStatus) {
        let sessionsRoot = codexHome.appendingPathComponent("sessions", isDirectory: true)
        let threadIndex = threadIndexReader.load(pinnedSessionID: pinnedSessionID)
        if !threadIndex.isEmpty {
            let uniqueMetadata = Dictionary(
                threadIndex.values.map { ($0.id, $0) },
                uniquingKeysWith: { current, _ in current }
            )
            var states: [SessionState] = []
            var hadReadFailure = false
            for metadata in uniqueMetadata.values.sorted(by: { $0.updatedAt > $1.updatedAt }) {
                let url = URL(fileURLWithPath: metadata.rolloutPath)
                guard fileManager.fileExists(atPath: url.path) else {
                    hadReadFailure = true
                    continue
                }
                do {
                    guard var state = try sessionCache.state(for: url) else { continue }
                    state.apply(metadata: metadata)
                    states.append(state)
                } catch {
                    hadReadFailure = true
                }
            }
            let observedAt = states.map(\.updatedAt).max()
            return (
                states,
                SourceStatus(
                    availability: hadReadFailure ? (states.isEmpty ? .unavailable : .stale) : .available,
                    observedAt: observedAt,
                    issue: hadReadFailure ? .readFailed : nil
                )
            )
        }

        guard let enumerator = fileManager.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return ([], SourceStatus(availability: .unavailable, issue: .missing))
        }
        var states: [SessionState] = []
        var hadReadFailure = false
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            do {
                if var state = try sessionCache.state(for: url) {
                    if let metadata = threadIndex[state.id] ?? threadIndex[url.standardizedFileURL.path] {
                        state.apply(metadata: metadata)
                    }
                    states.append(state)
                }
            } catch {
                hadReadFailure = true
            }
        }
        return (
            states,
            SourceStatus(
                availability: hadReadFailure ? (states.isEmpty ? .unavailable : .stale) : .available,
                observedAt: states.map(\.updatedAt).max(),
                issue: hadReadFailure ? .readFailed : nil
            )
        )
    }
}
