import Foundation
import SQLite3

struct ThreadMetadata {
    let id: String
    let rolloutPath: String
    let title: String?
    let model: String?
    let updatedAt: Date
    let isInternal: Bool
}

enum ThreadIndexReader {
    static func load(from codexHome: URL) -> [String: ThreadMetadata] {
        for databaseURL in stateDatabases(in: codexHome) {
            guard let rows = try? read(databaseURL), !rows.isEmpty else { continue }
            var index: [String: ThreadMetadata] = [:]
            for row in rows {
                index[row.id] = row
                index[URL(fileURLWithPath: row.rolloutPath).standardizedFileURL.path] = row
            }
            return index
        }
        return [:]
    }

    private static func stateDatabases(in codexHome: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: codexHome,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
    }

    private static func read(_ url: URL) throws -> [ThreadMetadata] {
        let database = try ReadOnlySQLite(url: url)
        defer { database.close() }

        let columns = try database.columnNames(table: "threads")
        guard columns.contains("id"), columns.contains("rollout_path") else { return [] }

        func expression(_ name: String, fallback: String = "NULL") -> String {
            columns.contains(name) ? "\"\(name)\"" : "\(fallback) AS \"\(name)\""
        }

        let sql = """
        SELECT
            \(expression("id")),
            \(expression("rollout_path")),
            \(expression("title")),
            \(expression("model")),
            \(expression("updated_at", fallback: "0")),
            \(expression("updated_at_ms", fallback: "0")),
            \(expression("archived", fallback: "0")),
            \(expression("agent_path")),
            \(expression("thread_source")),
            \(expression("preview", fallback: "''"))
        FROM threads
        """

        return try database.query(sql) { statement in
            guard let id = statement.text(at: 0),
                  let rolloutPath = statement.text(at: 1)
            else { return nil }

            let archived = statement.int64(at: 6) != 0
            guard !archived else { return nil }

            let title = statement.text(at: 2)
            let model = statement.text(at: 3)
            let seconds = statement.int64(at: 4)
            let milliseconds = statement.int64(at: 5)
            let updatedAt = milliseconds > 0
                ? Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
                : Date(timeIntervalSince1970: Double(seconds))
            let agentPath = statement.text(at: 7)
            let threadSource = statement.text(at: 8)
            let preview = statement.text(at: 9) ?? ""

            let isAutoReview = model?.caseInsensitiveCompare("codex-auto-review") == .orderedSame
            let hasAgentPath = !(agentPath?.isEmpty ?? true)
            let isNonUserSource = threadSource.map { !$0.isEmpty && $0 != "user" } ?? false
            let isInternal = isAutoReview || hasAgentPath || isNonUserSource || preview.isEmpty

            return ThreadMetadata(
                id: id,
                rolloutPath: rolloutPath,
                title: title,
                model: model,
                updatedAt: updatedAt,
                isInternal: isInternal
            )
        }
    }
}

final class ReadOnlySQLite {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, handle != nil else {
            if let handle { sqlite3_close(handle) }
            throw SQLiteReadError.openFailed
        }
        sqlite3_busy_timeout(handle, 50)
    }

    func close() {
        if let handle {
            sqlite3_close(handle)
            self.handle = nil
        }
    }

    func columnNames(table: String) throws -> Set<String> {
        Set(try query("PRAGMA table_info(\"\(table)\")") { statement in
            statement.text(at: 1)
        })
    }

    func query<T>(_ sql: String, transform: (SQLiteRow) throws -> T?) throws -> [T] {
        guard let handle else { throw SQLiteReadError.closed }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw SQLiteReadError.prepareFailed }
        defer { sqlite3_finalize(statement) }

        var values: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let value = try transform(SQLiteRow(statement: statement)) {
                    values.append(value)
                }
            case SQLITE_DONE:
                return values
            default:
                throw SQLiteReadError.stepFailed
            }
        }
    }
}

struct SQLiteRow {
    let statement: OpaquePointer

    func text(at index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, index)
        else { return nil }
        return String(cString: value)
    }

    func int64(at index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }
}

enum SQLiteReadError: Error {
    case openFailed
    case closed
    case prepareFailed
    case stepFailed
}
