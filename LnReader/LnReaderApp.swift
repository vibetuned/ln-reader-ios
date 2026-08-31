import SwiftUI
import LnReaderCore

@main
struct LnReaderApp: App {
    private let container: AppContainer
    @State private var engine: PlayerEngine
    @State private var sleepTimer: SleepTimerController
    @State private var collectionAdvance: CollectionAdvanceController
    @State private var cast: CastController
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
        _collectionAdvance = State(initialValue: CollectionAdvanceController(
            engine: engine,
            bookRepository: container.bookRepository,
            fileStore: container.fileStore
        ))
        _cast = State(initialValue: CastController(
            engine: engine,
            bookRepository: container.bookRepository,
            fileStore: container.fileStore
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.appContainer, container)
                .environment(engine)
                .environment(sleepTimer)
                .environment(collectionAdvance)
                .environment(cast)
                .environment(navigation)
                .task { await onLaunch() }
                .onOpenURL { url in
                    Task { await handleIncomingFile(url) }
                }
        }
    }

    /// Files arriving via AirDrop / "Open in…": an .m4b imports straight into
    /// the library; an .epub or sync .json waits for the user to pick the book
    /// to attach it to (sheet hosted by the Library).
    private func handleIncomingFile(_ url: URL) async {
        navigation.selectedTab = .library
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        switch url.pathExtension.lowercased() {
        case "m4b", "m4a":
            do {
                let book = try await container.bookRepository.importBook(from: url)
                print("openURL: imported \(book.title)")
                try? FileManager.default.removeItem(at: url) // Inbox copy
            } catch {
                print("openURL import failed: \(error)")
            }
        case "epub", "json":
            navigation.pendingAttachment = url
        default:
            break
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
        if let index = arguments.firstIndex(of: "-armTimer"), index + 1 < arguments.count,
           let minutes = Int(arguments[index + 1]) {
            sleepTimer.start(SleepTimerConfig(mode: .time(minutes: minutes), fadeOutSeconds: 10))
            navigation.selectedTab = .timer
        }
        if arguments.contains("-showImages") {
            navigation.selectedTab = .images
        }
        if let index = arguments.firstIndex(of: "-textZoom"), index + 1 < arguments.count,
           let zoom = Int(arguments[index + 1]) {
            UserDefaults.standard.set(zoom, forKey: "reader.textZoom")
        }
        if arguments.contains("-readerDark") {
            UserDefaults.standard.set(true, forKey: "reader.darkMode")
        }
        // -openTitle <prefix>: open the library book whose title starts with
        // the prefix (case-insensitive), instead of the restored last-played.
        if let index = arguments.firstIndex(of: "-openTitle"), index + 1 < arguments.count {
            let prefix = arguments[index + 1].lowercased()
            do {
                for try await items in container.bookRepository.observeBooks() {
                    if let match = items.first(where: { $0.book.title.lowercased().hasPrefix(prefix) }) {
                        await engine.open(bookId: match.id, autoPlay: false)
                        navigation.selectedTab = .player
                    }
                    break
                }
            } catch {
                print("openTitle failed: \(error)")
            }
        }
        if let index = arguments.firstIndex(of: "-seekTo"), index + 1 < arguments.count,
           let seconds = Int64(arguments[index + 1]), engine.book != nil {
            engine.seek(toMs: seconds * 1000)
        }
        if arguments.contains("-play"), engine.book != nil {
            engine.play()
        }
        if arguments.contains("-showReader"), let bookId = engine.book?.id {
            navigation.showReader(bookId: bookId)
        }
        if let index = arguments.firstIndex(of: "-tab"), index + 1 < arguments.count {
            switch arguments[index + 1] {
            case "library": navigation.selectedTab = .library
            case "player": navigation.selectedTab = .player
            case "images": navigation.selectedTab = .images
            case "timer": navigation.selectedTab = .timer
            default: break
            }
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
    /// paths); the flag may repeat to import several books. Add `-autoPlay` to
    /// start playing the first one, and `-testCollectionAdvance` to put all
    /// imported books in a collection and seek near the end of the first.
    private func autoImportIfRequested() async {
        let arguments = ProcessInfo.processInfo.arguments
        var imported: [Book] = []
        for (index, argument) in arguments.enumerated() where argument == "-autoImport" {
            guard index + 1 < arguments.count else { break }
            do {
                let sourceURL = URL(fileURLWithPath: arguments[index + 1])
                let book = try await container.bookRepository.importBook(from: sourceURL)
                print("autoImport: imported \(book.title)")
                // Attach sibling companions when they sit next to the m4b
                // (ln-vox output layout: book.m4b + *.epub + sync_manifest.json).
                let siblings = (try? FileManager.default.contentsOfDirectory(
                    at: sourceURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
                if let epub = siblings.first(where: { $0.pathExtension == "epub" }) {
                    try await container.bookRepository.attachEpub(bookId: book.id, from: epub)
                }
                if let sync = siblings.first(where: { $0.lastPathComponent == "sync_manifest.json" }) {
                    try await container.bookRepository.attachSync(bookId: book.id, from: sync)
                }
                imported.append(book)
            } catch {
                print("autoImport failed: \(error)")
            }
        }
        guard let first = imported.first else { return }

        if arguments.contains("-testCollectionAdvance") {
            if let collection = try? await container.collectionRepository.create(name: "Test Shelf") {
                for book in imported {
                    try? await container.collectionRepository.addBook(bookId: book.id, to: collection.id)
                }
                print("autoImport: created Test Shelf with \(imported.count) books")
            }
            container.lastBookRestoreHandled = true
            await engine.open(bookId: first.id, autoPlay: true)
            navigation.selectedTab = .player
            engine.seek(toMs: max(0, first.durationMs - 20_000))
            return
        }

        if arguments.contains("-autoPlay") {
            container.lastBookRestoreHandled = true
            await engine.open(bookId: first.id, autoPlay: true)
            navigation.selectedTab = .player
        }
    }
    #endif
}
