import SwiftUI
import LnReaderCore

/// "Attach to which book?" — shown when an .epub or sync .json arrives via
/// AirDrop / "Open in…". Tapping a book attaches the file as its companion.
struct AttachCompanionSheet: View {
    let url: URL
    let model: LibraryViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var attaching = false

    private var isEpub: Bool { url.pathExtension.lowercased() == "epub" }

    var body: some View {
        NavigationStack {
            Group {
                if model.allItems.isEmpty {
                    ContentUnavailableView(
                        "No books yet",
                        systemImage: "books.vertical",
                        description: Text("Import an .m4b first, then attach this file to it.")
                    )
                } else {
                    List(model.allItems) { item in
                        Button {
                            attach(to: item.book.id)
                        } label: {
                            HStack(spacing: 12) {
                                CoverImage(url: model.coverURL(for: item))
                                    .frame(width: 36, height: 54)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.book.title)
                                        .font(.subheadline)
                                        .lineLimit(2)
                                    Text(isEpub
                                         ? (item.book.epubPath != nil ? "Replaces the attached EPUB" : "No EPUB attached")
                                         : (item.book.syncPath != nil ? "Replaces the attached manifest" : "No sync manifest attached"))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                        .disabled(attaching)
                    }
                }
            }
            .navigationTitle(isEpub ? "Attach EPUB to…" : "Attach sync manifest to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay {
                if attaching { ProgressView() }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await model.observeBooks() }
    }

    private func attach(to bookId: String) {
        attaching = true
        Task {
            if isEpub {
                await model.attachEpub(bookId: bookId, from: url)
            } else {
                await model.attachSync(bookId: bookId, from: url)
            }
            try? FileManager.default.removeItem(at: url) // Inbox copy
            dismiss()
        }
    }
}
