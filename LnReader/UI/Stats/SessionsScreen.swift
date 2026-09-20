import SwiftUI
import LnReaderCore

/// Every recorded session, newest first — the chart's "Details".
///
/// History is unbounded: every play and every reading stretch adds a row. The list never loads it
/// whole; `loadMore` appends the next page as the tail comes into view. Pages are addressed by
/// offset rather than a cursor because the log is append-only and ordered by a fixed key, so a
/// page can't shift under us mid-scroll.
struct SessionsScreen: View {
    @Environment(\.appContainer) private var container
    @State private var model: SessionsModel?

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model == nil {
                let model = SessionsModel(repository: container.readLogRepository)
                self.model = model
                await model.loadMore()
            }
        }
    }

    private func content(_ model: SessionsModel) -> some View {
        List {
            if model.sessions.isEmpty && !model.isLoadingPage {
                Text("No sessions recorded yet.")
                    .foregroundStyle(.secondary)
            } else {
                Section {
                    ForEach(model.sessions) { session in
                        SessionRow(session: session)
                            .task {
                                // Reaching the tail asks for the next page.
                                if session.id == model.sessions.suffix(SessionsModel.prefetch).first?.id {
                                    await model.loadMore()
                                }
                            }
                    }
                    if !model.reachedEnd {
                        HStack {
                            Spacer(); ProgressView(); Spacer()
                        }
                    }
                } header: {
                    Text("\(model.total) \(model.total == 1 ? "session" : "sessions")")
                }
            }
        }
        .miniPlayerInset()
    }
}

private struct SessionRow: View {
    let session: ReadLogEntry

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: session.kind == .listen ? "headphones" : "book")
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityLabel(session.kind == .listen ? "Listened" : "Read")
            VStack(alignment: .leading, spacing: 2) {
                Text(session.bookTitle.isEmpty ? "Untitled" : session.bookTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(formatTotal(Int64(session.duration * 1000)))
                .font(.callout.monospacedDigit())
                .foregroundStyle(Color.accentColor)
        }
    }
}

/// Holds the pages the list has scrolled through. Deliberately not an `AsyncValueObservation`:
/// re-running a whole-table observation on every appended session would defeat the paging.
@MainActor
@Observable
final class SessionsModel {
    static let pageSize = 30
    /// How many rows from the end to start fetching, so the next page arrives before it's needed.
    static let prefetch = 6

    private let repository: ReadLogRepository
    private(set) var sessions: [ReadLogEntry] = []
    private(set) var total = 0
    private(set) var isLoadingPage = false
    private(set) var reachedEnd = false

    init(repository: ReadLogRepository) {
        self.repository = repository
    }

    func loadMore() async {
        guard !isLoadingPage, !reachedEnd else { return }
        isLoadingPage = true
        defer { isLoadingPage = false }
        if total == 0 { total = (try? await repository.count()) ?? 0 }
        let page = (try? await repository.page(limit: Self.pageSize, offset: sessions.count)) ?? []
        sessions.append(contentsOf: page)
        reachedEnd = page.count < Self.pageSize
    }
}
