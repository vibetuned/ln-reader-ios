import Foundation
import GRDB

/// Saved playback positions, keyed by book. Mirrors the Android PositionRepository.
public final class PositionRepository: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func get(bookId: String) async throws -> Int64? {
        try await database.writer.read { db in
            try PlaybackPosition.fetchOne(db, key: bookId)?.positionMs
        }
    }

    public func save(bookId: String, positionMs: Int64) async throws {
        try await database.writer.write { db in
            // A position for a deleted book must not resurrect a row (FK would throw anyway).
            guard try Book.exists(db, key: bookId) else { return }
            try PlaybackPosition(bookId: bookId, positionMs: positionMs, updatedAt: Date()).save(db)
        }
    }

    public func clear(bookId: String) async throws {
        _ = try await database.writer.write { db in
            try PlaybackPosition.deleteOne(db, key: bookId)
        }
    }

    /// The book with the most recently saved position — resume-on-launch.
    public func lastPlayedBookId() async throws -> String? {
        try await database.writer.read { db in
            try PlaybackPosition
                .order(Column("updatedAt").desc)
                .fetchOne(db)?
                .bookId
        }
    }
}
