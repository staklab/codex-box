import Foundation
import SQLite3

private let sqliteFixtureTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum RuntimeSQLiteFixtureSupport {
    struct ThreadRow {
        let id: String
        let source: String
        let cwd: String
        let title: String
        let createdAt: Int64
        let updatedAt: Int64
        let archived: Int

        init(
            id: String,
            source: String,
            cwd: String,
            title: String,
            createdAt: Int64,
            updatedAt: Int64,
            archived: Int = 0
        ) {
            self.id = id
            self.source = source
            self.cwd = cwd
            self.title = title
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.archived = archived
        }
    }

    struct LogRow {
        let threadID: String
        let timestamp: Int64
        let target: String
        let body: String?

        init(threadID: String, timestamp: Int64, target: String, body: String? = nil) {
            self.threadID = threadID
            self.timestamp = timestamp
            self.target = target
            self.body = body
        }
    }

    enum LogsSchema {
        case current
        case legacyCreatedAtAndBody
        case incompatibleMissingBody
    }

    static func writeStateDatabase(
        at url: URL,
        threads: [ThreadRow]
    ) throws {
        try self.withDatabase(at: url) { database in
            try self.exec(
                """
                CREATE TABLE threads (
                    id TEXT PRIMARY KEY,
                    source TEXT NOT NULL,
                    cwd TEXT NOT NULL,
                    title TEXT NOT NULL,
                    archived INTEGER NOT NULL DEFAULT 0,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL
                );
                """,
                in: database
            )

            let statement = try SQLiteFixtureStatement(
                database: database,
                sql: """
                INSERT INTO threads (id, source, cwd, title, archived, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """
            )

            for thread in threads {
                try statement.reset()
                try statement.bindText(thread.id, at: 1)
                try statement.bindText(thread.source, at: 2)
                try statement.bindText(thread.cwd, at: 3)
                try statement.bindText(thread.title, at: 4)
                try statement.bindInt(thread.archived, at: 5)
                try statement.bindInt64(thread.createdAt, at: 6)
                try statement.bindInt64(thread.updatedAt, at: 7)
                try statement.step()
            }
        }
    }

    static func writeLogsDatabase(
        at url: URL,
        logs: [LogRow],
        schema: LogsSchema = .current
    ) throws {
        try self.withDatabase(at: url) { database in
            switch schema {
            case .current:
                try self.exec(
                    """
                    CREATE TABLE logs (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        ts INTEGER NOT NULL,
                        thread_id TEXT,
                        target TEXT NOT NULL,
                        feedback_log_body TEXT
                    );
                    """,
                    in: database
                )

                let statement = try SQLiteFixtureStatement(
                    database: database,
                    sql: """
                    INSERT INTO logs (ts, thread_id, target, feedback_log_body)
                    VALUES (?, ?, ?, ?)
                    """
                )

                for log in logs {
                    try statement.reset()
                    try statement.bindInt64(log.timestamp, at: 1)
                    try statement.bindText(log.threadID, at: 2)
                    try statement.bindText(log.target, at: 3)
                    try statement.bindOptionalText(log.body, at: 4)
                    try statement.step()
                }

            case .legacyCreatedAtAndBody:
                try self.exec(
                    """
                    CREATE TABLE logs (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        created_at INTEGER NOT NULL,
                        thread_id TEXT,
                        target TEXT NOT NULL,
                        body TEXT
                    );
                    """,
                    in: database
                )

                let statement = try SQLiteFixtureStatement(
                    database: database,
                    sql: """
                    INSERT INTO logs (created_at, thread_id, target, body)
                    VALUES (?, ?, ?, ?)
                    """
                )

                for log in logs {
                    try statement.reset()
                    try statement.bindInt64(log.timestamp, at: 1)
                    try statement.bindText(log.threadID, at: 2)
                    try statement.bindText(log.target, at: 3)
                    try statement.bindOptionalText(log.body, at: 4)
                    try statement.step()
                }

            case .incompatibleMissingBody:
                try self.exec(
                    """
                    CREATE TABLE logs (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        ts INTEGER NOT NULL,
                        thread_id TEXT,
                        target TEXT NOT NULL
                    );
                    """,
                    in: database
                )
            }
        }
    }

    private static func withDatabase(
        at url: URL,
        work: (OpaquePointer) throws -> Void
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: url)

        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            let message: String
            if let database, let pointer = sqlite3_errmsg(database) {
                message = String(cString: pointer)
            } else {
                message = "unable to open sqlite fixture"
            }
            sqlite3_close(database)
            throw NSError(domain: "RuntimeSQLiteFixtureSupport", code: 1, userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }

        defer { sqlite3_close(database) }
        try work(database)
    }

    private static func exec(_ sql: String, in database: OpaquePointer) throws {
        var errorPointer: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(database, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "sqlite exec failed"
            sqlite3_free(errorPointer)
            throw NSError(domain: "RuntimeSQLiteFixtureSupport", code: 2, userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }
    }
}

private final class SQLiteFixtureStatement {
    let handle: OpaquePointer
    private let database: OpaquePointer

    init(database: OpaquePointer, sql: String) throws {
        self.database = database

        var handle: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &handle, nil) == SQLITE_OK, let handle else {
            throw NSError(domain: "RuntimeSQLiteFixtureSupport", code: 3, userInfo: [
                NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database)),
            ])
        }

        self.handle = handle
    }

    deinit {
        sqlite3_finalize(self.handle)
    }

    func reset() throws {
        guard sqlite3_reset(self.handle) == SQLITE_OK,
              sqlite3_clear_bindings(self.handle) == SQLITE_OK else {
            throw NSError(domain: "RuntimeSQLiteFixtureSupport", code: 4, userInfo: [
                NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(self.database)),
            ])
        }
    }

    func bindText(_ value: String, at index: Int32) throws {
        guard sqlite3_bind_text(self.handle, index, value, -1, sqliteFixtureTransientDestructor) == SQLITE_OK else {
            throw NSError(domain: "RuntimeSQLiteFixtureSupport", code: 5, userInfo: [
                NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(self.database)),
            ])
        }
    }

    func bindOptionalText(_ value: String?, at index: Int32) throws {
        guard let value else {
            guard sqlite3_bind_null(self.handle, index) == SQLITE_OK else {
                throw NSError(domain: "RuntimeSQLiteFixtureSupport", code: 6, userInfo: [
                    NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(self.database)),
                ])
            }
            return
        }
        try self.bindText(value, at: index)
    }

    func bindInt(_ value: Int, at index: Int32) throws {
        guard sqlite3_bind_int(self.handle, index, Int32(value)) == SQLITE_OK else {
            throw NSError(domain: "RuntimeSQLiteFixtureSupport", code: 7, userInfo: [
                NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(self.database)),
            ])
        }
    }

    func bindInt64(_ value: Int64, at index: Int32) throws {
        guard sqlite3_bind_int64(self.handle, index, value) == SQLITE_OK else {
            throw NSError(domain: "RuntimeSQLiteFixtureSupport", code: 8, userInfo: [
                NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(self.database)),
            ])
        }
    }

    func step() throws {
        guard sqlite3_step(self.handle) == SQLITE_DONE else {
            throw NSError(domain: "RuntimeSQLiteFixtureSupport", code: 9, userInfo: [
                NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(self.database)),
            ])
        }
    }
}
