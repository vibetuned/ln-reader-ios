import SwiftUI
import LnReaderCore

/// Chapter list bottom sheet; auto-scrolls to the current chapter.
struct ChapterListSheet: View {
    @Environment(PlayerEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(engine.chapters.enumerated()), id: \.offset) { index, chapter in
                        let isCurrent = engine.locator.window(atMs: engine.positionMs)?.index == index
                        Button {
                            engine.seek(toMs: chapter.startMs)
                            dismiss()
                        } label: {
                            HStack {
                                Text(chapter.title)
                                    .fontWeight(isCurrent ? .semibold : .regular)
                                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                                Spacer()
                                Text(formatMs(chapter.startMs))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .id(index)
                    }
                }
                .onAppear {
                    if let current = engine.locator.window(atMs: engine.positionMs)?.index {
                        proxy.scrollTo(current, anchor: .center)
                    }
                }
            }
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func formatMs(_ ms: Int64) -> String {
        let seconds = ms / 1000
        return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}
