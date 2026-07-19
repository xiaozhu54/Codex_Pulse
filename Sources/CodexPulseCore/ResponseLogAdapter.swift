import Foundation

final class ResponseLogAdapter {
    private let codexHome: URL
    private var databaseIdentity: String?
    private var lastRowID: Int64 = 0
    private var accumulators: [String: ResponseMetricsAccumulator] = [:]
    private(set) var status = SourceStatus(availability: .unavailable, issue: .missing)

    init(codexHome: URL) {
        self.codexHome = codexHome
    }

    func metrics(now: Date) -> [String: MetricValue<TokenSpeed>] {
        ingestNewRows()
        return accumulators.mapValues { accumulator in
            let speed = accumulator.current(now: now)
            return MetricValue(
                value: speed,
                availability: speed.kind == .unavailable ? .unavailable : status.availability,
                observedAt: accumulator.lastObservedAt,
                source: .responseLog,
                issue: status.issue
            )
        }
    }

    private func ingestNewRows() {
        guard let (url, database, columns) = compatibleDatabase() else { return }
        defer { database.close() }
        let identity = fileIdentity(url)
        if databaseIdentity != identity {
            databaseIdentity = identity
            lastRowID = 0
            for accumulator in accumulators.values { accumulator.handleRotation() }
        }

        if lastRowID == 0,
           let maximums: [Int64] = try? database.query(
               "SELECT COALESCE(MAX(id), 0) FROM logs",
               transform: { $0.int64(at: 0) }
           ),
           let maximum = maximums.first {
            lastRowID = max(0, maximum - 4_000)
        }

        guard columns.isSuperset(of: Self.requiredColumns) else {
            status = SourceStatus(availability: .unavailable, issue: .incompatible)
            return
        }
        let sql = """
        SELECT id, ts, ts_nanos, feedback_log_body, thread_id
        FROM logs
        WHERE id > \(lastRowID) AND target = 'codex_api::sse::responses'
        ORDER BY id ASC
        """
        do {
            let rows: [SpeedLogRow] = try database.query(sql) { row in
                guard let body = row.text(at: 3), let threadID = row.text(at: 4) else { return nil }
                return SpeedLogRow(
                    id: row.int64(at: 0),
                    timestamp: Date(
                        timeIntervalSince1970: Double(row.int64(at: 1))
                            + Double(row.int64(at: 2)) / 1_000_000_000
                    ),
                    body: body,
                    threadID: threadID
                )
            }
            if let last = rows.last { lastRowID = last.id }
            for row in rows {
                let accumulator = accumulators[row.threadID] ?? ResponseMetricsAccumulator()
                accumulator.ingest(row)
                accumulators[row.threadID] = accumulator
            }
            status = SourceStatus(
                availability: .available,
                observedAt: rows.last?.timestamp ?? status.observedAt
            )
        } catch {
            status = SourceStatus(availability: .stale, issue: .readFailed)
        }
    }

    private func compatibleDatabase() -> (URL, ReadOnlySQLite, Set<String>)? {
        let candidates = CodexDatabaseDiscovery.candidates(prefix: "logs_", in: codexHome)
        guard !candidates.isEmpty else {
            status = SourceStatus(availability: .unavailable, issue: .missing)
            return nil
        }
        for url in candidates {
            guard let database = try? ReadOnlySQLite(url: url) else { continue }
            guard let columns = try? database.columnNames(table: "logs"),
                  columns.isSuperset(of: Self.requiredColumns) else {
                database.close()
                continue
            }
            return (url, database, columns)
        }
        status = SourceStatus(availability: .unavailable, issue: .incompatible)
        return nil
    }

    private func fileIdentity(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey])
        return "\(url.standardizedFileURL.path)|\(String(describing: values?.fileResourceIdentifier))"
    }

    private static let requiredColumns: Set<String> = [
        "id", "ts", "ts_nanos", "target", "feedback_log_body", "thread_id"
    ]
}

private final class ResponseMetricsAccumulator {
    private struct Sample {
        let timestamp: Date
        let tokens: Int
    }

    private var responseID: String?
    private var responseStartedAt: Date?
    private var samples: [Sample] = []
    private var completedSpeeds: [Double] = []
    private var latest = TokenSpeed.unavailable
    private var outputKind: TokenSpeed.OutputKind?
    private(set) var lastObservedAt: Date?

    func ingest(_ row: SpeedLogRow) {
        lastObservedAt = max(lastObservedAt ?? .distantPast, row.timestamp)
        guard row.body.hasPrefix("SSE event: "),
              let data = String(row.body.dropFirst("SSE event: ".count)).data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return }

        switch type {
        case "response.created", "response.in_progress":
            let response = event["response"] as? [String: Any]
            let newID = response?["id"] as? String
            if responseID != newID || responseStartedAt == nil {
                responseID = newID
                responseStartedAt = row.timestamp
                samples.removeAll(keepingCapacity: true)
                outputKind = nil
                latest = TokenSpeed(kind: .thinking, recentAverage: recentAverage)
            } else if let started = responseStartedAt, row.timestamp < started {
                responseStartedAt = row.timestamp
            }
        case "response.output_text.delta", "response.reasoning_summary_text.delta":
            guard let delta = event["delta"] as? String else { return }
            outputKind = .text
            if responseStartedAt == nil { responseStartedAt = row.timestamp }
            let count = ApproximateTokenCounter.count(delta)
            if count > 0 { samples.append(Sample(timestamp: row.timestamp, tokens: count)) }
        case "response.function_call_arguments.delta", "response.custom_tool_call_input.delta":
            guard let delta = event["delta"] as? String else { return }
            outputKind = .toolCall
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
                    recentAverage: recentAverage,
                    outputKind: outputKind
                )
            } else {
                latest = TokenSpeed(kind: .unavailable, recentAverage: recentAverage)
            }
            resetInFlight()
        case "response.failed", "response.cancelled", "response.incomplete":
            resetInFlight()
            latest = TokenSpeed(kind: .unavailable, recentAverage: recentAverage)
        default:
            break
        }
    }

    func current(now: Date) -> TokenSpeed {
        let cutoff = now.addingTimeInterval(-2)
        samples.removeAll { $0.timestamp < cutoff }
        if let responseStartedAt, !samples.isEmpty {
            let windowStart = max(responseStartedAt, cutoff)
            let duration = max(now.timeIntervalSince(windowStart), 0.5)
            let tokens = samples.reduce(0) { $0 + $1.tokens }
            latest = TokenSpeed(
                kind: .estimating,
                tokensPerSecond: Double(tokens) / duration,
                recentAverage: recentAverage,
                outputKind: outputKind
            )
        } else if responseStartedAt != nil, latest.kind != .final {
            latest = TokenSpeed(kind: .thinking, recentAverage: recentAverage)
        }
        return latest
    }

    func handleRotation() {
        resetInFlight()
        latest = TokenSpeed(kind: .unavailable, recentAverage: recentAverage)
    }

    private var recentAverage: Double? {
        guard !completedSpeeds.isEmpty else { return nil }
        return completedSpeeds.reduce(0, +) / Double(completedSpeeds.count)
    }

    private func resetInFlight() {
        responseStartedAt = nil
        responseID = nil
        samples.removeAll(keepingCapacity: true)
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
        return total + tokensForASCII(asciiRun)
    }

    private static func isCJK(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: true
        default: false
        }
    }
}
