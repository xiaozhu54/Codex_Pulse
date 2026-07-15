import Foundation

final class LogSpeedTracker {
    private struct Sample {
        let timestamp: Date
        let tokens: Int
    }

    private let codexHome: URL
    private var databasePath: String?
    private var lastRowID: Int64 = 0
    private var selectedThreadID: String?
    private var responseID: String?
    private var responseStartedAt: Date?
    private var samples: [Sample] = []
    private var completedSpeeds: [Double] = []
    private var latest = TokenSpeed.unavailable

    init(codexHome: URL) {
        self.codexHome = codexHome
    }

    func speed(threadID: String, now: Date) -> TokenSpeed {
        if selectedThreadID != threadID {
            resetForThread(threadID)
        }
        ingestNewRows(for: threadID)

        let cutoff = now.addingTimeInterval(-2)
        samples.removeAll { $0.timestamp < cutoff }
        if let responseStartedAt, !samples.isEmpty {
            let windowStart = max(responseStartedAt, cutoff)
            let duration = max(now.timeIntervalSince(windowStart), 0.5)
            let tokens = samples.reduce(0) { $0 + $1.tokens }
            latest = TokenSpeed(
                kind: .estimating,
                tokensPerSecond: Double(tokens) / duration,
                recentAverage: recentAverage
            )
        } else if responseStartedAt != nil, latest.kind != .final {
            latest = TokenSpeed(kind: .thinking, recentAverage: recentAverage)
        }
        return latest
    }

    private var recentAverage: Double? {
        guard !completedSpeeds.isEmpty else { return nil }
        return completedSpeeds.reduce(0, +) / Double(completedSpeeds.count)
    }

    private func resetForThread(_ threadID: String) {
        selectedThreadID = threadID
        responseID = nil
        responseStartedAt = nil
        samples.removeAll(keepingCapacity: true)
        completedSpeeds.removeAll(keepingCapacity: true)
        latest = .unavailable
        lastRowID = 0
    }

    private func ingestNewRows(for threadID: String) {
        guard let url = latestLogDatabase() else { return }
        if databasePath != url.path {
            databasePath = url.path
            lastRowID = 0
        }

        guard let database = try? ReadOnlySQLite(url: url) else { return }
        defer { database.close() }
        guard let columns = try? database.columnNames(table: "logs"),
              ["id", "ts", "ts_nanos", "target", "feedback_log_body", "thread_id"].allSatisfy(columns.contains)
        else { return }

        if lastRowID == 0,
           let maximums: [Int64] = try? database.query("SELECT COALESCE(MAX(id), 0) FROM logs", transform: { row in
               row.int64(at: 0)
           }),
           let maximum = maximums.first {
            lastRowID = max(0, maximum - 4_000)
        }

        let sql = """
        SELECT id, ts, ts_nanos, feedback_log_body, thread_id
        FROM logs
        WHERE id > \(lastRowID) AND target = 'codex_api::sse::responses'
        ORDER BY id ASC
        """
        guard let rows: [SpeedLogRow] = try? database.query(sql, transform: { row in
            guard let body = row.text(at: 3), let rowThreadID = row.text(at: 4) else { return nil }
            return SpeedLogRow(
                id: row.int64(at: 0),
                timestamp: Date(
                    timeIntervalSince1970: Double(row.int64(at: 1))
                        + Double(row.int64(at: 2)) / 1_000_000_000
                ),
                body: body,
                threadID: rowThreadID
            )
        }) else { return }

        if let last = rows.last { lastRowID = last.id }
        for row in rows where row.threadID == threadID {
            ingest(row)
        }
    }

    private func ingest(_ row: SpeedLogRow) {
        guard row.body.hasPrefix("SSE event: "),
              let data = String(row.body.dropFirst("SSE event: ".count)).data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String
        else { return }

        switch type {
        case "response.created", "response.in_progress":
            let response = event["response"] as? [String: Any]
            let newID = response?["id"] as? String
            if responseID != newID || responseStartedAt == nil {
                responseID = newID
                responseStartedAt = row.timestamp
                samples.removeAll(keepingCapacity: true)
                latest = TokenSpeed(kind: .thinking, recentAverage: recentAverage)
            } else if let started = responseStartedAt, row.timestamp < started {
                responseStartedAt = row.timestamp
            }
        case "response.output_text.delta",
             "response.reasoning_summary_text.delta",
             "response.function_call_arguments.delta",
             "response.custom_tool_call_input.delta":
            guard let delta = event["delta"] as? String else { return }
            if responseStartedAt == nil { responseStartedAt = row.timestamp }
            let count = ApproximateTokenCounter.count(delta)
            if count > 0 { samples.append(Sample(timestamp: row.timestamp, tokens: count)) }
        case "response.completed":
            let response = event["response"] as? [String: Any]
            let usage = response?["usage"] as? [String: Any]
            let outputTokens = (usage?["output_tokens"] as? NSNumber)?.doubleValue
            if let outputTokens, let started = responseStartedAt {
                let duration = max(row.timestamp.timeIntervalSince(started), 0.001)
                let finalSpeed = outputTokens / duration
                completedSpeeds.append(finalSpeed)
                if completedSpeeds.count > 5 { completedSpeeds.removeFirst(completedSpeeds.count - 5) }
                latest = TokenSpeed(
                    kind: .final,
                    tokensPerSecond: finalSpeed,
                    recentAverage: recentAverage
                )
            }
            responseStartedAt = nil
            responseID = nil
            samples.removeAll(keepingCapacity: true)
        default:
            break
        }
    }

    private func latestLogDatabase() -> URL? {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: codexHome,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { $0.lastPathComponent.hasPrefix("logs_") && $0.pathExtension == "sqlite" }
            .max {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left < right
            }
    }
}

private struct SpeedLogRow {
    let id: Int64
    let timestamp: Date
    let body: String
    let threadID: String
}

private enum ApproximateTokenCounter {
    static func count(_ text: String) -> Int {
        var total = 0
        var asciiRun = 0

        func tokensForASCII(_ length: Int) -> Int {
            length == 0 ? 0 : max(1, Int(ceil(Double(length) / 4)))
        }

        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                total += tokensForASCII(asciiRun)
                asciiRun = 0
                total += 1
            } else if CharacterSet.alphanumerics.contains(scalar) {
                asciiRun += 1
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                total += tokensForASCII(asciiRun)
                asciiRun = 0
            } else {
                total += tokensForASCII(asciiRun)
                asciiRun = 0
                total += 1
            }
        }
        total += tokensForASCII(asciiRun)
        return total
    }

    private static func isCJK(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            true
        default:
            false
        }
    }
}
