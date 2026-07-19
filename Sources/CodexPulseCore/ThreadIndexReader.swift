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

final class ThreadIndexReader {
    private let codexHome: URL
    private var signature: String?
    private var cached: [String: ThreadMetadata] = [:]
    private(set) var status = SourceStatus(availability: .unavailable, issue: .missing)

    init(codexHome: URL) { self.codexHome = codexHome }

    func load(pinnedSessionID: String? = nil) -> [String: ThreadMetadata] {
        let candidates = CodexDatabaseDiscovery.candidates(prefix: "state_", in: codexHome)
        guard !candidates.isEmpty else {
            status = SourceStatus(availability: .unavailable, issue: .missing)
            return [:]
        }
        for databaseURL in candidates {
            let current = databaseSignature(databaseURL) + "|\(pinnedSessionID ?? "")"
            if current == signature { return cached }
            do {
                let rows = try Self.read(databaseURL, pinnedSessionID: pinnedSessionID)
                var index: [String: ThreadMetadata] = [:]
                for row in rows {
                    index[row.id] = row
                    index[URL(fileURLWithPath: row.rolloutPath).standardizedFileURL.path] = row
                }
                signature = current
                cached = index
                status = SourceStatus(availability: .available, observedAt: Date())
                return index
            } catch SQLiteReadError.incompatibleSchema {
                continue
            } catch {
                status = SourceStatus(
                    availability: cached.isEmpty ? .unavailable : .stale,
                    issue: .readFailed
                )
                return cached
            }
        }
        status = SourceStatus(availability: cached.isEmpty ? .unavailable : .stale, issue: .incompatible)
        return cached
    }

    private func databaseSignature(_ url: URL) -> String {
        [url, URL(fileURLWithPath: url.path + "-wal")].map { candidate in
            let values = try? candidate.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey]
            )
            return [
                String(values?.fileSize ?? -1),
                String(values?.contentModificationDate?.timeIntervalSince1970 ?? -1),
                String(describing: values?.fileResourceIdentifier)
            ].joined(separator: ":")
        }.joined(separator: "|")
    }

    private static func read(_ url: URL, pinnedSessionID: String?) throws -> [ThreadMetadata] {
        let database = try ReadOnlySQLite(url: url)
        defer { database.close() }
        let columns = try database.columnNames(table: "threads")
        guard columns.contains("id"), columns.contains("rollout_path") else {
            throw SQLiteReadError.incompatibleSchema
        }

        func expression(_ name: String, fallback: String = "NULL") -> String {
            columns.contains(name) ? "\"\(name)\"" : "\(fallback) AS \"\(name)\""
        }
        let selection = """
        \(expression("id")),
        \(expression("rollout_path")),
        \(expression("title")),
        \(expression("model")),
        \(expression("updated_at", fallback: "0")),
        \(expression("updated_at_ms", fallback: "0")),
        \(expression("archived", fallback: "0")),
        \(expression("agent_path")),
        \(expression("thread_source")),
        \(expression("preview"))
        """
        let activeClause = columns.contains("archived") ? "archived = 0" : "1 = 1"
        let orderColumn: String
        if columns.contains("updated_at_ms") { orderColumn = "updated_at_ms" }
        else if columns.contains("updated_at") { orderColumn = "updated_at" }
        else { orderColumn = "rowid" }

        let recentSQL = """
        SELECT \(selection)
        FROM threads
        WHERE \(activeClause)
        ORDER BY \(orderColumn) DESC
        LIMIT 64
        """
        var rows: [ThreadMetadata] = try database.query(recentSQL, transform: decodeRow)
        if let pinnedSessionID, !rows.contains(where: { $0.id == pinnedSessionID }) {
            let pinnedSQL = """
            SELECT \(selection)
            FROM threads
            WHERE \(activeClause) AND id = ?
            LIMIT 1
            """
            let pinned: [ThreadMetadata] = try database.query(
                pinnedSQL,
                textBindings: [pinnedSessionID],
                transform: decodeRow
            )
            rows.append(contentsOf: pinned)
        }
        return rows
    }

    private static func decodeRow(_ statement: SQLiteRow) -> ThreadMetadata? {
        guard let id = statement.text(at: 0), let rolloutPath = statement.text(at: 1) else { return nil }
        guard statement.int64(at: 6) == 0 else { return nil }
        let seconds = statement.int64(at: 4)
        let milliseconds = statement.int64(at: 5)
        let updatedAt = milliseconds > 0
            ? Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
            : Date(timeIntervalSince1970: Double(seconds))
        let model = statement.text(at: 3)
        let agentPath = statement.text(at: 7)
        let threadSource = statement.text(at: 8)
        let preview = statement.text(at: 9) ?? ""
        let isInternal = model?.caseInsensitiveCompare("codex-auto-review") == .orderedSame
            || !(agentPath?.isEmpty ?? true)
            || (threadSource.map { !$0.isEmpty && $0 != "user" } ?? false)
            || (statement.text(at: 9) != nil && preview.isEmpty)
        return ThreadMetadata(
            id: id,
            rolloutPath: rolloutPath,
            title: statement.text(at: 2),
            model: model,
            updatedAt: updatedAt,
            isInternal: isInternal
        )
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
        Set(try query("PRAGMA table_info(\"\(table)\")") { $0.text(at: 1) })
    }

    func query<T>(
        _ sql: String,
        textBindings: [String] = [],
        transform: (SQLiteRow) throws -> T?
    ) throws -> [T] {
        guard let handle else { throw SQLiteReadError.closed }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteReadError.prepareFailed
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in textBindings.enumerated() {
            let result = value.withCString { pointer in
                sqlite3_bind_text(
                    statement,
                    Int32(offset + 1),
                    pointer,
                    -1,
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                )
            }
            guard result == SQLITE_OK else { throw SQLiteReadError.bindFailed }
        }

        var values: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let value = try transform(SQLiteRow(statement: statement)) { values.append(value) }
            case SQLITE_DONE:
                return values
            case SQLITE_BUSY, SQLITE_LOCKED:
                throw SQLiteReadError.busy
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
              let value = sqlite3_column_text(statement, index) else { return nil }
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
    case bindFailed
    case stepFailed
    case busy
    case incompatibleSchema
}
