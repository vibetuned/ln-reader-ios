import Foundation
import Observation
import LnReaderCore

struct CollectionEndPrompt: Identifiable {
    let finished: Book
    let previous: Book?
    let next: Book?
    var id: String { finished.id }
}

/// Watches for a natural end of book and, when the finished book belongs to a
/// collection, offers the neighboring books — the iOS analog of Android's
/// CollectionAdvanceController. Because it hangs off the engine directly, it
/// fires no matter which screen is showing.
@MainActor
@Observable
final class CollectionAdvanceController {
    private(set) var prompt: CollectionEndPrompt?

    private let engine: PlayerEngine
    private let bookRepository: BookRepository
    private let fileStore: FileStore

    init(engine: PlayerEngine, bookRepository: BookRepository, fileStore: FileStore) {
        self.engine = engine
        self.bookRepository = bookRepository
        self.fileStore = fileStore
        engine.onBookFinished = { [weak self] book in
            Task { @MainActor in await self?.bookFinished(book) }
        }
    }

    private func bookFinished(_ book: Book) async {
        guard let collectionId = book.collectionId,
              let books = try? await bookRepository.books(inCollection: collectionId) else { return }
        // Neighbors follow the same order the collection shows in the library.
        let ordered = LibraryPrefs.orderedBooks(books, collectionId: collectionId)
        guard let index = ordered.firstIndex(where: { $0.id == book.id }) else { return }
        let previous = index > 0 ? ordered[index - 1] : nil
        let next = index + 1 < ordered.count ? ordered[index + 1] : nil
        guard previous != nil || next != nil else { return }
        prompt = CollectionEndPrompt(finished: book, previous: previous, next: next)
    }

    func continueTo(bookId: String) {
        prompt = nil
        Task { await engine.open(bookId: bookId, autoPlay: true) }
    }

    func dismiss() {
        prompt = nil
    }

    func coverURL(for book: Book) -> URL? {
        book.coverPath.map(fileStore.url(for:))
    }
}
