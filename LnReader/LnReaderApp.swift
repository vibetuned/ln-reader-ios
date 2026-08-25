import SwiftUI

@main
struct LnReaderApp: App {
    private let container: AppContainer
    @State private var engine: PlayerEngine
    @State private var sleepTimer: SleepTimerController
    @State private var navigation = AppNavigation()

    init() {
        let container = AppContainer()
        self.container = container
        let engine = PlayerEngine(
            bookRepository: container.bookRepository,
            positionRepository: container.positionRepository,
            fileStore: container.fileStore
        )
        _engine = State(initialValue: engine)
        _sleepTimer = State(initialValue: SleepTimerController(engine: engine))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.appContainer, container)
                .environment(engine)
                .environment(sleepTimer)
                .environment(navigation)
                .task { await onLaunch() }
        }
    }

    private func onLaunch() async {
        #if DEBUG
        await autoImportIfRequested()
        #endif
        await restoreLastBook()
        #if DEBUG
        // Dev hooks for scripted smoke tests.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-armChapterTimer") {
            sleepTimer.start(SleepTimerConfig(mode: .chapters(count: 1), fadeOutSeconds: 10))
            navigation.selectedTab = .timer
        }
        if arguments.contains("-showImages") {
            navigation.selectedTab = .images
        }
        #endif
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
            let sourceURL = URL(fileURLWithPath: arguments[flag + 1])
            let book = try await container.bookRepository.importBook(from: sourceURL)
            print("autoImport: imported \(book.title)")
            // Attach sibling companions when they sit next to the m4b
            // (ln-vox output layout: book.m4b + *.epub + sync_manifest.json).
            let siblings = (try? FileManager.default.contentsOfDirectory(
                at: sourceURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
            if let epub = siblings.first(where: { $0.pathExtension == "epub" }) {
                try await container.bookRepository.attachEpub(bookId: book.id, from: epub)
                print("autoImport: attached \(epub.lastPathComponent)")
            }
            if let sync = siblings.first(where: { $0.lastPathComponent == "sync_manifest.json" }) {
                try await container.bookRepository.attachSync(bookId: book.id, from: sync)
                print("autoImport: attached \(sync.lastPathComponent)")
            }
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
