import SwiftUI
import LnReaderCore

/// Grid of every image embedded in the m4b. Shows the explicitly requested
/// book (detail sheet → "View images") or falls back to the playing book.
struct ViewerScreen: View {
    @Environment(\.appContainer) private var container
    @Environment(PlayerEngine.self) private var engine
    @Environment(AppNavigation.self) private var navigation

    @State private var detail: BookDetail?
    @State private var fullScreenSelection: ImageSelection?

    private struct ImageSelection: Identifiable {
        let id: Int
    }

    private var targetBookId: String? {
        navigation.viewerBookId ?? engine.book?.id
    }

    var body: some View {
        NavigationStack {
            Group {
                if let detail, !detail.images.isEmpty {
                    grid(detail)
                } else {
                    ContentUnavailableView(
                        "No images",
                        systemImage: "photo.on.rectangle",
                        description: Text(
                            targetBookId == nil
                                ? "Open a book first — its embedded illustrations show up here."
                                : "This book has no embedded images."
                        )
                    )
                }
            }
            .navigationTitle(detail.map { $0.book.title } ?? "Images")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task(id: targetBookId) {
            guard let targetBookId else {
                detail = nil
                return
            }
            detail = try? await container.bookRepository.detail(bookId: targetBookId)
        }
        // Leaving the tab clears an explicit target, so a plain tab tap shows
        // the playing book again (mirrors Android's optional bookId route arg).
        .onDisappear { navigation.viewerBookId = nil }
        .fullScreenCover(item: $fullScreenSelection) { selection in
            if let detail {
                FullScreenImageViewer(
                    imageURLs: detail.images.map { container.fileStore.url(for: $0.cachePath) },
                    startIndex: selection.id
                )
            }
        }
    }

    private func grid(_ detail: BookDetail) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 10)], spacing: 10) {
                ForEach(Array(detail.images.enumerated()), id: \.offset) { index, image in
                    ViewerThumbnail(url: container.fileStore.url(for: image.cachePath))
                        .onTapGesture { fullScreenSelection = ImageSelection(id: index) }
                }
            }
            .padding(.horizontal)
        }
    }
}

private struct ViewerThumbnail: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .aspectRatio(2 / 3, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: url) {
            image = await Task.detached(priority: .utility) {
                UIImage(contentsOfFile: url.path)
            }.value
        }
    }
}
