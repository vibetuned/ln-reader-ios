import Foundation
import GRDB

/// The usage log: one row per listening or reading session, for the time-series view to come.
///
/// A row's life is start → heartbeat… → end. `start` opens it with `endedAt == startedAt`;
/// `heartbeat` advances `endedAt` while the session runs (a process killed mid-session still
/// leaves an honest duration, to within the heartbeat interval); `end` closes it. Callers hold the
/// returned id for the session's life and never reuse it.
///
/// Nothing here deletes rows when a book is removed: usage history outlives the book, which is
/// why each row snapshots the title.
public final class ReadLogRepository: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Opens a session and returns its id. `position` is playback ms (listen) or spine index (read).
    public func start(bookId: String, bookTitle: String, kind: ReadLogKind, position: Int64) async throws -> String {
        let now = Date()
        let entry = ReadLogEntry(
            id: UUID().uuidString,
            bookId: bookId,
            bookTitle: bookTitle,
            kind: kind,
            startedAt: now,
            endedAt: now,
            startPosition: position,
            endPosition: position
        )
        try await database.writer.write { db in try entry.insert(db) }
        return entry.id
    }

    /// Marks the session as still running, as of now, at `position`.
    public func heartbeat(sessionId: String, position: Int64) async throws {
        try await touch(sessionId: sessionId, position: position)
    }

    /// Closes the session as of now, at `position`. Idempotent.
    public func end(sessionId: String, position: Int64) async throws {
        try await touch(sessionId: sessionId, position: position)
    }

    private func touch(sessionId: String, position: Int64) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE readLog SET endedAt = ?, endPosition = ? WHERE id = ?",
                arguments: [Date(), position, sessionId])
        }
    }

    public func all() async throws -> [ReadLogEntry] {
        try await database.writer.read { db in
            try ReadLogEntry.order(Column("startedAt")).fetchAll(db)
        }
    }

    public func between(_ from: Date, _ to: Date) async throws -> [ReadLogEntry] {
        try await database.writer.read { db in
            try ReadLogEntry
                .filter(Column("startedAt") >= from && Column("startedAt") < to)
                .order(Column("startedAt"))
                .fetchAll(db)
        }
    }

    public func forBook(_ bookId: String) async throws -> [ReadLogEntry] {
        try await database.writer.read { db in
            try ReadLogEntry.filter(Column("bookId") == bookId).order(Column("startedAt")).fetchAll(db)
        }
    }
}
