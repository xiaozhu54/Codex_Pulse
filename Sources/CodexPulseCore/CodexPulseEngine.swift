import Foundation

public enum CodexPulseError: Error, Equatable {
    case codexHomeUnavailable
}

public final class CodexPulseEngine {
    private let codexHome: URL
    private let fileManager: FileManager
    private let speedTracker: LogSpeedTracker
    private let sessionCache = SessionCache()

    public init(codexHome: URL, fileManager: FileManager = .default) {
        self.codexHome = codexHome.standardizedFileURL
        self.fileManager = fileManager
        self.speedTracker = LogSpeedTracker(codexHome: codexHome.standardizedFileURL)
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
        let selected: SessionState?
        if let pinned = preferences.pinnedSessionID {
            guard let pinnedState = sessions.first(where: { $0.id == pinned }) else {
                return StatusSnapshot(
                    visibility: .idle,
                    sessionID: pinned,
                    selectionMode: .pinnedUnavailable,
                    stage: .unavailable,
                    dynamicIconEnabled: preferences.dynamicIconEnabled
                )
            }
            selected = pinnedState
        } else {
            selected = sessions.max(by: { $0.updatedAt < $1.updatedAt })
        }

        guard let selected else {
            return StatusSnapshot(
                visibility: .idle,
                dynamicIconEnabled: preferences.dynamicIconEnabled
            )
        }

        let speed = selected.active
            ? speedTracker.speed(threadID: selected.id, now: now)
            : .unavailable
        return selected.snapshot(
            selectionMode: preferences.pinnedSessionID == nil ? .automatic : .pinned,
            dynamicIconEnabled: preferences.dynamicIconEnabled,
            tokenSpeed: speed
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
        let threadIndex = ThreadIndexReader.load(from: codexHome)
        if !threadIndex.isEmpty {
            let uniqueMetadata = Dictionary(
                threadIndex.values.map { ($0.id, $0) },
                uniquingKeysWith: { current, _ in current }
            )
            var candidates = uniqueMetadata.values
                .filter { !$0.isInternal }
                .sorted { $0.updatedAt > $1.updatedAt }
            if candidates.count > 16 {
                let recent = Array(candidates.prefix(16))
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
            return states.filter { !$0.isInternal }
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
        return states.filter { !$0.isInternal }
    }
}

private final class SessionCache {
    private struct Entry {
        let fileSize: Int
        let modificationDate: Date
        let state: SessionState
    }

    private var entries: [String: Entry] = [:]

    func state(for url: URL) throws -> SessionState? {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let fileSize = values.fileSize ?? 0
        let modificationDate = values.contentModificationDate ?? .distantPast
        let key = url.standardizedFileURL.path
        if let cached = entries[key],
           cached.fileSize == fileSize,
           cached.modificationDate == modificationDate {
            return cached.state
        }
        guard let state = try SessionLogParser.parse(url: url) else { return nil }
        entries[key] = Entry(fileSize: fileSize, modificationDate: modificationDate, state: state)
        return state
    }
}

private struct SessionState {
    var id: String
    var title: String?
    var updatedAt: Date
    var active = false
    var stage: TaskStage = .idle
    var weeklyRemaining: Double?
    var weeklyResetsAt: Date?
    var model: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var contextWindow: Int?
    var indexedAsInternal = false

    var isInternal: Bool {
        if indexedAsInternal { return true }
        guard let model else { return false }
        return model.caseInsensitiveCompare("codex-auto-review") == .orderedSame
    }

    mutating func apply(metadata: ThreadMetadata) {
        title = metadata.title ?? title
        model = model ?? metadata.model
        indexedAsInternal = metadata.isInternal
        if metadata.updatedAt > updatedAt {
            updatedAt = metadata.updatedAt
        }
    }

    func snapshot(
        selectionMode: SessionSelectionMode,
        dynamicIconEnabled: Bool,
        tokenSpeed: TokenSpeed
    ) -> StatusSnapshot {
        let usedTokens: Int?
        if let inputTokens, let outputTokens {
            usedTokens = inputTokens + outputTokens
        } else {
            usedTokens = nil
        }

        let available: Double?
        if let usedTokens, let contextWindow, contextWindow > 0 {
            available = min(max((1 - Double(usedTokens) / Double(contextWindow)) * 100, 0), 100)
        } else {
            available = nil
        }

        let resolvedStage: TaskStage
        if !active {
            resolvedStage = .idle
        } else if [.usingTool, .waitingForTool, .waitingForApproval].contains(stage) {
            resolvedStage = stage
        } else {
            switch tokenSpeed.kind {
            case .estimating: resolvedStage = .generating
            case .thinking: resolvedStage = .thinking
            case .final: resolvedStage = .finishing
            case .unavailable: resolvedStage = stage
            }
        }

        return StatusSnapshot(
            visibility: active ? .active : .idle,
            weeklyRemainingPercent: weeklyRemaining,
            weeklyResetsAt: weeklyResetsAt,
            tokenSpeed: active && tokenSpeed.kind == .unavailable && stage == .thinking
                ? TokenSpeed(kind: .thinking)
                : tokenSpeed,
            model: model,
            contextAvailablePercent: available,
            contextUsedTokens: usedTokens,
            contextWindowTokens: contextWindow,
            sessionID: id,
            sessionTitle: title,
            selectionMode: selectionMode,
            stage: resolvedStage,
            updatedAt: updatedAt,
            dynamicIconEnabled: dynamicIconEnabled
        )
    }
}

private enum SessionLogParser {
    static func parse(url: URL) throws -> SessionState? {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let attributes = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        var state = SessionState(
            id: url.deletingPathExtension().lastPathComponent,
            updatedAt: attributes?.contentModificationDate ?? .distantPast
        )

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            if let timestamp = object["timestamp"] as? String,
               let date = parseTimestamp(timestamp) {
                state.updatedAt = max(state.updatedAt, date)
            }

            let type = object["type"] as? String
            let payload = object["payload"] as? [String: Any] ?? [:]
            switch type {
            case "session_meta":
                state.id = (payload["id"] as? String) ?? (payload["session_id"] as? String) ?? state.id
            case "turn_context":
                state.model = (payload["model"] as? String) ?? state.model
            case "event_msg":
                applyEvent(payload, to: &state)
            case "response_item":
                applyResponseItem(payload, to: &state)
            default:
                break
            }
        }
        return state
    }

    private static func applyEvent(_ payload: [String: Any], to state: inout SessionState) {
        switch payload["type"] as? String {
        case "task_started":
            state.active = true
            state.stage = .thinking
        case "task_complete", "task_failed", "task_cancelled", "turn_aborted":
            state.active = false
            state.stage = .idle
        case "token_count":
            applyTokenCount(payload, to: &state)
        default:
            if let eventType = payload["type"] as? String,
               eventType.localizedCaseInsensitiveContains("approval") {
                state.stage = .waitingForApproval
            }
            break
        }
    }

    private static func applyResponseItem(_ payload: [String: Any], to state: inout SessionState) {
        guard state.active else { return }
        switch payload["type"] as? String {
        case "custom_tool_call", "function_call", "mcp_tool_call":
            state.stage = .waitingForTool
        case "custom_tool_call_output", "function_call_output", "mcp_tool_call_output":
            state.stage = .thinking
        case "message":
            state.stage = .finishing
        default:
            break
        }
    }

    private static func applyTokenCount(_ payload: [String: Any], to state: inout SessionState) {
        if let info = payload["info"] as? [String: Any] {
            let usage = info["last_token_usage"] as? [String: Any]
            state.inputTokens = (usage?["input_tokens"] as? NSNumber)?.intValue ?? state.inputTokens
            state.outputTokens = (usage?["output_tokens"] as? NSNumber)?.intValue ?? state.outputTokens
            state.contextWindow = (info["model_context_window"] as? NSNumber)?.intValue ?? state.contextWindow
        }

        guard let rateLimits = payload["rate_limits"] as? [String: Any] else { return }
        let limitID = rateLimits["limit_id"] as? String
        let candidates = [rateLimits["primary"], rateLimits["secondary"]]
        for case let window as [String: Any] in candidates {
            guard (window["window_minutes"] as? NSNumber)?.intValue == 10_080 else { continue }
            if limitID == nil || limitID == "codex" {
                if let used = (window["used_percent"] as? NSNumber)?.doubleValue {
                    state.weeklyRemaining = min(max(100 - used, 0), 100)
                }
                if let reset = (window["resets_at"] as? NSNumber)?.doubleValue {
                    state.weeklyResetsAt = Date(timeIntervalSince1970: reset)
                }
            }
            break
        }
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
