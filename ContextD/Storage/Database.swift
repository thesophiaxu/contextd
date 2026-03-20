import Foundation
import GRDB

/// Manages the SQLite database using GRDB with WAL mode and FTS5.
/// Handles schema creation, migrations, and provides the shared DatabasePool.
final class AppDatabase: Sendable {
    /// The GRDB database pool (WAL mode: concurrent reads, serial writes).
    let dbPool: DatabasePool

    private static let logger = DualLogger(category: "Database")

    /// Initialize the database at the default application support location.
    init() throws {
        let dbPath = try AppDatabase.databasePath()
        dbPool = try DatabasePool(path: dbPath)
        try migrator.migrate(dbPool)
        AppDatabase.logger.info("Database initialized at \(dbPath)")
    }

    /// Initialize with a custom path (for testing).
    init(path: String) throws {
        dbPool = try DatabasePool(path: path)
        try migrator.migrate(dbPool)
    }

    // MARK: - Database Path

    private static func databasePath() throws -> String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("ContextD", isDirectory: true)

        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        return appSupport.appendingPathComponent("contextd.sqlite").path
    }

    // MARK: - Migrations

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // Always reset the database in development for schema changes.
        // Remove this in production!
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1_createCaptures") { db in
            try db.create(table: "captures") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .double).notNull()
                t.column("appName", .text).notNull()
                t.column("appBundleID", .text)
                t.column("windowTitle", .text)
                t.column("ocrText", .text).notNull()
                t.column("fullOcrText", .text).notNull().defaults(to: "")
                t.column("visibleWindows", .text)
                t.column("textHash", .text).notNull()
                t.column("isSummarized", .boolean).notNull().defaults(to: false)
                t.column("frameType", .text).notNull().defaults(to: "keyframe")
                t.column("keyframeId", .integer)
                t.column("changePercentage", .double).notNull().defaults(to: 1.0)
            }

            try db.create(index: "idx_captures_timestamp", on: "captures", columns: ["timestamp"])
            try db.create(index: "idx_captures_app", on: "captures", columns: ["appName"])
            try db.create(index: "idx_captures_hash", on: "captures", columns: ["textHash"])
            try db.create(index: "idx_captures_keyframe", on: "captures", columns: ["keyframeId"])
            try db.create(index: "idx_captures_frametype", on: "captures", columns: ["frameType"])
        }

        migrator.registerMigration("v1_createCapturesFTS") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE captures_fts USING fts5(
                    ocrText,
                    windowTitle,
                    appName,
                    content=captures,
                    content_rowid=id,
                    tokenize='porter unicode61'
                )
                """)

            // Triggers to keep FTS in sync with the content table.
            // The FTS column name stays 'ocrText' for backward compat, but the VALUE
            // comes from fullOcrText (always has complete text for all frame types).
            try db.execute(sql: """
                CREATE TRIGGER captures_ai AFTER INSERT ON captures BEGIN
                    INSERT INTO captures_fts(rowid, ocrText, windowTitle, appName)
                    VALUES (new.id, new.fullOcrText, new.windowTitle, new.appName);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER captures_ad AFTER DELETE ON captures BEGIN
                    INSERT INTO captures_fts(captures_fts, rowid, ocrText, windowTitle, appName)
                    VALUES ('delete', old.id, old.fullOcrText, old.windowTitle, old.appName);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER captures_au AFTER UPDATE ON captures BEGIN
                    INSERT INTO captures_fts(captures_fts, rowid, ocrText, windowTitle, appName)
                    VALUES ('delete', old.id, old.fullOcrText, old.windowTitle, old.appName);
                    INSERT INTO captures_fts(rowid, ocrText, windowTitle, appName)
                    VALUES (new.id, new.fullOcrText, new.windowTitle, new.appName);
                END
                """)
        }

        migrator.registerMigration("v1_createSummaries") { db in
            try db.create(table: "summaries") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("startTimestamp", .double).notNull()
                t.column("endTimestamp", .double).notNull()
                t.column("appNames", .text)
                t.column("summary", .text).notNull()
                t.column("keyTopics", .text)
                t.column("captureIds", .text).notNull()
            }

            try db.create(index: "idx_summaries_time", on: "summaries",
                          columns: ["startTimestamp", "endTimestamp"])
        }

        migrator.registerMigration("v1_createSummariesFTS") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE summaries_fts USING fts5(
                    summary,
                    keyTopics,
                    appNames,
                    content=summaries,
                    content_rowid=id,
                    tokenize='porter unicode61'
                )
                """)

            try db.execute(sql: """
                CREATE TRIGGER summaries_ai AFTER INSERT ON summaries BEGIN
                    INSERT INTO summaries_fts(rowid, summary, keyTopics, appNames)
                    VALUES (new.id, new.summary, new.keyTopics, new.appNames);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER summaries_ad AFTER DELETE ON summaries BEGIN
                    INSERT INTO summaries_fts(summaries_fts, rowid, summary, keyTopics, appNames)
                    VALUES ('delete', old.id, old.summary, old.keyTopics, old.appNames);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER summaries_au AFTER UPDATE ON summaries BEGIN
                    INSERT INTO summaries_fts(summaries_fts, rowid, summary, keyTopics, appNames)
                    VALUES ('delete', old.id, old.summary, old.keyTopics, old.appNames);
                    INSERT INTO summaries_fts(rowid, summary, keyTopics, appNames)
                    VALUES (new.id, new.summary, new.keyTopics, new.appNames);
                END
                """)
        }

        migrator.registerMigration("v2_createTokenUsage") { db in
            try db.create(table: "token_usage") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .double).notNull()
                t.column("caller", .text).notNull()
                t.column("model", .text).notNull()
                t.column("inputTokens", .integer).notNull()
                t.column("outputTokens", .integer).notNull()
            }

            try db.create(index: "idx_token_usage_timestamp", on: "token_usage",
                          columns: ["timestamp"])
            try db.create(index: "idx_token_usage_caller", on: "token_usage",
                          columns: ["caller"])
        }

        return migrator
    }
}
