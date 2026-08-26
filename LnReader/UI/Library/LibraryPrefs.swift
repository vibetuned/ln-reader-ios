import Foundation
import LnReaderCore

/// Single source of truth for the library sort preferences and the ordering
/// they produce — shared by the library grid and collection advancing, like
/// Android's CollectionOrdering.
enum LibraryPrefs {
    static let sortFieldKey = "library.sortField"
    static let sortAscendingKey = "library.sortAscending"

    static func manualModeKey(_ collectionId: String) -> String {
        "library.collection.\(collectionId).manual"
    }

    static func manualOrderKey(_ collectionId: String) -> String {
        "library.collection.\(collectionId).order"
    }

    /// Books in the order the library shows them for this collection:
    /// the per-collection manual arrangement when enabled, otherwise the
    /// app-wide field + direction.
    static func orderedBooks(
        _ books: [Book],
        collectionId: String?,
        defaults: UserDefaults = .standard
    ) -> [Book] {
        if let collectionId, defaults.bool(forKey: manualModeKey(collectionId)) {
            let order = defaults.stringArray(forKey: manualOrderKey(collectionId)) ?? []
            let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
            // Books added after the arrangement go last, in import order.
            return books
                .sorted { $0.importedAt < $1.importedAt }
                .enumerated()
                .sorted { lhs, rhs in
                    let l = position[lhs.element.id] ?? order.count + lhs.offset
                    let r = position[rhs.element.id] ?? order.count + rhs.offset
                    return l < r
                }
                .map(\.element)
        }
        let field = defaults.string(forKey: sortFieldKey)
            .flatMap(LibrarySortField.init(rawValue:)) ?? .dateAdded
        let ascending = defaults.object(forKey: sortAscendingKey) as? Bool ?? false
        let sorted: [Book] = switch field {
        case .name:
            books.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .dateAdded:
            books.sorted { $0.importedAt < $1.importedAt }
        }
        return ascending ? sorted : sorted.reversed()
    }
}
