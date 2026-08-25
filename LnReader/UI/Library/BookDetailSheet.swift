import SwiftUI
import LnReaderCore

/// Book detail sheet — mirrors the Android BookDetailSheet. For now: metadata
/// plus Remove; Open/Read/companion actions arrive with their features.
struct BookDetailSheet: View {
    let item: BookListItem
    let model: LibraryViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(PlayerEngine.self) private var engine
    @Environment(AppNavigation.self) private var navigation
    @State private var confirmingRemove = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        CoverImage(url: model.coverURL(for: item))
                            .aspectRatio(2 / 3, contentMode: .fit)
                            .frame(width: 90)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.book.title)
                                .font(.headline)
                            if let author = item.book.author {
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

                Section {
                    Button {
                        Task { await engine.open(bookId: item.book.id, autoPlay: true) }
                        navigation.selectedTab = .player
                        dismiss()
                    } label: {
                        Label("Open", systemImage: "play.fill")
                    }
                }

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
                "Remove \"\(item.book.title)\"? The imported copy and its images are deleted.",
                isPresented: $confirmingRemove,
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    Task {
                        engine.unload(bookId: item.book.id)
                        await model.delete(bookId: item.book.id)
                        dismiss()
                    }
                }
            }
        }
    }

    private var duration: String {
        let seconds = item.book.durationMs / 1000
        return String(format: "%d h %02d min", seconds / 3600, seconds / 60 % 60)
    }

    private var size: String {
        ByteCountFormatter.string(fromByteCount: item.book.fileSize, countStyle: .file)
    }
}
