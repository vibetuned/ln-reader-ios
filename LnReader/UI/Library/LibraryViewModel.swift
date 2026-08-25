import Foundation
import Observation
import LnReaderCore

enum LibrarySortField: String, CaseIterable {
    case name
    case dateAdded
}

@MainActor
@Observable
final class LibraryViewModel {
    private let repository: BookRepository
    private let fileStore: FileStore
    private let defaults = UserDefaults.standard

    private(set) var items: [BookListItem] = []
    private(set) var importPhase: ImportPhase?
    var importErrorMessage: String?

    // Sort is persisted app-wide, like Android's LibraryPreferences.
    var sortField: LibrarySortField {
        didSet { defaults.set(sortField.rawValue, forKey: "library.sortField") }
    }
    var sortAscending: Bool {
        didSet { defaults.set(sortAscending, forKey: "library.sortAscending") }
    }

    var sortedItems: [BookListItem] {
        let sorted: [BookListItem]
        switch sortField {
        case .name:
            sorted = items.sorted {
                $0.book.title.localizedStandardCompare($1.book.title) == .orderedAscending
            }
        case .dateAdded:
            sorted = items.sorted { $0.book.importedAt < $1.book.importedAt }
        }
        return sortAscending ? sorted : sorted.reversed()
    }

    init(repository: BookRepository, fileStore: FileStore) {
        self.repository = repository
        self.fileStore = fileStore
        sortField = defaults.string(forKey: "library.sortField")
            .flatMap(LibrarySortField.init(rawValue:)) ?? .dateAdded
        sortAscending = defaults.object(forKey: "library.sortAscending") as? Bool ?? false
    }

    func coverURL(for item: BookListItem) -> URL? {
        item.book.coverPath.map(fileStore.url(for:))
    }

    /// Runs until cancelled; call from `.task`.
    func observe() async {
        do {
            for try await items in repository.observeBooks() {
                self.items = items
            }
        } catch {
            importErrorMessage = "Library observation failed: \(error.localizedDescription)"
        }
    }

    func importBook(from pickedURL: URL) async {
        guard importPhase == nil else { return }
        importPhase = .copying(bytesCopied: 0, totalBytes: 0)
        defer { importPhase = nil }
        do {
            let scoped = pickedURL.startAccessingSecurityScopedResource()
            defer { if scoped { pickedURL.stopAccessingSecurityScopedResource() } }
            try await repository.importBook(from: pickedURL) { phase in
                Task { @MainActor [weak self] in self?.importPhase = phase }
            }
        } catch {
            importErrorMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    func delete(bookId: String) async {
        do {
            try await repository.delete(bookId: bookId)
        } catch {
            importErrorMessage = "Delete failed: \(error.localizedDescription)"
        }
    }
}
