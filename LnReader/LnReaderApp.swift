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
            readLogRepository: container.readLogRepository,
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
        // A launch that names a book owns the opening move. Without this the restore goes first,
        // and when the last book was an EPUB it presents that reader — a full-screen cover that
        // does not swap to another book when `-openTitle` asks for one, so the hook silently
        // acts on whichever book was already open.
        if ProcessInfo.processInfo.arguments.contains("-openTitle") {
            container.lastBookRestoreHandled = true
        }
        #endif
        await restoreLastBook()
        #if DEBUG
        // Dev hooks for scripted smoke tests, in the order Android's DebugLaunch applies them:
        // preferences, then the book, then the screen. The screen hooks have to come last —
        // `-openTitle` selects the player tab itself, so anything that picks a screen before it
        // is quietly undone, which is how `-showImages` used to end up on the player.
        let arguments = ProcessInfo.processInfo.arguments
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
                        // An EPUB-only book has no player to open; it goes to the reader.
                        if match.book.hasAudio {
                            await engine.open(bookId: match.id, autoPlay: false)
                            navigation.selectedTab = .player
                        } else {
                            navigation.showReader(bookId: match.id)
                        }
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
        if arguments.contains("-showImages") {
            navigation.selectedTab = .images
        }
        if arguments.contains("-armChapterTimer") {
            sleepTimer.start(SleepTimerConfig(mode: .chapters(count: 1), fadeOutSeconds: 10))
            navigation.selectedTab = .settings
        }
        if let index = arguments.firstIndex(of: "-armTimer"), index + 1 < arguments.count,
           let minutes = Int(arguments[index + 1]) {
            sleepTimer.start(SleepTimerConfig(mode: .time(minutes: minutes), fadeOutSeconds: 10))
            navigation.selectedTab = .settings
        }
        if let index = arguments.firstIndex(of: "-tab"), index + 1 < arguments.count {
            switch arguments[index + 1] {
            case "library": navigation.selectedTab = .library
            case "player": navigation.selectedTab = .player
            case "images": navigation.selectedTab = .images
            // "timer" still resolves, so existing scripts keep working after the merge.
            case "timer", "settings": navigation.selectedTab = .settings
            default: break
            }
        }
        #endif
    }

    /// On a fresh launch, reopen whatever the user was last in: the most recent of the last
    /// playback save and the last reading save decides the book. An audiobook comes back in the
    /// player, paused at its position (mirrors Android's resume-on-launch); a book without audio
    /// can only come back in the reader, at its saved page — its reading position is the only
    /// record of where the user was.
    private func restoreLastBook() async {
        guard !container.lastBookRestoreHandled else { return }
        container.lastBookRestoreHandled = true
        guard engine.book == nil, navigation.readerBookId == nil else { return }
        let lastPlayed = try? await container.positionRepository.lastPlayed()
        let lastRead = try? await container.readingPositionRepository.lastRead()
        let candidates = [lastPlayed, lastRead].compactMap { $0 }
        guard let latest = candidates.max(by: { $0.updatedAt < $1.updatedAt }),
              let detail = try? await container.bookRepository.detail(bookId: latest.bookId) else { return }
        if detail.book.hasAudio {
            await engine.open(bookId: detail.book.id, autoPlay: false)
            if engine.book != nil { navigation.selectedTab = .player }
        } else {
            navigation.showReader(bookId: detail.book.id)
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
                // An EPUB-only import is already the whole book — nothing to attach.
                if book.hasAudio {
                    let siblings = (try? FileManager.default.contentsOfDirectory(
                        at: sourceURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
                    if let epub = siblings.first(where: { $0.pathExtension == "epub" }) {
                        try await container.bookRepository.attachEpub(bookId: book.id, from: epub)
                    }
                    if let sync = siblings.first(where: { $0.lastPathComponent == "sync_manifest.json" }) {
                        try await container.bookRepository.attachSync(bookId: book.id, from: sync)
                    }
                }
                imported.append(book)
            } catch {
                print("autoImport failed: \(error)")
            }
        }
        if arguments.contains("-seedStats") {
            let days = arguments.firstIndex(of: "-seedDays")
                .flatMap { $0 + 1 < arguments.count ? Int(arguments[$0 + 1]) : nil } ?? 120
            await seedStats(days: days)
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
            if first.hasAudio {
                await engine.open(bookId: first.id, autoPlay: true)
                navigation.selectedTab = .player
            } else {
                navigation.showReader(bookId: first.id)
            }
        }
    }
    /// Replaces the usage log with generated sessions so the stats chart has something to show.
    ///
    /// Deterministic (seeded off each day) so a rerun produces the same history and screenshots
    /// stay comparable, and shaped like real use rather than uniform noise: a few sessions a day
    /// at plausible hours and lengths, mostly listening, weighted so the first books in the
    /// library dominate — a flat distribution would make every bar the same height and hide
    /// whether the stack works. Mirrors Android's `--ez seedStats`.
    private func seedStats(days: Int) async {
        let library = (try? await allBooks()) ?? []
        guard !library.isEmpty else {
            print("seedStats: no books in the library, nothing to attribute to")
            return
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var sessions: [ReadLogEntry] = []

        for dayOffset in stride(from: days, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: today) else { continue }
            var rng = SeededRandom(seed: UInt64(Int(date.timeIntervalSince1970) / 86_400))
            // Most days have some listening; a third are quiet, which gives the chart gaps.
            let roll = rng.next(upTo: 100)
            let count = roll <= 32 ? 0 : (roll <= 70 ? 1 : (roll <= 92 ? 2 : 3))
            let hours = [8, 12, 18, 21]
            for i in 0..<count {
                // Books early in the library get picked more often, so totals differ visibly.
                let weighted = rng.next(upTo: library.count * (library.count + 1) / 2)
                var index = 0, acc = library.count
                while acc <= weighted && index < library.count - 1 { index += 1; acc += library.count - index }
                let book = library[index]
                let minutes = 8 + rng.next(upTo: 68)
                let hour = hours[i % hours.count]
                guard let start = calendar.date(bySettingHour: hour, minute: rng.next(upTo: 60),
                                                second: 0, of: date) else { continue }
                let kind: ReadLogKind = (book.hasAudio && rng.next(upTo: 100) < 78) ? .listen : .read
                sessions.append(ReadLogEntry(
                    id: "seed-\(Int(date.timeIntervalSince1970))-\(i)",
                    bookId: book.id, bookTitle: book.title, kind: kind,
                    startedAt: start, endedAt: start.addingTimeInterval(Double(minutes) * 60),
                    startPosition: 0, endPosition: Int64(minutes) * 60_000))
            }
        }
        try? await container.readLogRepository.replaceAll(sessions)
        print("seedStats: wrote \(sessions.count) sessions over \(days) days")
    }

    /// The whole library, however it is filed — `books(inCollection:)` only returns members.
    private func allBooks() async throws -> [Book] {
        var iterator = container.bookRepository.observeBooks().makeAsyncIterator()
        return (try await iterator.next())?.map(\.book) ?? []
    }
    #endif
}

#if DEBUG
/// Tiny reproducible generator — `SystemRandomNumberGenerator` would make every seeded run differ.
private struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }
    mutating func next(upTo bound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return bound <= 0 ? 0 : Int((state >> 33) % UInt64(bound))
    }
}
#endif
