import SwiftUI
import UniformTypeIdentifiers
import LnReaderCore

/// Book detail sheet — mirrors the Android BookDetailSheet: Open, View images,
/// collection membership, EPUB / sync companions, and Remove.
struct BookDetailSheet: View {
    let item: BookListItem
    let model: LibraryViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(PlayerEngine.self) private var engine
    @Environment(AppNavigation.self) private var navigation

    @State private var confirmingRemove = false
    @State private var pickingCompanion: CompanionKind?
    @State private var askingNewCollection = false

    /// One fileImporter serves both companions — two `.fileImporter` modifiers
    /// on the same view conflict (only the last one presents).
    private enum CompanionKind {
        case epub, sync
    }

    private static let epubType = UTType(filenameExtension: "epub") ?? .zip

    /// Live row from the observed list, so attach/detach updates the sheet.
    private var current: BookListItem {
        model.allItems.first { $0.id == item.id } ?? item
    }

    private var book: Book { current.book }

    var body: some View {
        NavigationStack {
            List {
                header

                Section {
                    Button {
                        Task { await engine.open(bookId: book.id, autoPlay: true) }
                        navigation.selectedTab = .player
                        dismiss()
                    } label: {
                        Label("Open", systemImage: "play.fill")
                    }
                    Button {
                        navigation.showImages(bookId: book.id)
                        dismiss()
                    } label: {
                        Label("View images", systemImage: "photo.on.rectangle")
                    }
                }

                collectionSection
                companionsSection

                Section {
                    Button(role: .destructive) {
                        confirmingRemove = true
                    } label: {
                        Label("Remove from library", systemImage: "trash")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Book")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Remove \"\(book.title)\"? The imported copy and its images are deleted.",
                isPresented: $confirmingRemove,
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    Task {
                        engine.unload(bookId: book.id)
                        await model.delete(bookId: book.id)
                        dismiss()
                    }
                }
            }
            .fileImporter(
                isPresented: Binding(
                    get: { pickingCompanion != nil },
                    set: { if !$0 { pickingCompanion = nil } }
                ),
                allowedContentTypes: pickingCompanion == .epub ? [Self.epubType] : [.json]
            ) { result in
                guard case .success(let url) = result, let kind = pickingCompanion else { return }
                Task {
                    switch kind {
                    case .epub: await model.attachEpub(bookId: book.id, from: url)
                    case .sync: await model.attachSync(bookId: book.id, from: url)
                    }
                }
            }
            .sheet(isPresented: $askingNewCollection) {
                CollectionNameSheet(confirmTitle: "Create & add") { name in
                    Task { await model.addBook(bookId: book.id, toNewCollectionNamed: name) }
                }
            }
        }
    }

    private var header: some View {
        Section {
            HStack(spacing: 16) {
                CoverImage(url: model.coverURL(for: current))
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .frame(width: 90)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(book.title)
                        .font(.headline)
                    if let author = book.author {
                        Text(author)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text(duration)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(size)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listRowSeparator(.hidden)
        }
    }

    private var collectionSection: some View {
        Section("Collection") {
            if let collectionId = book.collectionId {
                let name = model.collections.first { $0.id == collectionId }?.collection.name
                Button {
                    Task { await model.removeBookFromCollection(bookId: book.id) }
                } label: {
                    Label("Remove from \"\(name ?? "collection")\"", systemImage: "folder.badge.minus")
                }
            } else {
                Menu {
                    ForEach(model.collections) { collection in
                        Button(collection.collection.name) {
                            Task { await model.addBook(bookId: book.id, toCollection: collection.id) }
                        }
                    }
                    Divider()
                    Button("New collection…") {
                        askingNewCollection = true
                    }
                } label: {
                    Label("Add to collection", systemImage: "folder.badge.plus")
                }
            }
        }
    }

    private var companionsSection: some View {
        Section {
            companionRow(
                title: "EPUB",
                attached: book.epubPath != nil,
                attach: { pickingCompanion = .epub },
                detach: { Task { await model.detachEpub(bookId: book.id) } }
            )
            companionRow(
                title: "Sync manifest",
                attached: book.syncPath != nil,
                attach: { pickingCompanion = .sync },
                detach: { Task { await model.detachSync(bookId: book.id) } }
            )
        } header: {
            Text("Companions")
        } footer: {
            Text("An EPUB adds the reader; a sync manifest adds audio-synced highlighting and image markers.")
        }
    }

    private func companionRow(
        title: String,
        attached: Bool,
        attach: @escaping () -> Void,
        detach: @escaping () -> Void
    ) -> some View {
        HStack {
            Label(title, systemImage: attached ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(attached ? Color.primary : Color.secondary)
            Spacer()
            if attached {
                Button("Detach", role: .destructive, action: detach)
                    .buttonStyle(.borderless)
            } else {
                Button("Attach…", action: attach)
                    .buttonStyle(.borderless)
            }
        }
    }

    private var duration: String {
        let seconds = book.durationMs / 1000
        return String(format: "%d h %02d min", seconds / 3600, seconds / 60 % 60)
    }

    private var size: String {
        ByteCountFormatter.string(fromByteCount: book.fileSize, countStyle: .file)
    }
}
