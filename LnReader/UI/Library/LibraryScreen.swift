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

    @State private var showImporter = false
    @State private var activeSheet: ActiveSheet?
    @State private var confirmingCollectionDelete = false

    /// One sheet modifier for all sheets — SwiftUI honors only one `.sheet`
    /// (and one `.alert`) per view, so presentations must not be split across
    /// same-type modifiers on the same node.
    private enum ActiveSheet: Identifiable {
        case detail(BookListItem)
        case newCollection

        var id: String {
            switch self {
            case .detail(let item): item.id
            case .newCollection: "new-collection"
            }
        }
    }

    private static let m4bType = UTType(filenameExtension: "m4b", conformingTo: .audiovisualContent)
        ?? .mpeg4Audio

    private var isEmpty: Bool {
        model.sortedItems.isEmpty && (collectionName != nil || model.collections.isEmpty)
    }

    var body: some View {
        Group {
            if isEmpty && model.importPhase == nil {
                ContentUnavailableView(
                    collectionName == nil ? "No books yet" : "Empty collection",
                    systemImage: "books.vertical",
                    description: Text("Tap + to import an .m4b audiobook.")
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
            allowedContentTypes: [Self.m4bType, .mpeg4Audio]
        ) { result in
            if case .success(let url) = result {
                Task { await model.importBook(from: url) }
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .detail(let item):
                BookDetailSheet(item: item, model: model)
                    .presentationDetents([.medium, .large])
            case .newCollection:
                CollectionNameSheet { name in
                    Task { await model.createCollection(named: name) }
                }
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
    }

    private var addButton: some View {
        Group {
            if collectionName == nil {
                // Top level offers Book or Collection, like Android's + menu.
                Menu {
                    Button {
                        showImporter = true
                    } label: {
                        Label("Import book", systemImage: "waveform")
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

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 190), spacing: 16)], spacing: 20) {
                if collectionName == nil {
                    ForEach(model.collections) { item in
                        NavigationLink(value: CollectionRoute(id: item.id, name: item.collection.name)) {
                            CollectionTile(item: item, model: model)
                        }
                        .buttonStyle(.plain)
                    }
                }
                ForEach(model.sortedItems) { item in
                    BookGridCell(item: item, coverURL: model.coverURL(for: item))
                        .onTapGesture { play(item) }
                        .contextMenu {
                            Button {
                                play(item)
                            } label: {
                                Label("Open", systemImage: "play.fill")
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

    private func play(_ item: BookListItem) {
        Task { await engine.open(bookId: item.book.id, autoPlay: true) }
        navigation.selectedTab = .player
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $model.sortField) {
                Text("Name").tag(LibrarySortField.name)
                Text("Date added").tag(LibrarySortField.dateAdded)
            }
            Picker("Direction", selection: $model.sortAscending) {
                Text("Ascending").tag(true)
                Text("Descending").tag(false)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
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
        }
    }
}

struct CoverImage: View {
    let url: URL?
    var image: UIImage? = nil // preloaded, skips disk loading
    @State private var loaded: UIImage?

    private var displayed: UIImage? { image ?? loaded }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary)
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
