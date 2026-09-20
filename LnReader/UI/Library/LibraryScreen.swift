import SwiftUI
import UniformTypeIdentifiers
import LnReaderCore

struct LibraryScreen: View {
    @Environment(\.appContainer) private var container
    @State private var model: LibraryViewModel?

    var body: some View {
        Group {
            if let model {
                NavigationStack {
                    LibraryContent(model: model, collectionName: nil)
                        .navigationDestination(for: CollectionRoute.self) { route in
                            CollectionView(route: route)
                        }
                }
            } else {
                ProgressView()
            }
        }
        .onAppear {
            if model == nil {
                model = LibraryViewModel(
                    repository: container.bookRepository,
                    collectionRepository: container.collectionRepository,
                    fileStore: container.fileStore
                )
            }
        }
    }
}

struct CollectionRoute: Hashable {
    let id: String
    let name: String
}

/// One collection's contents — LibraryContent reused with a scoped model.
private struct CollectionView: View {
    let route: CollectionRoute
    @Environment(\.appContainer) private var container
    @State private var model: LibraryViewModel?

    var body: some View {
        Group {
            if let model {
                LibraryContent(model: model, collectionName: route.name)
            } else {
                ProgressView()
            }
        }
        .onAppear {
            if model == nil {
                model = LibraryViewModel(
                    repository: container.bookRepository,
                    collectionRepository: container.collectionRepository,
                    fileStore: container.fileStore,
                    collectionId: route.id
                )
            }
        }
    }
}

private struct LibraryContent: View {
    @Bindable var model: LibraryViewModel
    /// nil = top-level library; set = inside this collection.
    let collectionName: String?

    @Environment(PlayerEngine.self) private var engine
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var showImporter = false
    @State private var activeSheet: ActiveSheet?
    @State private var confirmingCollectionDelete = false

    /// One sheet modifier for all sheets — SwiftUI honors only one `.sheet`
    /// (and one `.alert`) per view, so presentations must not be split across
    /// same-type modifiers on the same node.
    private enum ActiveSheet: Identifiable {
        case detail(BookListItem)
        case newCollection
        case reorder
        case attachCompanion(URL)

        var id: String {
            switch self {
            case .detail(let item): item.id
            case .newCollection: "new-collection"
            case .reorder: "reorder"
            case .attachCompanion(let url): "attach-\(url.absoluteString)"
            }
        }
    }

    private static let m4bType = UTType(filenameExtension: "m4b", conformingTo: .audiovisualContent)
        ?? .mpeg4Audio
    private static let epubType = UTType(filenameExtension: "epub") ?? .zip

    private var isEmpty: Bool {
        model.sortedItems.isEmpty && (collectionName != nil || model.collections.isEmpty)
    }

    var body: some View {
        Group {
            if isEmpty && model.importPhase == nil {
                ContentUnavailableView(
                    collectionName == nil ? "No books yet" : "Empty collection",
                    systemImage: "books.vertical",
                    description: Text("Tap + to import an .m4b audiobook or an .epub book.")
                )
            } else {
                grid
            }
        }
        .navigationTitle(collectionName ?? "Library")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { sortMenu }
            if collectionName != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        confirmingCollectionDelete = true
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) { addButton }
        }
        .safeAreaInset(edge: .bottom) {
            if let phase = model.importPhase {
                ImportProgressBar(phase: phase)
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [Self.m4bType, .mpeg4Audio, Self.epubType, .epub]
        ) { result in
            if case .success(let url) = result {
                Task { await model.importBook(from: url) }
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .detail(let item):
                // Large detent: the sheet holds enough sections (collection,
                // companions, remove) that medium hides most of them.
                BookDetailSheet(item: item, model: model)
                    .presentationDetents([.large])
            case .newCollection:
                CollectionNameSheet { name in
                    Task { await model.createCollection(named: name) }
                }
            case .reorder:
                ReorderSheet(model: model)
            case .attachCompanion(let url):
                AttachCompanionSheet(url: url, model: model)
            }
        }
        // Companions arriving via AirDrop / "Open in…" (top level only).
        .onChange(of: navigation.pendingAttachment) { _, url in
            if let url, collectionName == nil {
                navigation.pendingAttachment = nil
                activeSheet = .attachCompanion(url)
            }
        }
        .onAppear {
            if let url = navigation.pendingAttachment, collectionName == nil {
                navigation.pendingAttachment = nil
                activeSheet = .attachCompanion(url)
            }
        }
        .confirmationDialog(
            "Delete \"\(collectionName ?? "")\"?",
            isPresented: $confirmingCollectionDelete,
            titleVisibility: .visible
        ) {
            Button("Move books back to the library") {
                Task {
                    await model.deleteCollection(deleteBooks: false) { _ in }
                    dismiss()
                }
            }
            Button("Delete the books too", role: .destructive) {
                Task {
                    await model.deleteCollection(deleteBooks: true) { engine.unload(bookId: $0) }
                    dismiss()
                }
            }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.importErrorMessage != nil },
                set: { if !$0 { model.importErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.importErrorMessage ?? "")
        }
        .task { await model.observeBooks() }
        .task { await model.observeCollections() }
        // The grid's bottom row would otherwise sit under the floating mini-player.
        .miniPlayerInset()
    }

    private var addButton: some View {
        Group {
            if collectionName == nil {
                // Top level offers Book or Collection, like Android's + menu.
                Menu {
                    Button {
                        showImporter = true
                    } label: {
                        Label("Import book", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        activeSheet = .newCollection
                    } label: {
                        Label("New collection", systemImage: "folder.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add")
            } else {
                // Inside a collection, + imports straight into it.
                Button {
                    showImporter = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .disabled(model.importPhase != nil)
    }

    /// An adaptive grid fits as many columns as the minimum allows, so the phone's minimum on an
    /// iPad gives six thin covers across and a shelf that reads as a strip along the top. A
    /// regular-width screen asks for wider tiles instead, which lands on four — the same shape
    /// the Android tablet layout has.
    private var gridColumns: [GridItem] {
        let wide = horizontalSizeClass == .regular
        return [GridItem(.adaptive(minimum: wide ? 200 : 130, maximum: wide ? 280 : 190), spacing: 16)]
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: 20) {
                if collectionName == nil {
                    ForEach(model.collections) { item in
                        NavigationLink(value: CollectionRoute(id: item.id, name: item.collection.name)) {
                            CollectionTile(item: item, model: model)
                        }
                        .buttonStyle(.plain)
                    }
                }
                ForEach(model.sortedItems) { item in
                    // Tap opens the detail sheet (Open / images / collection /
                    // companions / remove); Android's tap-to-play lives on the
                    // sheet's Open button and the long-press menu instead.
                    BookGridCell(item: item, coverURL: model.coverURL(for: item))
                        .onTapGesture { activeSheet = .detail(item) }
                        .accessibilityIdentifier("book-cell")
                        .contextMenu {
                            Button {
                                play(item)
                            } label: {
                                Label(
                                    item.book.hasAudio ? "Open" : "Read",
                                    systemImage: item.book.hasAudio ? "play.fill" : "book"
                                )
                            }
                            Button {
                                activeSheet = .detail(item)
                            } label: {
                                Label("Details", systemImage: "info.circle")
                            }
                            Button(role: .destructive) {
                                Task {
                                    engine.unload(bookId: item.book.id)
                                    await model.delete(bookId: item.book.id)
                                }
                            } label: {
                                Label("Remove from library", systemImage: "trash")
                            }
                        }
                }
            }
            .padding(.horizontal)
        }
    }

    /// "Open" from the grid: play an audiobook, read an EPUB-only book.
    private func play(_ item: BookListItem) {
        guard item.book.hasAudio else {
            navigation.showReader(bookId: item.book.id)
            return
        }
        Task { await engine.open(bookId: item.book.id, autoPlay: true) }
        navigation.selectedTab = .player
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: Binding(
                get: { model.sortChoice },
                set: { choice in
                    model.sortChoice = choice
                    // Picking Manual goes straight to arranging, like Android's
                    // ReorderScreen.
                    if choice == .manual { activeSheet = .reorder }
                }
            )) {
                Text("Name").tag(LibrarySortChoice.name)
                Text("Date added").tag(LibrarySortChoice.dateAdded)
                if collectionName != nil {
                    Text("Manual").tag(LibrarySortChoice.manual)
                }
            }
            if model.sortChoice == .manual {
                Button {
                    activeSheet = .reorder
                } label: {
                    Label("Reorder…", systemImage: "line.3.horizontal")
                }
            } else {
                Picker("Direction", selection: $model.sortAscending) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel("Sort")
    }
}

/// Folder-style tile: up to four contained covers in a 2×2 mini-shelf
/// (simplified from Android's 3×3), name, and book count.
private struct CollectionTile: View {
    let item: CollectionListItem
    let model: LibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary)
                if item.coverPaths.isEmpty {
                    Image(systemName: "folder.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                } else {
                    shelfGrid
                }
            }
            .aspectRatio(2 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(item.collection.name)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
            Text("^[\(item.bookCount) book](inflect: true)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, -4)
        }
    }

    private var shelfGrid: some View {
        GeometryReader { proxy in
            let cellHeight = proxy.size.height / 2 - 6
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
                ForEach(Array(item.coverPaths.prefix(4).enumerated()), id: \.offset) { _, path in
                    CoverImage(url: model.coverURL(forPath: path))
                        .frame(height: cellHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(4)
        }
    }
}

private struct BookGridCell: View {
    let item: BookListItem
    let coverURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverImage(url: coverURL)
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottom) {
                    if let progress = item.progress {
                        ProgressView(value: progress)
                            .tint(.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.bottom, 4)
                    }
                }
            Text(item.book.title)
                .font(.footnote)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
            // How long, or how far: an audiobook is measured in time, an EPUB-only book in
            // pages, so the same line reads "9h 26m" or "6 / 45" (matching Android's tile).
            Text(extentLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, -2)
        }
    }

    /// The page total comes from the book row (recorded at import). Rows imported before that
    /// column existed fall back to the count the reader wrote alongside the reading position;
    /// with neither, the format is all we can honestly say.
    private var extentLabel: String {
        let book = item.book
        guard !book.hasAudio else { return Self.formatDuration(ms: book.durationMs) }
        let total = book.spineCount > 0 ? book.spineCount : (item.readingPosition?.spineCount ?? 0)
        guard total > 0 else { return "EPUB" }
        let page = min(max(1, (item.readingPosition?.spineIndex ?? 0) + 1), total)
        return "\(page) / \(total)"
    }

    static func formatDuration(ms: Int64) -> String {
        guard ms > 0 else { return "—" }
        let minutes = ms / 60_000
        let hours = minutes / 60
        return hours > 0 ? "\(hours)h \(minutes % 60)m" : "\(minutes)m"
    }
}

struct CoverImage: View {
    let url: URL?
    var image: UIImage? = nil // preloaded, skips disk loading
    @State private var loaded: UIImage?

    private var displayed: UIImage? { image ?? loaded }

    var body: some View {
        // The image lives in an overlay so its natural size can never inflate
        // the layout (scaledToFill reports oversize for wide images).
        RoundedRectangle(cornerRadius: 10)
            .fill(.quaternary)
            .overlay {
                if let displayed {
                    Image(uiImage: displayed)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "headphones")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .task(id: url) {
                guard image == nil, let url else { return }
                loaded = await Task.detached(priority: .utility) {
                    UIImage(contentsOfFile: url.path)
                }.value
            }
    }
}

struct ImportProgressBar: View {
    let phase: ImportPhase

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch phase {
            case .copying(let copied, let total) where total > 0:
                Text("Copying: \(format(copied)) / \(format(total))")
                    .font(.caption)
                ProgressView(value: Double(copied), total: Double(total))
            case .copying:
                Text("Copying…").font(.caption)
                ProgressView()
            case .parsing:
                Text("Parsing m4b…").font(.caption)
                ProgressView()
            case .finalizing:
                Text("Finalizing…").font(.caption)
                ProgressView()
            }
        }
        .padding(12)
        .background(.bar)
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
