import SwiftUI
import UniformTypeIdentifiers
import LnReaderCore

struct LibraryScreen: View {
    @Environment(\.appContainer) private var container
    @State private var model: LibraryViewModel?

    var body: some View {
        Group {
            if let model {
                LibraryContent(model: model)
            } else {
                ProgressView()
            }
        }
        .onAppear {
            if model == nil {
                model = LibraryViewModel(
                    repository: container.bookRepository,
                    fileStore: container.fileStore
                )
            }
        }
    }
}

private struct LibraryContent: View {
    @Bindable var model: LibraryViewModel
    @State private var showImporter = false
    @State private var selectedBook: BookListItem?

    private static let m4bType = UTType(filenameExtension: "m4b", conformingTo: .audiovisualContent)
        ?? .mpeg4Audio

    var body: some View {
        NavigationStack {
            Group {
                if model.sortedItems.isEmpty && model.importPhase == nil {
                    ContentUnavailableView(
                        "No books yet",
                        systemImage: "books.vertical",
                        description: Text("Tap + to import an .m4b audiobook.")
                    )
                } else {
                    grid
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { sortMenu }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showImporter = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(model.importPhase != nil)
                }
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
            .sheet(item: $selectedBook) { item in
                BookDetailSheet(item: item, model: model)
                    .presentationDetents([.medium])
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
        }
        .task { await model.observe() }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 190), spacing: 16)], spacing: 20) {
                ForEach(model.sortedItems) { item in
                    BookGridCell(item: item, coverURL: model.coverURL(for: item))
                        .onTapGesture { selectedBook = item }
                }
            }
            .padding(.horizontal)
        }
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
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "headphones")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: url) {
            guard let url else { return }
            let loaded = await Task.detached(priority: .utility) {
                UIImage(contentsOfFile: url.path)
            }.value
            image = loaded
        }
    }
}

private struct ImportProgressBar: View {
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
