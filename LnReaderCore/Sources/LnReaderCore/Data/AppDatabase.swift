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

        // v2: EPUB-only books and the usage log (mirrors Android Room v6).
        // - `book.mediaKind` tells an EPUB-only book from an audiobook; existing rows are audio.
        // - `readingPosition` is the reader's saved place per book, the EPUB counterpart of
        //   `position`; it cascades with the book like `position` does.
        // - `readLog` records listening / reading sessions for the usage time-series. No foreign
        //   key on purpose: history should survive the book leaving the library.
        migrator.registerMigration("v2") { db in
            try db.alter(table: "book") { t in
                t.add(column: "mediaKind", .text).notNull().defaults(to: MediaKind.audio)
            }
            try db.create(table: "readingPosition") { t in
                t.primaryKey("bookId", .text)
                    .references("book", onDelete: .cascade)
                t.column("spineIndex", .integer).notNull()
                t.column("scrollFraction", .double).notNull()
                t.column("spineCount", .integer).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "readLog") { t in
                t.primaryKey("id", .text)
                t.column("bookId", .text).notNull().indexed()
                t.column("bookTitle", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("startedAt", .datetime).notNull().indexed()
                t.column("endedAt", .datetime).notNull()
                t.column("startPosition", .integer).notNull()
                t.column("endPosition", .integer).notNull()
            }
        }

        // v3: `book.spineCount` — an EPUB-only book's page count, taken at import so the library
        // tile can read "6 / 45" without opening the EPUB. Audiobooks keep the default 0.
        migrator.registerMigration("v3") { db in
            try db.alter(table: "book") { t in
                t.add(column: "spineCount", .integer).notNull().defaults(to: 0)
            }
        }

        return migrator
    }
}
