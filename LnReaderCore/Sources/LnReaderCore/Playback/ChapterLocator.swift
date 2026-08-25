import Foundation

/// The chapter containing a playback position, with its book-absolute window.
public struct ChapterWindow: Equatable, Sendable {
    public let index: Int
    public let title: String
    public let startMs: Int64
    public let endMs: Int64

    public var durationMs: Int64 { endMs - startMs }
}

/// Chapter math shared by the scrubber, the chapter list, and chapter skipping.
/// Chapters must be ordered by start time (they are stored that way).
public struct ChapterLocator: Sendable {
    public let chapters: [Chapter]
    public let bookDurationMs: Int64

    public init(chapters: [Chapter], bookDurationMs: Int64) {
        self.chapters = chapters
        self.bookDurationMs = bookDurationMs
    }

    /// The chapter whose window contains `positionMs`; nil when the book has no chapters.
    public func window(atMs positionMs: Int64) -> ChapterWindow? {
        guard !chapters.isEmpty else { return nil }
        // Binary search the last chapter whose start <= position.
        var lo = 0
        var hi = chapters.count - 1
        var found = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if chapters[mid].startMs <= positionMs {
                found = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return window(atIndex: found)
    }

    public func window(atIndex index: Int) -> ChapterWindow? {
        guard chapters.indices.contains(index) else { return nil }
        let chapter = chapters[index]
        let endMs = index + 1 < chapters.count ? chapters[index + 1].startMs : max(bookDurationMs, chapter.startMs)
        return ChapterWindow(index: index, title: chapter.title, startMs: chapter.startMs, endMs: endMs)
    }
}
