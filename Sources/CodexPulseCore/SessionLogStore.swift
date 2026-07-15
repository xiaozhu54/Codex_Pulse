import Foundation

final class SessionCache {
    private struct Entry {
        var identity: String?
        var offset: UInt64
        var remainder = Data()
        var state: SessionState
    }

    private var entries: [String: Entry] = [:]

    func state(for url: URL) throws -> SessionState? {
        let key = url.standardizedFileURL.path
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .fileResourceIdentifierKey])
        let size = UInt64(values.fileSize ?? 0)
        let identity = values.fileResourceIdentifier.map { String(describing: $0) }
        var entry = entries[key] ?? Entry(
            identity: identity,
            offset: 0,
            state: SessionState(id: url.deletingPathExtension().lastPathComponent, updatedAt: .distantPast)
        )

        if entry.identity != identity || size < entry.offset {
            entry = Entry(
                identity: identity,
                offset: 0,
                state: SessionState(id: url.deletingPathExtension().lastPathComponent, updatedAt: .distantPast)
            )
        }
        guard size > entry.offset else {
            entries[key] = entry
            return entry.offset == 0 ? nil : entry.state
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: entry.offset)
        let newData = try handle.readToEnd() ?? Data()
        entry.offset += UInt64(newData.count)
        entry.remainder.append(newData)

        while let newline = entry.remainder.firstIndex(of: 0x0A) {
            let line = entry.remainder[..<newline]
            if !line.isEmpty { SessionLogParser.apply(Data(line), to: &entry.state) }
            entry.remainder.removeSubrange(...newline)
        }
        entries[key] = entry
        return entry.offset == 0 ? nil : entry.state
    }
}

struct SessionState {
    var id: String
    var title: String?
    var updatedAt: Date
    var latestTaskEventAt: Date?
    var active = false
    var stage: TaskStage = .idle
    var weeklyRemaining: Double?
    var weeklyResetsAt: Date?
    var weeklyUpdatedAt: Date?
    var weeklyIsCodex = false
    var model: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var contextWindow: Int?
    var indexedAsInternal = false

    var hasRecognizableTaskEvent: Bool { latestTaskEventAt != nil }

    var isInternal: Bool {
        if indexedAsInternal { return true }
        guard let model else { return false }
        return model.caseInsensitiveCompare("codex-auto-review") == .orderedSame
    }

    mutating func apply(metadata: ThreadMetadata) {
        title = metadata.title ?? title
        model = model ?? metadata.model
        indexedAsInternal = metadata.isInternal
    }

    func snapshot(
        selectionMode: SessionSelectionMode,
        dynamicIconEnabled: Bool,
        tokenSpeed: TokenSpeed,
        weeklyRemaining: Double?,
        weeklyResetsAt: Date?
    ) -> StatusSnapshot {
        let usedTokens = inputTokens.flatMap { input in outputTokens.map { input + $0 } }
        let available = usedTokens.flatMap { used in
            contextWindow.flatMap { window in
                window > 0 ? min(max((1 - Double(used) / Double(window)) * 100, 0), 100) : nil
            }
        }
        let resolvedStage: TaskStage
        if !active { resolvedStage = .idle }
        else if [.usingTool, .waitingForTool, .waitingForApproval].contains(stage) { resolvedStage = stage }
        else {
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
            tokenSpeed: tokenSpeed,
            model: model,
            contextAvailablePercent: available,
            contextUsedTokens: usedTokens,
            contextWindowTokens: contextWindow,
            sessionID: id,
            sessionTitle: title,
            selectionMode: selectionMode,
            stage: resolvedStage,
            updatedAt: latestTaskEventAt ?? updatedAt,
            dynamicIconEnabled: dynamicIconEnabled
        )
    }
}

enum SessionLogParser {
    static func apply(_ line: Data, to state: inout SessionState) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        let timestamp = (object["timestamp"] as? String).flatMap(parseTimestamp)
        if let timestamp { state.updatedAt = max(state.updatedAt, timestamp) }
        let payload = object["payload"] as? [String: Any] ?? [:]
        switch object["type"] as? String {
        case "session_meta":
            state.id = (payload["id"] as? String) ?? (payload["session_id"] as? String) ?? state.id
        case "turn_context":
            state.model = (payload["model"] as? String) ?? state.model
        case "event_msg": applyEvent(payload, timestamp: timestamp, to: &state)
        case "response_item": applyResponseItem(payload, timestamp: timestamp, to: &state)
        default: break
        }
    }

    private static func applyEvent(_ payload: [String: Any], timestamp: Date?, to state: inout SessionState) {
        let event = payload["type"] as? String
        switch event {
        case "task_started":
            state.active = true
            state.stage = .thinking
            state.latestTaskEventAt = timestamp ?? state.updatedAt
        case "task_complete", "task_failed", "task_cancelled", "turn_aborted":
            state.active = false
            state.stage = .idle
            state.latestTaskEventAt = timestamp ?? state.updatedAt
        case "token_count": applyTokenCount(payload, timestamp: timestamp, to: &state)
        case "user_message": state.latestTaskEventAt = timestamp ?? state.updatedAt
        default:
            if event?.localizedCaseInsensitiveContains("approval") == true { state.stage = .waitingForApproval }
        }
    }

    private static func applyResponseItem(_ payload: [String: Any], timestamp: Date?, to state: inout SessionState) {
        if payload["type"] as? String == "message", payload["role"] as? String == "user" {
            state.latestTaskEventAt = timestamp ?? state.updatedAt
        }
        guard state.active else { return }
        switch payload["type"] as? String {
        case "custom_tool_call", "function_call", "mcp_tool_call": state.stage = .waitingForTool
        case "custom_tool_call_output", "function_call_output", "mcp_tool_call_output": state.stage = .thinking
        case "message": state.stage = .finishing
        default: break
        }
    }

    private static func applyTokenCount(_ payload: [String: Any], timestamp: Date?, to state: inout SessionState) {
        if let info = payload["info"] as? [String: Any] {
            let usage = info["last_token_usage"] as? [String: Any]
            state.inputTokens = (usage?["input_tokens"] as? NSNumber)?.intValue ?? state.inputTokens
            state.outputTokens = (usage?["output_tokens"] as? NSNumber)?.intValue ?? state.outputTokens
            state.contextWindow = (info["model_context_window"] as? NSNumber)?.intValue ?? state.contextWindow
        }
        guard let rateLimits = payload["rate_limits"] as? [String: Any] else { return }
        let limitID = rateLimits["limit_id"] as? String
        for case let window as [String: Any] in [rateLimits["primary"], rateLimits["secondary"]] {
            guard (window["window_minutes"] as? NSNumber)?.intValue == 10_080,
                  let used = (window["used_percent"] as? NSNumber)?.doubleValue else { continue }
            state.weeklyRemaining = min(max(100 - used, 0), 100)
            state.weeklyResetsAt = (window["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            state.weeklyUpdatedAt = timestamp ?? state.updatedAt
            state.weeklyIsCodex = limitID == "codex"
            break
        }
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}
