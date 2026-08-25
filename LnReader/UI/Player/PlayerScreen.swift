import SwiftUI
import LnReaderCore

struct PlayerScreen: View {
    @Environment(PlayerEngine.self) private var engine
    @Environment(AppNavigation.self) private var navigation

    var body: some View {
        NavigationStack {
            Group {
                if engine.book != nil {
                    PlayerContent()
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
                if let book = engine.book {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            navigation.showImages(bookId: book.id)
                        } label: {
                            Image(systemName: "photo.on.rectangle")
                        }
                    }
                }
            }
        }
    }
}

private struct PlayerContent: View {
    @Environment(PlayerEngine.self) private var engine

    // While dragging, the scrubber drives this book-absolute preview position.
    @State private var scrubMs: Int64?
    @State private var showChapters = false

    private var displayMs: Int64 { scrubMs ?? engine.positionMs }
    private var chapter: ChapterWindow? { engine.locator.window(atMs: displayMs) }

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

                Spacer(minLength: 8)

                bottomBar
                    .padding(.bottom, 12)
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showChapters) {
            ChapterListSheet()
        }
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
            Slider(
                value: Binding(
                    get: { Double(localMs) },
                    set: { scrubMs = windowStart + Int64($0) }
                ),
                in: 0 ... Double(windowDuration)
            ) { editing in
                if !editing, let target = scrubMs {
                    engine.seek(toMs: target)
                    scrubMs = nil
                }
            }
            HStack {
                Text(formatMs(localMs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                bookStrip
                Spacer()
                Text(formatMs(windowDuration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
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

    private var bottomBar: some View {
        HStack {
            Menu {
                Picker("Speed", selection: Binding(
                    get: { engine.rate },
                    set: { engine.setRate($0) }
                )) {
                    ForEach(PlayerEngine.speedPresets, id: \.self) { preset in
                        Text(formatRate(preset)).tag(preset)
                    }
                }
            } label: {
                Label(formatRate(engine.rate), systemImage: "gauge.with.needle")
                    .font(.subheadline)
            }
        }
    }

    private func formatMs(_ ms: Int64) -> String {
        let seconds = ms / 1000
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func formatRemaining(_ ms: Int64) -> String {
        let minutes = ms / 60_000
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    private func formatRate(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...2))))×"
    }
}
