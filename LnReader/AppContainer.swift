import SwiftUI
import LnReaderCore

/// Manual DI container, mirroring the Android app's AppContainer: process-scoped
/// lazy singletons, no framework. Reached from SwiftUI via `@Environment(\.appContainer)`.
final class AppContainer {
    /// Base directory for everything the app owns (database + book files).
    /// Application Support is backed up but not user-visible — the equivalent
    /// of Android's filesDir.
    let storeBaseURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LnReader")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private(set) lazy var fileStore = FileStore(baseURL: storeBaseURL)

    private(set) lazy var database: AppDatabase = {
        do {
            return try AppDatabase(url: storeBaseURL.appendingPathComponent("db/lnreader.sqlite"))
        } catch {
            fatalError("Could not open database: \(error)")
        }
    }()

    private(set) lazy var bookRepository = BookRepository(database: database, fileStore: fileStore)

    private(set) lazy var positionRepository = PositionRepository(database: database)

    private(set) lazy var collectionRepository = CollectionRepository(database: database)

    /// Guards "reopen last book once per launch" — process-scoped, like Android's
    /// AppContainer.lastBookRestoreHandled.
    var lastBookRestoreHandled = false
}

private struct AppContainerKey: EnvironmentKey {
    static let defaultValue = AppContainer()
}

extension EnvironmentValues {
    var appContainer: AppContainer {
        get { self[AppContainerKey.self] }
        set { self[AppContainerKey.self] = newValue }
    }
}
