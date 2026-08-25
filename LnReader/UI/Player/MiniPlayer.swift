import SwiftUI
import LnReaderCore

/// Compact now-playing bar shown over every tab except the full player:
/// cover, title, skips, play/pause, and stacked chapter + whole-book progress.
struct MiniPlayer: View {
    @Environment(PlayerEngine.self) private var engine
    @Environment(AppNavigation.self) private var navigation

    var body: some View {
        HStack(spacing: 12) {
            CoverImage(url: nil, image: engine.cover)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 5) {
                Text(engine.book?.title ?? "")
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                progressBars
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
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 6, y: 2)
        .frame(maxWidth: 480)
        .contentShape(Rectangle())
        .onTapGesture { navigation.selectedTab = .player }
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
