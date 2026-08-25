import SwiftUI
import LnReaderCore

/// Compact now-playing bar shown over every tab except the full player (and
/// inside the reader): cover, title, Read shortcut (when the book has an EPUB
/// and the reader isn't already open), skips, play/pause — with stacked
/// chapter + whole-book progress bars on their own full-width row.
struct MiniPlayer: View {
    @Environment(PlayerEngine.self) private var engine
    @Environment(AppNavigation.self) private var navigation

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 12) {
                CoverImage(url: nil, image: engine.cover)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Text(engine.book?.title ?? "")
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if engine.book?.epubPath != nil, navigation.readerBookId == nil {
                    Button {
                        if let bookId = engine.book?.id {
                            navigation.showReader(bookId: bookId)
                        }
                    } label: {
                        Image(systemName: "book")
                    }
                    .accessibilityLabel("Read")
                }
                Button { engine.skip(seconds: -10) } label: {
                    Image(systemName: "gobackward.10")
                }
                Button { engine.togglePlayPause() } label: {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 28)
                }
                Button { engine.skip(seconds: 30) } label: {
                    Image(systemName: "goforward.30")
                }
            }
            progressBars
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 6, y: 2)
        .frame(maxWidth: 480)
        .contentShape(Rectangle())
        .onTapGesture {
            // From inside the reader cover, tapping also closes the reader.
            navigation.readerBookId = nil
            navigation.selectedTab = .player
        }
    }

    private var progressBars: some View {
        let duration = max(1, engine.book?.durationMs ?? 1)
        let chapter = engine.locator.window(atMs: engine.positionMs)
        return VStack(spacing: 3) {
            if let chapter {
                ProgressView(
                    value: Double(engine.positionMs - chapter.startMs),
                    total: Double(max(1, chapter.durationMs))
                )
                .scaleEffect(y: 0.6)
            }
            ProgressView(value: Double(engine.positionMs), total: Double(duration))
                .scaleEffect(y: 0.6)
                .tint(.secondary)
        }
    }
}
