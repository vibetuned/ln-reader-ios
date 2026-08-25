import Foundation
import GRDB

/// Owns the GRDB database. Migrations are incremental and non-destructive —
/// same policy as the Android app (real users on the store).
public struct AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    /// Opens (and migrates) the database at `url`, creating directories as needed.
    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: url.path)
        try Self.migrator.migrate(queue)
        writer = queue
    }

    /// In-memory database for tests and previews.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(existingWriter: DatabaseQueue())
    }

    private init(existingWriter: any DatabaseWriter) throws {
        writer = existingWriter
        try Self.migrator.migrate(writer)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "collection") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "book") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("author", .text)
                t.column("album", .text)
                t.column("durationMs", .integer).notNull()
                t.column("audioPath", .text).notNull()
                t.column("coverPath", .text)
                t.column("fileSize", .integer).notNull()
                t.column("importedAt", .datetime).notNull()
                t.column("epubPath", .text)
                t.column("syncPath", .text)
                t.column("collectionId", .text)
                    .references("collection", onDelete: .setNull)
            }
            try db.create(table: "chapter") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("bookId", .text).notNull()
                    .references("book", onDelete: .cascade)
                    .indexed()
                t.column("orderIndex", .integer).notNull()
                t.column("title", .text).notNull()
                t.column("startMs", .integer).notNull()
            }
            try db.create(table: "embeddedImage") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("bookId", .text).notNull()
                    .references("book", onDelete: .cascade)
                    .indexed()
                t.column("orderIndex", .integer).notNull()
                t.column("mimeType", .text).notNull()
                t.column("cachePath", .text).notNull()
            }
            try db.create(table: "position") { t in
                t.primaryKey("bookId", .text)
                    .references("book", onDelete: .cascade)
                t.column("positionMs", .integer).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }

        return migrator
    }
}
