import SwiftUI
import LnReaderCore

struct PlayerScreen: View {
    @Environment(PlayerEngine.self) private var engine
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var activeSheet: ActiveSheet?

    private enum ActiveSheet: String, Identifiable {
        case timer, speed, chapters
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Group {
                if engine.book != nil {
                    PlayerContent(openTimer: { activeSheet = .timer })
                } else {
                    ContentUnavailableView(
                        "Nothing playing",
                        systemImage: "play.circle",
                        description: Text("Pick a book in the Library.")
                    )
                }
            }
            .navigationTitle("Player")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // iPad (regular): NO visible topBarTrailing items — the bar
                // shares space with the top tab bar and folds extras into
                // UIKit's overflow, which never opens (see DESIGN.md); the
                // stateful icons live in a row inside the player body instead.
                // iPhone (compact): the tab bar sits at the bottom, so the nav
                // bar has room — the icons go up top like a classic player.
                if let book = engine.book {
                    if horizontalSizeClass == .compact {
                        ToolbarItem(placement: .topBarTrailing) {
                            RouteControls(spacing: 18, openTimer: { activeSheet = .timer })
                        }
                    }
                    ToolbarItem(placement: .secondaryAction) {
                        Button {
                            activeSheet = .speed
                        } label: {
                            Label(
                                "Playback speed · \(engine.rate.formatted(.number.precision(.fractionLength(0...2))))×",
                                systemImage: "gauge.with.needle")
                        }
                    }
                    ToolbarItem(placement: .secondaryAction) {
                        Button {
                            activeSheet = .chapters
                        } label: {
                            Label("Chapters", systemImage: "list.bullet")
                        }
                        .disabled(engine.chapters.isEmpty)
                    }
                    ToolbarItem(placement: .secondaryAction) {
                        Button {
                            navigation.showImages(bookId: book.id)
                        } label: {
                            Label("View images", systemImage: "photo.on.rectangle")
                        }
                    }
                }
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .timer:
                    NavigationStack {
                        TimerControls()
                            .navigationTitle("Sleep Timer")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button("Done") { activeSheet = nil }
                                }
                            }
                    }
                    .presentationDetents([.medium, .large])
                case .speed:
                    SpeedSheet()
                case .chapters:
                    ChapterListSheet()
                }
            }
        }
    }
}

/// Playback speed presets, presented as a sheet (Android's SpeedSheet).
private struct SpeedSheet: View {
    @Environment(PlayerEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(PlayerEngine.speedPresets, id: \.self) { preset in
                Button {
                    engine.setRate(preset)
                } label: {
                    HStack {
                        Text("\(preset.formatted(.number.precision(.fractionLength(0...2))))×")
                            .monospacedDigit()
                        Spacer()
                        if engine.rate == preset {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
            .navigationTitle("Playback speed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Cast / AirPlay / Read / sleep timer — the stateful controls, shared by the
/// iPhone top bar and the iPad body row (where the bar can't hold them).
private struct RouteControls: View {
    @Environment(PlayerEngine.self) private var engine
    @Environment(AppNavigation.self) private var navigation
    @Environment(SleepTimerController.self) private var sleepTimer
    @Environment(CastController.self) private var cast

    let spacing: CGFloat
    let openTimer: () -> Void

    var body: some View {
        HStack(spacing: spacing) {
            if cast.devicesAvailable {
                CastButton()
                    .frame(width: 28, height: 28)
                    .accessibilityLabel("Cast")
            }
            AirPlayButton()
                .frame(width: 28, height: 28)
                .accessibilityLabel("AirPlay")
            if engine.book?.epubPath != nil {
                Button {
                    if let bookId = engine.book?.id {
                        navigation.showReader(bookId: bookId)
                    }
                } label: {
                    Image(systemName: "book")
                        .font(.title3)
                }
                .accessibilityLabel("Read")
            }
            Button {
                openTimer()
            } label: {
                Image(systemName: sleepTimer.state != nil ? "moon.zzz.fill" : "moon.zzz")
                    .font(.title3)
                    .foregroundStyle(sleepTimer.state != nil ? Color.accentColor : Color.primary)
            }
            .accessibilityLabel("Sleep timer")
        }
        .buttonStyle(.plain)
    }
}

private struct PlayerContent: View {
    @Environment(PlayerEngine.self) private var engine
    @Environment(\.appContainer) private var container
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Opens the sleep-timer sheet (owned by PlayerScreen).
    let openTimer: () -> Void

    // While dragging, the scrubber drives this book-absolute preview position.
    @State private var scrubMs: Int64?
    /// The chapter window FROZEN for the duration of a drag. Without it, a
    /// drag to the chapter edge recomputes the window as the next chapter,
    /// whose scrubber max immediately rolls the preview into the one after —
    /// cascading to the end of the book (like Android, the window is fixed
    /// while dragging and the seek happens once, on release).
    @State private var scrubWindow: ChapterWindow?
    @State private var showChapters = false
    /// Sync-manifest images that have a matching embedded m4b image (matched
    /// by ordinal, like Android) — they render as tappable scrubber markers.
    @State private var markers: [SyncImage] = []
    @State private var embeddedImageURLs: [URL] = []
    @State private var markerSelection: MarkerSelection?

    private struct MarkerSelection: Identifiable {
        let id: Int
    }

    private var displayMs: Int64 { scrubMs ?? engine.positionMs }
    private var chapter: ChapterWindow? {
        scrubWindow ?? engine.locator.window(atMs: displayMs)
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Spacer(minLength: 12)

                CoverImage(url: nil, image: engine.cover)
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .frame(maxHeight: proxy.size.height * 0.42)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(radius: 8, y: 4)

                Spacer(minLength: 16)

                VStack(spacing: 4) {
                    Text(engine.book?.title ?? "")
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    if let author = engine.book?.author {
                        Text(author)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    chapterSelector
                        .padding(.top, 6)
                }
                .padding(.horizontal, 24)

                Spacer(minLength: 16)

                scrubberBlock
                    .padding(.horizontal, 24)

                Spacer(minLength: 12)

                transport

                if horizontalSizeClass == .regular {
                    Spacer(minLength: 18)
                    RouteControls(spacing: 34, openTimer: openTimer)
                    Spacer(minLength: 12)
                } else {
                    Spacer(minLength: 16)
                }
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showChapters) {
            ChapterListSheet()
        }
        .fullScreenCover(item: $markerSelection) { selection in
            FullScreenImageViewer(imageURLs: embeddedImageURLs, startIndex: selection.id)
        }
        // Keyed on syncPath too: attaching a manifest must reload the markers.
        .task(id: [engine.book?.id, engine.book?.syncPath]) { await loadMarkers() }
    }

    /// Markers are m4b-backed by spec: a manifest image only becomes a marker
    /// if an embedded image exists at the same ordinal.
    private func loadMarkers() async {
        markers = []
        embeddedImageURLs = []
        guard let book = engine.book else { return }
        guard let detail = try? await container.bookRepository.detail(bookId: book.id) else { return }
        embeddedImageURLs = detail.images.map { container.fileStore.url(for: $0.cachePath) }
        guard let syncPath = book.syncPath,
              let manifest = SyncManifestParser.parse(fileURL: container.fileStore.url(for: syncPath))
        else { return }
        markers = manifest.images.filter { $0.ordinal < detail.images.count }
    }

    private var chapterSelector: some View {
        Button {
            showChapters = true
        } label: {
            VStack(spacing: 2) {
                Text(chapter?.title ?? "No chapters")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let chapter {
                    Text("Chapter \(chapter.index + 1) of \(engine.chapters.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(engine.chapters.isEmpty)
    }

    // Chapter-relative scrubber, with the whole-book strip between the labels.
    private var scrubberBlock: some View {
        let windowStart = chapter?.startMs ?? 0
        let windowDuration = max(1, (chapter?.durationMs ?? engine.book?.durationMs ?? 1))
        let localMs = displayMs - windowStart

        return VStack(spacing: 6) {
            markerRow(windowStart: windowStart, windowDuration: windowDuration)
            ChapterScrubber(
                value: Double(min(max(0, localMs), windowDuration)),
                duration: Double(windowDuration),
                onScrubChanged: { value in
                    // Freeze the window on the first touch of a drag, so a
                    // preview at the chapter edge can't roll into the next
                    // chapter and cascade.
                    if scrubWindow == nil {
                        scrubWindow = engine.locator.window(atMs: engine.positionMs)
                    }
                    let start = scrubWindow?.startMs ?? windowStart
                    scrubMs = start + Int64(value)
                },
                onScrubEnded: { value in
                    let start = scrubWindow?.startMs ?? windowStart
                    engine.seek(toMs: start + Int64(value))
                    scrubMs = nil
                    scrubWindow = nil
                }
            )
            HStack {
                Text(formatMs(min(max(0, localMs), windowDuration)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                bookStrip
                Spacer()
                // Remaining in the chapter, counting down with the drag (Android).
                Text("-\(formatMs(max(0, windowDuration - localMs)))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Image markers within the current chapter, at their chapter-local
    /// fraction (inset by the slider thumb radius); tap opens the m4b image.
    @ViewBuilder
    private func markerRow(windowStart: Int64, windowDuration: Int64) -> some View {
        let windowEnd = windowStart + windowDuration
        let inChapter = markers.filter { marker in
            let triggerMs = Int64(marker.triggerSeconds * 1000)
            return triggerMs >= windowStart && triggerMs < windowEnd
        }
        if inChapter.isEmpty {
            EmptyView()
        } else {
            GeometryReader { proxy in
                let thumbInset: CGFloat = 14
                let usable = proxy.size.width - thumbInset * 2
                ForEach(inChapter, id: \.ordinal) { marker in
                    let fraction = Double(Int64(marker.triggerSeconds * 1000) - windowStart)
                        / Double(max(1, windowDuration))
                    Button {
                        markerSelection = MarkerSelection(id: marker.ordinal)
                    } label: {
                        Image(systemName: "photo.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.accentColor)
                            .background(Circle().fill(.background))
                    }
                    .position(x: thumbInset + usable * fraction, y: 8)
                }
            }
            .frame(height: 16)
        }
    }

    private var bookStrip: some View {
        let duration = max(1, engine.book?.durationMs ?? 1)
        let remaining = max(0, duration - displayMs)
        return HStack(spacing: 8) {
            ProgressView(value: Double(displayMs), total: Double(duration))
                .frame(width: 140)
            Text("\(formatRemaining(remaining)) left")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var transport: some View {
        HStack(spacing: 28) {
            Button { engine.previousChapter() } label: {
                Image(systemName: "backward.end.fill").font(.title2)
            }
            .disabled(engine.chapters.isEmpty)
            Button { engine.skip(seconds: -10) } label: {
                Image(systemName: "gobackward.10").font(.title)
            }
            Button { engine.togglePlayPause() } label: {
                ZStack {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 72, height: 72)
                    if engine.isBuffering {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title)
                            .foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            Button { engine.skip(seconds: 30) } label: {
                Image(systemName: "goforward.30").font(.title)
            }
            Button { engine.nextChapter() } label: {
                Image(systemName: "forward.end.fill").font(.title2)
            }
            .disabled(engine.chapters.isEmpty)
        }
    }

    private func formatMs(_ ms: Int64) -> String {
        let seconds = ms / 1000
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Minutes rounded up, like Android — it only reads 0 min at the very end.
    private func formatRemaining(_ ms: Int64) -> String {
        let minutes = (max(0, ms) + 59_999) / 60_000
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }
}
