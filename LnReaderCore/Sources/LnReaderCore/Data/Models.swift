import Foundation
import GRDB

/// Schema notes vs the Android app (Room v5):
/// - No `uri` / `isDownloaded`: iOS always copies the picked file into the app
///   container at import (no SAF equivalent), so every book owns its audio file
///   at `audioPath`.
/// - All file paths are stored *relative* to the FileStore base directory —
///   the app container's absolute path can change across app updates/restores.
/// - `syncKey` (vestigial on Android) is dropped.
public struct Book: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var author: String?
    public var album: String?
    public var durationMs: Int64
    /// Relative path of the copied m4b audio file.
    public var audioPath: String
    /// Relative path of the cover image (first embedded image), if any.
    public var coverPath: String?
    public var fileSize: Int64
    public var importedAt: Date
    /// Relative path of the attached EPUB companion, if any.
    public var epubPath: String?
    /// Relative path of the attached sync manifest, if any.
    public var syncPath: String?
    /// nil = top-level library. A book belongs to at most one collection.
    public var collectionId: String?
    /// `MediaKind.audio` for an imported m4b (every pre-v2 row), `MediaKind.epub` for a book that
    /// is only an EPUB — no audio, so `audioPath` is empty and `durationMs` is 0. Read this rather
    /// than inferring from those; it's a flag beside a NOT NULL `audioPath` because flipping that
    /// column's nullability would mean rebuilding the table on installed databases.
    public var mediaKind: String = MediaKind.audio
    /// Number of pages (EPUB spine documents) for an EPUB-only book, captured at import so the
    /// library can show "6 / 45" before the book has ever been opened. 0 for audiobooks, and for
    /// EPUB-only rows imported before the column existed — the library falls back to the count the
    /// reader saved alongside the reading position for those.
    public var spineCount: Int = 0

    /// False for an EPUB-only book: nothing to play, so it opens in the reader instead.
    public var hasAudio: Bool { mediaKind == MediaKind.audio }
}

/// Values of `Book.mediaKind`. Mirrors Android's `MEDIA_KIND_*`.
public enum MediaKind {
    public static let audio = "audio"
    public static let epub = "epub"
}

/// Where the reader left off in a book — the EPUB analog of `PlaybackPosition`. An audiobook's
/// reader follows the narration, but an EPUB-only book has none, so this is the only record of the
/// reader's place: the spine page and how far down it was scrolled. `spineCount` rides along so the
/// library can draw progress without opening the EPUB.
public struct ReadingPosition: Codable, Equatable, Sendable {
    public var bookId: String
    public var spineIndex: Int
    /// 0…1 scroll offset within the page.
    public var scrollFraction: Double
    public var spineCount: Int
    public var updatedAt: Date

    public init(bookId: String, spineIndex: Int, scrollFraction: Double, spineCount: Int, updatedAt: Date) {
        self.bookId = bookId
        self.spineIndex = spineIndex
        self.scrollFraction = scrollFraction
        self.spineCount = spineCount
        self.updatedAt = updatedAt
    }

    /// 0…1 progress through the book by page, with the scroll within the current page.
    public var fraction: Double {
        guard spineCount > 0 else { return 0 }
        return min(1, max(0, (Double(spineIndex) + min(1, max(0, scrollFraction))) / Double(spineCount)))
    }
}

/// Kinds of `ReadLogEntry`. Mirrors Android's `READ_LOG_KIND_*`.
public enum ReadLogKind: String, Codable, Sendable {
    case listen
    case read
}

/// One session of using the app with a book — a stretch of listening or reading — for the usage
/// time-series. Opened when playback starts / the reader opens, closed when it stops; while open,
/// `endedAt` is advanced by a heartbeat so a killed process still leaves an honest row. Rows
/// outlive their book on purpose (deleting a finished book shouldn't erase the hours spent on it),
/// which is why `bookTitle` is snapshotted and there is no foreign key.
public struct ReadLogEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var bookId: String
    public var bookTitle: String
    public var kind: ReadLogKind
    public var startedAt: Date
    public var endedAt: Date
    /// Playback ms for a listen session, spine index for a read session.
    public var startPosition: Int64
    public var endPosition: Int64

    public var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }
}

public struct Chapter: Codable, Equatable, Sendable {
    public var id: Int64?
    public var bookId: String
    public var orderIndex: Int
    public var title: String
    public var startMs: Int64
}

public struct EmbeddedImage: Codable, Equatable, Sendable {
    public var id: Int64?
    public var bookId: String
    public var orderIndex: Int
    public var mimeType: String
    /// Relative path of the extracted image file.
    public var cachePath: String
}

public struct PlaybackPosition: Codable, Equatable, Sendable {
    public var bookId: String
    public var positionMs: Int64
    public var updatedAt: Date
}

public struct BookCollection: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var createdAt: Date
}

// MARK: - GRDB records

extension Book: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "book"
}

extension Chapter: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "chapter"
    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension EmbeddedImage: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "embeddedImage"
    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension PlaybackPosition: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "position"
}

extension BookCollection: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "collection"
}

extension ReadingPosition: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "readingPosition"
}

extension ReadLogEntry: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "readLog"
}
