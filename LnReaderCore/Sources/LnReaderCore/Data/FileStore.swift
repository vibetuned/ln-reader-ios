import Foundation

/// Owns the on-disk layout under a base directory (Application Support on iOS,
/// a temp dir in tests). The database stores paths *relative* to `baseURL`
/// because the iOS app container path can change across updates/restores.
///
/// ```
/// <base>/
///   books/<bookId>/<original name>.m4b     copied audio
///   books/<bookId>/images/<idx>.{jpg|png}  extracted embedded images
///   companions/<bookId>/{book.epub, sync.json}
///   epubs/<bookId>/…                       extracted EPUB working tree
/// ```
public struct FileStore: Sendable {
    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    public func url(for relativePath: String) -> URL {
        baseURL.appendingPathComponent(relativePath)
    }

    public func relativePath(of url: URL) -> String {
        let base = baseURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { return path }
        return String(path.dropFirst(base.count + 1))
    }

    public func bookDir(bookId: String) -> URL {
        baseURL.appendingPathComponent("books/\(bookId)")
    }

    public func imagesDir(bookId: String) -> URL {
        bookDir(bookId: bookId).appendingPathComponent("images")
    }

    public func companionsDir(bookId: String) -> URL {
        baseURL.appendingPathComponent("companions/\(bookId)")
    }

    public func epubExtractionDir(bookId: String) -> URL {
        baseURL.appendingPathComponent("epubs/\(bookId)")
    }

    /// Removes every file owned by a book (audio, images, companions, extracted EPUB).
    public func deleteBookFiles(bookId: String) {
        let fm = FileManager.default
        try? fm.removeItem(at: bookDir(bookId: bookId))
        try? fm.removeItem(at: companionsDir(bookId: bookId))
        try? fm.removeItem(at: epubExtractionDir(bookId: bookId))
    }
}
