import Foundation
import GRDB

public enum ImportPhase: Equatable, Sendable {
    case copying(bytesCopied: Int64, totalBytes: Int64)
    case parsing
    case finalizing
}

public enum ImportError: Error {
    case unreadableSource(URL)
}

/// A book joined with its saved playback position (drives the library progress bars).
public struct BookListItem: Equatable, Identifiable, Sendable {
    public let book: Book
    public let positionMs: Int64?
    public var id: String { book.id }

    /// 0…1 whole-book progress, nil when never played.
    public var progress: Double? {
        guard let positionMs, book.durationMs > 0 else { return nil }
        return min(1, max(0, Double(positionMs) / Double(book.durationMs)))
    }
}

public struct BookDetail: Equatable, Sendable {
    public let book: Book
    public let chapters: [Chapter]
    public let images: [EmbeddedImage]
}

public final class BookRepository: Sendable {
    private let database: AppDatabase
    private let fileStore: FileStore

    public init(database: AppDatabase, fileStore: FileStore) {
        self.database = database
        self.fileStore = fileStore
    }

    // MARK: - Observation

    /// All books with their playback positions, unsorted (sorting is a UI concern).
    public func observeBooks() -> AsyncValueObservation<[BookListItem]> {
        ValueObservation
            .tracking { db in
                let books = try Book.fetchAll(db)
                let positions = try PlaybackPosition.fetchAll(db)
                let positionsByBook = Dictionary(uniqueKeysWithValues: positions.map { ($0.bookId, $0.positionMs) })
                return books.map { BookListItem(book: $0, positionMs: positionsByBook[$0.id]) }
            }
            .values(in: database.writer)
    }

    public func observeDetail(bookId: String) -> AsyncValueObservation<BookDetail?> {
        ValueObservation
            .tracking { db in
                guard let book = try Book.fetchOne(db, key: bookId) else { return nil }
                return try BookDetail(
                    book: book,
                    chapters: Chapter
                        .filter(Column("bookId") == bookId)
                        .order(Column("orderIndex"))
                        .fetchAll(db),
                    images: EmbeddedImage
                        .filter(Column("bookId") == bookId)
                        .order(Column("orderIndex"))
                        .fetchAll(db)
                )
            }
            .values(in: database.writer)
    }

    public func books(inCollection collectionId: String) async throws -> [Book] {
        try await database.writer.read { db in
            try Book.filter(Column("collectionId") == collectionId).fetchAll(db)
        }
    }

    public func detail(bookId: String) async throws -> BookDetail? {
        try await database.writer.read { db in
            guard let book = try Book.fetchOne(db, key: bookId) else { return nil }
            return try BookDetail(
                book: book,
                chapters: Chapter
                    .filter(Column("bookId") == bookId)
                    .order(Column("orderIndex"))
                    .fetchAll(db),
                images: EmbeddedImage
                    .filter(Column("bookId") == bookId)
                    .order(Column("orderIndex"))
                    .fetchAll(db)
            )
        }
    }

    // MARK: - Import

    /// Copies the source m4b into the app's file store, parses it, extracts the
    /// embedded images, and inserts the book. The caller is responsible for
    /// security-scoped access to `sourceURL` for the duration of the call.
    /// Any failure cleans up the partial files.
    @discardableResult
    public func importBook(
        from sourceURL: URL,
        collectionId: String? = nil,
        onProgress: @escaping @Sendable (ImportPhase) -> Void = { _ in }
    ) async throws -> Book {
        let bookId = UUID().uuidString
        let fm = FileManager.default
        do {
            // 1. Copy into books/<id>/<original name> in chunks, reporting progress.
            let fileName = sourceURL.lastPathComponent
            let bookDir = fileStore.bookDir(bookId: bookId)
            try fm.createDirectory(at: bookDir, withIntermediateDirectories: true)
            let audioURL = bookDir.appendingPathComponent(fileName)
            let totalBytes = (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                .map(Int64.init) ?? 0
            onProgress(.copying(bytesCopied: 0, totalBytes: totalBytes))
            let copied = try Self.copyFile(from: sourceURL, to: audioURL) { bytesCopied in
                onProgress(.copying(bytesCopied: bytesCopied, totalBytes: totalBytes))
            }

            // 2. Parse metadata from the local copy.
            onProgress(.parsing)
            let source = try FileM4bSource(url: audioURL)
            defer { source.close() }
            let parsed = try M4bParser().parse(source: source)

            // 3. Extract embedded images to books/<id>/images/.
            onProgress(.finalizing)
            let imagesDir = fileStore.imagesDir(bookId: bookId)
            var imageRecords: [EmbeddedImage] = []
            if !parsed.images.isEmpty {
                try fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
                for (index, image) in parsed.images.enumerated() {
                    let ext = image.mimeType == "image/png" ? "png" : "jpg"
                    let imageURL = imagesDir.appendingPathComponent("\(index).\(ext)")
                    try image.bytes.write(to: imageURL)
                    imageRecords.append(EmbeddedImage(
                        id: nil,
                        bookId: bookId,
                        orderIndex: index,
                        mimeType: image.mimeType,
                        cachePath: fileStore.relativePath(of: imageURL)
                    ))
                }
            }

            // 4. Insert book + chapters + images in one transaction.
            let book = Book(
                id: bookId,
                title: parsed.title ?? fileName.replacingOccurrences(of: ".m4b", with: ""),
                author: parsed.author,
                album: parsed.album,
                durationMs: parsed.durationMs,
                audioPath: fileStore.relativePath(of: audioURL),
                coverPath: imageRecords.first?.cachePath,
                fileSize: copied,
                importedAt: Date(),
                epubPath: nil,
                syncPath: nil,
                collectionId: collectionId
            )
            let chapters = parsed.chapters.enumerated().map { index, chapter in
                Chapter(id: nil, bookId: bookId, orderIndex: index, title: chapter.title, startMs: chapter.startMs)
            }
            let images = imageRecords
            try await database.writer.write { db in
                try book.insert(db)
                for var chapter in chapters { try chapter.insert(db) }
                for var image in images { try image.insert(db) }
            }
            return book
        } catch {
            fileStore.deleteBookFiles(bookId: bookId)
            throw error
        }
    }

    // MARK: - Companions

    /// Copies an EPUB companion into the store and records it on the book.
    public func attachEpub(bookId: String, from sourceURL: URL) async throws {
        try await attachCompanion(bookId: bookId, from: sourceURL, fileName: "book.epub", column: "epubPath")
        // A stale extraction from a previously attached EPUB must not survive.
        try? FileManager.default.removeItem(at: fileStore.epubExtractionDir(bookId: bookId))
    }

    /// Copies a sync manifest companion into the store and records it on the book.
    public func attachSync(bookId: String, from sourceURL: URL) async throws {
        try await attachCompanion(bookId: bookId, from: sourceURL, fileName: "sync.json", column: "syncPath")
    }

    public func detachEpub(bookId: String) async throws {
        try await detachCompanion(bookId: bookId, fileName: "book.epub", column: "epubPath")
        try? FileManager.default.removeItem(at: fileStore.epubExtractionDir(bookId: bookId))
    }

    public func detachSync(bookId: String) async throws {
        try await detachCompanion(bookId: bookId, fileName: "sync.json", column: "syncPath")
    }

    private func attachCompanion(bookId: String, from sourceURL: URL, fileName: String, column: String) async throws {
        let dir = fileStore.companionsDir(bookId: bookId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: destination)
        _ = try Self.copyFile(from: sourceURL, to: destination) { _ in }
        let relative = fileStore.relativePath(of: destination)
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE book SET \(column) = ? WHERE id = ?", arguments: [relative, bookId])
        }
    }

    private func detachCompanion(bookId: String, fileName: String, column: String) async throws {
        try? FileManager.default.removeItem(
            at: fileStore.companionsDir(bookId: bookId).appendingPathComponent(fileName))
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE book SET \(column) = NULL WHERE id = ?", arguments: [bookId])
        }
    }

    // MARK: - Delete

    /// Removes the book row (chapters/images/position cascade) and all its files.
    public func delete(bookId: String) async throws {
        _ = try await database.writer.write { db in
            try Book.deleteOne(db, key: bookId)
        }
        fileStore.deleteBookFiles(bookId: bookId)
    }

    // MARK: - Helpers

    /// Chunked copy with progress. Returns bytes copied.
    private static func copyFile(
        from source: URL,
        to destination: URL,
        chunkSize: Int = 8 << 20,
        onProgress: (Int64) -> Void
    ) throws -> Int64 {
        guard let input = InputStream(url: source) else {
            throw ImportError.unreadableSource(source)
        }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        input.open()
        defer { input.close() }

        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var total: Int64 = 0
        while true {
            let read = input.read(&buffer, maxLength: chunkSize)
            if read < 0 { throw input.streamError ?? ImportError.unreadableSource(source) }
            if read == 0 { break }
            try output.write(contentsOf: Data(bytes: buffer, count: read))
            total += Int64(read)
            onProgress(total)
        }
        return total
    }
}
