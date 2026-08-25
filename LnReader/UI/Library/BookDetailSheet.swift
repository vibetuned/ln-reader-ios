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
    @State private var attachingEpub = false
    @State private var attachingSync = false
    @State private var askingNewCollectionName = false
    @State private var newCollectionName = ""

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
                isPresented: $attachingEpub,
                allowedContentTypes: [Self.epubType]
            ) { result in
                if case .success(let url) = result {
                    Task { await model.attachEpub(bookId: book.id, from: url) }
                }
            }
            .fileImporter(
                isPresented: $attachingSync,
                allowedContentTypes: [.json]
            ) { result in
                if case .success(let url) = result {
                    Task { await model.attachSync(bookId: book.id, from: url) }
                }
            }
            .alert("New collection", isPresented: $askingNewCollectionName) {
                TextField("Name", text: $newCollectionName)
                Button("Create & add") {
                    Task { await model.addBook(bookId: book.id, toNewCollectionNamed: newCollectionName) }
                    newCollectionName = ""
                }
                Button("Cancel", role: .cancel) { newCollectionName = "" }
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
                        askingNewCollectionName = true
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
                attach: { attachingEpub = true },
                detach: { Task { await model.detachEpub(bookId: book.id) } }
            )
            companionRow(
                title: "Sync manifest",
                attached: book.syncPath != nil,
                attach: { attachingSync = true },
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
