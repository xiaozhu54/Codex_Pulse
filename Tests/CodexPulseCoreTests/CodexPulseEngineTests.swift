import Foundation
import SQLite3
import CodexPulseCore

@main
struct CodexPulseBehaviorTests {
    static func main() throws {
        try idleShowsOnlyWeeklyRemaining()
        print("PASS: Codex idle shows only weekly remaining")
        try internalReviewDoesNotReplaceActiveMainTask()
        print("PASS: Internal review does not replace active main task")
        try threadIndexFiltersSubagentsAndProvidesTitle()
        print("PASS: Thread index filters subagents and provides title")
        try unavailablePinnedSessionDoesNotSilentlySwitch()
        print("PASS: Unavailable pinned session does not silently switch")
        try observableOutputProducesLiveTokenSpeed()
        print("PASS: Observable model output produces live token speed")
        try completedResponsesCalibrateWithoutToolWait()
        print("PASS: Completed responses calibrate without tool wait")
        try weeklyColorsHonorAuthoredStops()
        print("PASS: Weekly colors honor authored stops")
        try toolCallKeepsTaskActiveAndShowsWaitingStage()
        print("PASS: Tool call keeps task active and shows waiting stage")
        try partialLineWaitsForCompletionAndContextCanRecover()
        print("PASS: Partial line waits and context can recover after compaction")
    }

    private static func idleShowsOnlyWeeklyRemaining() throws {
        let fixture = try CodexHomeFixture()
        try fixture.writeSession(
            id: "main-thread",
            title: "A user task",
            lines: [
                #"{"timestamp":"2026-07-16T00:00:00Z","type":"session_meta","payload":{"id":"main-thread"}}"#,
                #"{"timestamp":"2026-07-16T00:00:01Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
                #"{"timestamp":"2026-07-16T00:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":25000,"output_tokens":1000},"model_context_window":100000},"rate_limits":{"limit_id":"codex","primary":{"used_percent":25.0,"window_minutes":10080,"resets_at":1784246400}}}}"#,
                #"{"timestamp":"2026-07-16T00:00:03Z","type":"event_msg","payload":{"type":"task_complete"}}"#
            ]
        )

        let engine = CodexPulseEngine(codexHome: fixture.url)
        let snapshot = try engine.snapshot(
            codexRunning: true,
            preferences: PulsePreferences()
        )

        try expect(snapshot.visibility == .idle, "expected idle visibility")
        try expect(snapshot.menuBarText == "W 75%", "expected compact weekly menu text")
        try expect(snapshot.weeklyRemainingPercent == 75, "expected 75% weekly remaining")
    }

    private static func internalReviewDoesNotReplaceActiveMainTask() throws {
        let fixture = try CodexHomeFixture()
        try fixture.writeSession(
            id: "main-thread",
            title: "Build the feature",
            lines: [
                #"{"timestamp":"2026-07-16T00:10:00Z","type":"session_meta","payload":{"id":"main-thread"}}"#,
                #"{"timestamp":"2026-07-16T00:10:01Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
                #"{"timestamp":"2026-07-16T00:10:02Z","type":"event_msg","payload":{"type":"task_started"}}"#,
                #"{"timestamp":"2026-07-16T00:10:03Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":25000,"output_tokens":1000},"model_context_window":100000},"rate_limits":{"limit_id":"codex","primary":{"used_percent":40.0,"window_minutes":10080,"resets_at":1784246400}}}}"#
            ]
        )
        try fixture.writeSession(
            id: "review-thread",
            title: "Internal review",
            lines: [
                #"{"timestamp":"2026-07-16T00:11:00Z","type":"session_meta","payload":{"id":"review-thread"}}"#,
                #"{"timestamp":"2026-07-16T00:11:01Z","type":"turn_context","payload":{"model":"codex-auto-review"}}"#,
                #"{"timestamp":"2026-07-16T00:11:02Z","type":"event_msg","payload":{"type":"task_started"}}"#
            ]
        )

        let snapshot = try CodexPulseEngine(codexHome: fixture.url).snapshot(
            codexRunning: true,
            preferences: PulsePreferences()
        )

        try expect(snapshot.sessionID == "main-thread", "expected main thread to win automatic following")
        try expect(snapshot.visibility == .active, "expected active visibility")
        try expect(
            snapshot.menuBarText == "W 60% · 推理中… · GPT‑5.6 · Ctx 74%",
            "expected complete active task summary"
        )
    }

    private static func threadIndexFiltersSubagentsAndProvidesTitle() throws {
        let fixture = try CodexHomeFixture()
        let mainPath = try fixture.writeSession(
            id: "main-thread",
            title: "Pinned task",
            lines: [
                #"{"timestamp":"2026-07-16T00:20:00Z","type":"session_meta","payload":{"id":"main-thread"}}"#,
                #"{"timestamp":"2026-07-16T00:20:01Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
                #"{"timestamp":"2026-07-16T00:20:02Z","type":"event_msg","payload":{"type":"task_started"}}"#
            ]
        )
        let subagentPath = try fixture.writeSession(
            id: "subagent-thread",
            title: "Internal worker",
            lines: [
                #"{"timestamp":"2026-07-16T00:21:00Z","type":"session_meta","payload":{"id":"subagent-thread"}}"#,
                #"{"timestamp":"2026-07-16T00:21:01Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
                #"{"timestamp":"2026-07-16T00:21:02Z","type":"event_msg","payload":{"type":"task_started"}}"#
            ]
        )
        try fixture.writeThreadIndex(rows: [
            .init(
                id: "main-thread",
                rolloutPath: mainPath.path,
                updatedAt: 100,
                title: "Pinned task",
                model: "gpt-5.6-sol",
                agentPath: nil,
                threadSource: "user"
            ),
            .init(
                id: "subagent-thread",
                rolloutPath: subagentPath.path,
                updatedAt: 200,
                title: "Internal worker",
                model: "gpt-5.6-sol",
                agentPath: "/root/worker",
                threadSource: "subagent"
            )
        ])

        let snapshot = try CodexPulseEngine(codexHome: fixture.url).snapshot(
            codexRunning: true,
            preferences: PulsePreferences()
        )

        try expect(snapshot.sessionID == "main-thread", "expected subagent to be excluded")
        try expect(snapshot.sessionTitle == "Pinned task", "expected title from thread index")
    }

    private static func unavailablePinnedSessionDoesNotSilentlySwitch() throws {
        let fixture = try CodexHomeFixture()
        try fixture.writeSession(
            id: "available-thread",
            title: "Available task",
            lines: [
                #"{"timestamp":"2026-07-16T00:30:00Z","type":"session_meta","payload":{"id":"available-thread"}}"#,
                #"{"timestamp":"2026-07-16T00:30:01Z","type":"event_msg","payload":{"type":"task_started"}}"#
            ]
        )

        let snapshot = try CodexPulseEngine(codexHome: fixture.url).snapshot(
            codexRunning: true,
            preferences: PulsePreferences(pinnedSessionID: "missing-thread")
        )

        try expect(snapshot.selectionMode == .pinnedUnavailable, "expected unavailable pinned state")
        try expect(snapshot.sessionID == "missing-thread", "expected missing pin identity to be preserved")
        try expect(snapshot.visibility == .idle, "expected no other active thread to be substituted")
    }

    private static func observableOutputProducesLiveTokenSpeed() throws {
        let fixture = try CodexHomeFixture()
        try fixture.writeSession(
            id: "main-thread",
            title: "Streaming task",
            lines: [
                #"{"timestamp":"2026-07-16T00:40:00Z","type":"session_meta","payload":{"id":"main-thread"}}"#,
                #"{"timestamp":"2026-07-16T00:40:01Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
                #"{"timestamp":"2026-07-16T00:40:02Z","type":"event_msg","payload":{"type":"task_started"}}"#
            ]
        )
        let start: Int64 = 1_784_000_000
        try fixture.writeLogs(rows: [
            .init(
                timestamp: start,
                nanoseconds: 0,
                threadID: "main-thread",
                body: #"SSE event: {"type":"response.created","response":{"id":"response-1"}}"#
            ),
            .init(
                timestamp: start + 1,
                nanoseconds: 0,
                threadID: "main-thread",
                body: #"SSE event: {"type":"response.output_text.delta","delta":"one two"}"#
            ),
            .init(
                timestamp: start + 1,
                nanoseconds: 500_000_000,
                threadID: "main-thread",
                body: #"SSE event: {"type":"response.custom_tool_call_input.delta","delta":" six four"}"#
            )
        ])

        let snapshot = try CodexPulseEngine(codexHome: fixture.url).snapshot(
            codexRunning: true,
            preferences: PulsePreferences(),
            now: Date(timeIntervalSince1970: TimeInterval(start + 2))
        )

        try expect(snapshot.tokenSpeed.kind == .estimating, "expected a live estimate")
        try expect(
            snapshot.tokenSpeed.tokensPerSecond == 2,
            "expected four estimated tokens over two seconds, got \(String(describing: snapshot.tokenSpeed.tokensPerSecond))"
        )
        try expect(snapshot.menuBarText.contains("≈2.0 t/s"), "expected estimated speed in menu bar")
        try expect(snapshot.stage == .generating, "expected generating stage")
    }

    private static func completedResponsesCalibrateWithoutToolWait() throws {
        let fixture = try CodexHomeFixture()
        try fixture.writeSession(
            id: "main-thread",
            title: "Tool task",
            lines: [
                #"{"timestamp":"2026-07-16T00:50:00Z","type":"session_meta","payload":{"id":"main-thread"}}"#,
                #"{"timestamp":"2026-07-16T00:50:01Z","type":"event_msg","payload":{"type":"task_started"}}"#
            ]
        )
        let start: Int64 = 1_784_100_000
        try fixture.writeLogs(rows: [
            .init(timestamp: start, nanoseconds: 0, threadID: "main-thread", body: #"SSE event: {"type":"response.created","response":{"id":"response-1"}}"#),
            .init(timestamp: start + 4, nanoseconds: 0, threadID: "main-thread", body: #"SSE event: {"type":"response.completed","response":{"id":"response-1","usage":{"output_tokens":20,"output_tokens_details":{"reasoning_tokens":8}}}}"#),
            .init(timestamp: start + 100, nanoseconds: 0, threadID: "main-thread", body: #"SSE event: {"type":"response.created","response":{"id":"response-2"}}"#),
            .init(timestamp: start + 102, nanoseconds: 0, threadID: "main-thread", body: #"SSE event: {"type":"response.completed","response":{"id":"response-2","usage":{"output_tokens":10,"output_tokens_details":{"reasoning_tokens":4}}}}"#)
        ])

        let snapshot = try CodexPulseEngine(codexHome: fixture.url).snapshot(
            codexRunning: true,
            preferences: PulsePreferences(),
            now: Date(timeIntervalSince1970: TimeInterval(start + 102))
        )

        try expect(snapshot.tokenSpeed.kind == .final, "expected a calibrated final speed")
        try expect(snapshot.tokenSpeed.tokensPerSecond == 5, "expected the latest response to be 5 t/s")
        try expect(snapshot.tokenSpeed.recentAverage == 5, "expected tool wait to be excluded from the moving average")
    }

    private static func weeklyColorsHonorAuthoredStops() throws {
        try expect(WeeklyColor.color(remainingPercent: 100).hex == "#FFFFFF", "expected 100% to be white")
        try expect(WeeklyColor.color(remainingPercent: 54.5).hex == "#FFCCA8", "expected authored middle stop")
        try expect(WeeklyColor.color(remainingPercent: 0).hex == "#FF7417", "expected 0% to be orange")
        try expect(
            WeeklyColor.color(remainingPercent: 50).hex != WeeklyColor.color(remainingPercent: 45.5).hex,
            "expected continuous interpolation between stops"
        )
    }

    private static func toolCallKeepsTaskActiveAndShowsWaitingStage() throws {
        let fixture = try CodexHomeFixture()
        try fixture.writeSession(
            id: "main-thread",
            title: "Tool task",
            lines: [
                #"{"timestamp":"2026-07-16T01:00:00Z","type":"session_meta","payload":{"id":"main-thread"}}"#,
                #"{"timestamp":"2026-07-16T01:00:01Z","type":"event_msg","payload":{"type":"task_started"}}"#,
                #"{"timestamp":"2026-07-16T01:00:02Z","type":"response_item","payload":{"type":"custom_tool_call","name":"safe_fixture_tool"}}"#
            ]
        )

        let snapshot = try CodexPulseEngine(codexHome: fixture.url).snapshot(
            codexRunning: true,
            preferences: PulsePreferences()
        )

        try expect(snapshot.visibility == .active, "expected tool call to remain active")
        try expect(snapshot.stage == .waitingForTool, "expected waiting-for-tool stage")
    }

    private static func partialLineWaitsForCompletionAndContextCanRecover() throws {
        let fixture = try CodexHomeFixture()
        try fixture.writeSession(
            id: "main-thread",
            title: "Compaction task",
            lines: [
                #"{"timestamp":"2026-07-16T01:10:00Z","type":"session_meta","payload":{"id":"main-thread"}}"#,
                #"{"timestamp":"2026-07-16T01:10:01Z","type":"event_msg","payload":{"type":"task_started"}}"#,
                #"{"timestamp":"2026-07-16T01:10:02Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":85000,"output_tokens":5000},"model_context_window":100000},"rate_limits":{}}}"#
            ]
        )
        let engine = CodexPulseEngine(codexHome: fixture.url)
        let before = try engine.snapshot(codexRunning: true, preferences: PulsePreferences())
        try expect(
            abs((before.contextAvailablePercent ?? -1) - 10) < 0.001,
            "expected 10% context before compaction"
        )

        let compacted = #"{"timestamp":"2026-07-16T01:10:03Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":25000,"output_tokens":5000},"model_context_window":100000},"rate_limits":{}}}"#
        let split = compacted.index(compacted.startIndex, offsetBy: compacted.count / 2)
        try fixture.appendToSession(id: "main-thread", text: String(compacted[..<split]))
        let whilePartial = try engine.snapshot(codexRunning: true, preferences: PulsePreferences())
        try expect(
            abs((whilePartial.contextAvailablePercent ?? -1) - 10) < 0.001,
            "expected incomplete JSON to be ignored"
        )

        try fixture.appendToSession(id: "main-thread", text: String(compacted[split...]) + "\n")
        let after = try engine.snapshot(codexRunning: true, preferences: PulsePreferences())
        try expect(
            abs((after.contextAvailablePercent ?? -1) - 70) < 0.001,
            "expected context to recover after compaction"
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw BehaviorTestFailure(message: message) }
    }
}

private struct BehaviorTestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { "FAIL: \(message)" }
}

private final class CodexHomeFixture {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-pulse-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func writeSession(id: String, title: String, lines: [String]) throws -> URL {
        let directory = url.appendingPathComponent("sessions/2026/07/16", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("rollout-\(id).jsonl")
        try lines.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func writeThreadIndex(rows: [ThreadIndexRow]) throws {
        let path = url.appendingPathComponent("state_9.sqlite").path
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK, let database else {
            throw BehaviorTestFailure(message: "could not create thread index fixture")
        }
        defer { sqlite3_close(database) }

        let schema = """
        CREATE TABLE threads (
            id TEXT PRIMARY KEY,
            rollout_path TEXT NOT NULL,
            updated_at INTEGER NOT NULL,
            archived INTEGER NOT NULL,
            title TEXT NOT NULL,
            model TEXT,
            agent_path TEXT,
            thread_source TEXT,
            preview TEXT NOT NULL
        );
        """
        guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
            throw BehaviorTestFailure(message: "could not create threads fixture table")
        }

        let insert = "INSERT INTO threads VALUES (?, ?, ?, 0, ?, ?, ?, ?, 'visible')"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, insert, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw BehaviorTestFailure(message: "could not prepare thread fixture insert")
        }
        defer { sqlite3_finalize(statement) }

        for row in rows {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            bind(row.id, at: 1, to: statement)
            bind(row.rolloutPath, at: 2, to: statement)
            sqlite3_bind_int64(statement, 3, sqlite3_int64(row.updatedAt))
            bind(row.title, at: 4, to: statement)
            bind(row.model, at: 5, to: statement)
            bind(row.agentPath, at: 6, to: statement)
            bind(row.threadSource, at: 7, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw BehaviorTestFailure(message: "could not insert thread fixture")
            }
        }
    }

    func writeLogs(rows: [LogRow]) throws {
        let path = url.appendingPathComponent("logs_9.sqlite").path
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK, let database else {
            throw BehaviorTestFailure(message: "could not create logs fixture")
        }
        defer { sqlite3_close(database) }

        let schema = """
        CREATE TABLE logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts INTEGER NOT NULL,
            ts_nanos INTEGER NOT NULL,
            level TEXT NOT NULL,
            target TEXT NOT NULL,
            feedback_log_body TEXT,
            thread_id TEXT
        );
        """
        guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
            throw BehaviorTestFailure(message: "could not create logs fixture table")
        }

        let insert = "INSERT INTO logs (ts, ts_nanos, level, target, feedback_log_body, thread_id) VALUES (?, ?, 'TRACE', 'codex_api::sse::responses', ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, insert, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw BehaviorTestFailure(message: "could not prepare log fixture insert")
        }
        defer { sqlite3_finalize(statement) }

        for row in rows {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_int64(statement, 1, sqlite3_int64(row.timestamp))
            sqlite3_bind_int64(statement, 2, sqlite3_int64(row.nanoseconds))
            bind(row.body, at: 3, to: statement)
            bind(row.threadID, at: 4, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw BehaviorTestFailure(message: "could not insert log fixture")
            }
        }
    }

    func appendToSession(id: String, text: String) throws {
        let file = url.appendingPathComponent("sessions/2026/07/16/rollout-\(id).jsonl")
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func bind(_ value: String?, at index: Int32, to statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
}

private struct ThreadIndexRow {
    let id: String
    let rolloutPath: String
    let updatedAt: Int
    let title: String
    let model: String?
    let agentPath: String?
    let threadSource: String?
}

private struct LogRow {
    let timestamp: Int64
    let nanoseconds: Int64
    let threadID: String
    let body: String
}
