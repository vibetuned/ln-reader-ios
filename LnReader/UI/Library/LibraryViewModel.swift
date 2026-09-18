import Foundation
import Observation
import LnReaderCore

enum LibrarySortField: String, CaseIterable {
    case name
    case dateAdded
}

/// What the sort menu offers: the two global fields, plus Manual inside a
/// collection (a per-collection hand-arranged order, like Android).
enum LibrarySortChoice: Hashable {
    case name
    case dateAdded
    case manual
}

/// Backs both the top-level library (collectionId == nil: collections first,
/// then loose books) and a single collection's view — mirroring Android's
/// reused LibraryScreen.
@MainActor
@Observable
final class LibraryViewModel {
    private let repository: BookRepository
    private let collectionRepository: CollectionRepository
    private let fileStore: FileStore
    private let defaults = UserDefaults.standard

    /// nil = top-level library.
    let collectionId: String?

    private(set) var allItems: [BookListItem] = []
    private(set) var collections: [CollectionListItem] = []
    private(set) var importPhase: ImportPhase?
    var importErrorMessage: String?

    // Sort field/direction are persisted app-wide, like Android's
    // LibraryPreferences; manual mode + arranged order are per-collection.
    var sortField: LibrarySortField {
        didSet { defaults.set(sortField.rawValue, forKey: LibraryPrefs.sortFieldKey) }
    }
    var sortAscending: Bool {
        didSet { defaults.set(sortAscending, forKey: LibraryPrefs.sortAscendingKey) }
    }
    private(set) var manualMode: Bool
    private var manualOrder: [String]

    var sortChoice: LibrarySortChoice {
        get {
            manualMode && collectionId != nil ? .manual : (sortField == .name ? .name : .dateAdded)
        }
        set {
            switch newValue {
            case .name:
                setManualMode(false)
                sortField = .name
            case .dateAdded:
                setManualMode(false)
                sortField = .dateAdded
            case .manual:
                guard collectionId != nil else { return }
                // Seed the arranged order from the current on-screen order.
                if manualOrder.isEmpty { manualOrder = sortedItems.map(\.id) }
                setManualMode(true)
                persistManualOrder()
            }
        }
    }

    /// Books scoped to this view (loose books at top level, members inside a collection).
    var sortedItems: [BookListItem] {
        let scoped = allItems.filter { $0.book.collectionId == collectionId }
        if manualMode, collectionId != nil {
            return applyManualOrder(to: scoped)
        }
        let sorted: [BookListItem]
        switch sortField {
        case .name:
            sorted = scoped.sorted {
                $0.book.title.localizedStandardCompare($1.book.title) == .orderedAscending
            }
        case .dateAdded:
            sorted = scoped.sorted { $0.book.importedAt < $1.book.importedAt }
        }
        return sortAscending ? sorted : sorted.reversed()
    }

    /// Reorders from the reorder sheet's drag; offsets are in sortedItems space.
    func moveManualItems(fromOffsets source: IndexSet, toOffset destination: Int) {
        var ids = sortedItems.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        manualOrder = ids
        persistManualOrder()
    }

    private func applyManualOrder(to items: [BookListItem]) -> [BookListItem] {
        let position = Dictionary(
            uniqueKeysWithValues: manualOrder.enumerated().map { ($1, $0) })
        // Books added after the arrangement (not in the stored order) go last,
        // keeping their import order among themselves.
        return items
            .sorted { $0.book.importedAt < $1.book.importedAt }
            .enumerated()
            .sorted { lhs, rhs in
                let l = position[lhs.element.id] ?? manualOrder.count + lhs.offset
                let r = position[rhs.element.id] ?? manualOrder.count + rhs.offset
                return l < r
            }
            .map(\.element)
    }

    private func setManualMode(_ enabled: Bool) {
        manualMode = enabled
        guard let collectionId else { return }
        defaults.set(enabled, forKey: LibraryPrefs.manualModeKey(collectionId))
    }

    private func persistManualOrder() {
        guard let collectionId else { return }
        defaults.set(manualOrder, forKey: LibraryPrefs.manualOrderKey(collectionId))
    }

    init(
        repository: BookRepository,
        collectionRepository: CollectionRepository,
        fileStore: FileStore,
        collectionId: String? = nil
    ) {
        self.repository = repository
        self.collectionRepository = collectionRepository
        self.fileStore = fileStore
        self.collectionId = collectionId
        sortField = defaults.string(forKey: LibraryPrefs.sortFieldKey)
            .flatMap(LibrarySortField.init(rawValue:)) ?? .dateAdded
        sortAscending = defaults.object(forKey: LibraryPrefs.sortAscendingKey) as? Bool ?? false
        if let collectionId {
            manualMode = defaults.bool(forKey: LibraryPrefs.manualModeKey(collectionId))
            manualOrder = defaults.stringArray(forKey: LibraryPrefs.manualOrderKey(collectionId)) ?? []
        } else {
            manualMode = false
            manualOrder = []
        }
    }

    func coverURL(for item: BookListItem) -> URL? {
        item.book.coverPath.map(fileStore.url(for:))
    }

    func coverURL(forPath path: String) -> URL {
        fileStore.url(for: path)
    }

    /// Runs until cancelled; call from `.task`.
    func observeBooks() async {
        do {
            for try await items in repository.observeBooks() {
                allItems = items
            }
        } catch {
            importErrorMessage = "Library observation failed: \(error.localizedDescription)"
        }
    }

    /// Runs until cancelled; call from `.task`.
    func observeCollections() async {
        do {
            for try await items in collectionRepository.observeCollections() {
                collections = items
            }
        } catch {
            importErrorMessage = "Collections observation failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Import / delete

    func importBook(from pickedURL: URL) async {
        guard importPhase == nil else { return }
        importPhase = .copying(bytesCopied: 0, totalBytes: 0)
        defer { importPhase = nil }
        do {
            let scoped = pickedURL.startAccessingSecurityScopedResource()
            defer { if scoped { pickedURL.stopAccessingSecurityScopedResource() } }
            try await repository.importBook(from: pickedURL, collectionId: collectionId) { phase in
                Task { @MainActor [weak self = self] in self?.importPhase = phase }
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

    // MARK: - Collections

    func createCollection(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await collectionRepository.create(name: trimmed)
        } catch {
            importErrorMessage = "Could not create collection: \(error.localizedDescription)"
        }
    }

    func addBook(bookId: String, toCollection collectionId: String) async {
        do {
            try await collectionRepository.addBook(bookId: bookId, to: collectionId)
        } catch {
            importErrorMessage = "Could not add to collection: \(error.localizedDescription)"
        }
    }

    func addBook(bookId: String, toNewCollectionNamed name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let collection = try await collectionRepository.create(name: trimmed)
            try await collectionRepository.addBook(bookId: bookId, to: collection.id)
        } catch {
            importErrorMessage = "Could not add to collection: \(error.localizedDescription)"
        }
    }

    func removeBookFromCollection(bookId: String) async {
        do {
            try await collectionRepository.removeBook(bookId: bookId)
        } catch {
            importErrorMessage = "Could not remove from collection: \(error.localizedDescription)"
        }
    }

    /// Deletes this view's collection. `deleteBooks` also deletes every book in
    /// it (files included); otherwise books move back to the top level.
    /// `onBookDeleted` lets the caller unload a deleted book from the player.
    func deleteCollection(deleteBooks: Bool, onBookDeleted: (String) -> Void) async {
        guard let collectionId else { return }
        do {
            if deleteBooks {
                for bookId in try await collectionRepository.bookIds(in: collectionId) {
                    onBookDeleted(bookId)
                    try await repository.delete(bookId: bookId)
                }
            }
            try await collectionRepository.delete(collectionId: collectionId)
        } catch {
            importErrorMessage = "Could not delete collection: \(error.localizedDescription)"
        }
    }

    // MARK: - Companions

    func attachEpub(bookId: String, from pickedURL: URL) async {
        await attachCompanion(pickedURL) {
            try await self.repository.attachEpub(bookId: bookId, from: $0)
        }
    }

    func attachSync(bookId: String, from pickedURL: URL) async {
        await attachCompanion(pickedURL) {
            try await self.repository.attachSync(bookId: bookId, from: $0)
        }
    }

    func detachEpub(bookId: String) async {
        try? await repository.detachEpub(bookId: bookId)
    }

    func detachSync(bookId: String) async {
        try? await repository.detachSync(bookId: bookId)
    }

    private func attachCompanion(_ pickedURL: URL, attach: (URL) async throws -> Void) async {
        do {
            let scoped = pickedURL.startAccessingSecurityScopedResource()
            defer { if scoped { pickedURL.stopAccessingSecurityScopedResource() } }
            try await attach(pickedURL)
        } catch {
            importErrorMessage = "Could not attach file: \(error.localizedDescription)"
        }
    }
}
