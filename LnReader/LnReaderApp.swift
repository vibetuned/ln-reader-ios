import SwiftUI

@main
struct LnReaderApp: App {
    private let container: AppContainer
    @State private var engine: PlayerEngine
    @State private var navigation = AppNavigation()

    init() {
        let container = AppContainer()
        self.container = container
        _engine = State(initialValue: PlayerEngine(
            bookRepository: container.bookRepository,
            positionRepository: container.positionRepository,
            fileStore: container.fileStore
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.appContainer, container)
                .environment(engine)
                .environment(navigation)
                .task { await onLaunch() }
        }
    }

    private func onLaunch() async {
        #if DEBUG
        await autoImportIfRequested()
        #endif
        await restoreLastBook()
    }

    /// On a fresh launch, reopen the last-played book paused at its saved
    /// position and show the player (mirrors Android's resume-on-launch).
    private func restoreLastBook() async {
        guard !container.lastBookRestoreHandled else { return }
        container.lastBookRestoreHandled = true
        guard engine.book == nil,
              let bookId = try? await container.positionRepository.lastPlayedBookId() else { return }
        await engine.open(bookId: bookId, autoPlay: false)
        if engine.book != nil {
            navigation.selectedTab = .player
        }
    }

    #if DEBUG
    /// Dev hook: `simctl launch booted com.vibetuned.lnreader -autoImport <path>`
    /// imports a book without driving the file picker (simulator can read host
    /// paths). Add `-autoPlay` to start playing it immediately.
    private func autoImportIfRequested() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-autoImport"), flag + 1 < arguments.count else { return }
        do {
            let book = try await container.bookRepository.importBook(
                from: URL(fileURLWithPath: arguments[flag + 1]))
            print("autoImport: imported \(book.title)")
            if arguments.contains("-autoPlay") {
                container.lastBookRestoreHandled = true
                await engine.open(bookId: book.id, autoPlay: true)
                navigation.selectedTab = .player
            }
        } catch {
            print("autoImport failed: \(error)")
        }
    }
    #endif
}
