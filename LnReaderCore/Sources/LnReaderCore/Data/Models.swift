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
