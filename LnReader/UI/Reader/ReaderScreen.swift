import SwiftUI
import WebKit
import LnReaderCore

/// Full-screen EPUB reader with manual paging, light/dark + text size, and
/// audio-synced beat highlighting when a sync manifest is attached.
struct ReaderScreen: View {
    let bookId: String

    @Environment(\.appContainer) private var container
    @Environment(PlayerEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var model: ReaderViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    ReaderContent(model: model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(model?.book?.title ?? "Reader")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        model?.stop()
                        dismiss()
                    }
                }
            }
        }
        .task {
            if model == nil {
                let model = ReaderViewModel(
                    repository: container.bookRepository,
                    fileStore: container.fileStore,
                    engine: engine
                )
                self.model = model
                await model.load(bookId: bookId)
            }
        }
        .onDisappear { model?.stop() }
    }
}

private struct ReaderContent: View {
    @Bindable var model: ReaderViewModel
    @Environment(PlayerEngine.self) private var engine

    var body: some View {
        Group {
            if let error = model.loadError {
                ContentUnavailableView("Cannot read", systemImage: "book.closed", description: Text(error))
            } else {
                WebViewContainer(webView: model.webView)
                    .overlay {
                        if model.searchActive, model.showSearchResults {
                            SearchResultsList(model: model)
                        }
                    }
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if model.searchActive {
                            ReaderSearchBar(model: model)
                        }
                    }
                    .safeAreaInset(edge: .bottom) {
                        if engine.book != nil {
                            MiniPlayer()
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                        }
                    }
            }
        }
        .toolbar {
            // Plain buttons only — a Menu in the toolbar breaks the system's
            // "…" overflow menu, but buttons collapse into it correctly.
            ToolbarItemGroup(placement: .topBarTrailing) {
                if model.hasSync, !model.followEnabled {
                    Button {
                        model.resumeFollow()
                    } label: {
                        Label("Resume", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                }
                Button {
                    model.searchActive ? model.closeSearch() : model.openSearch()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("Search in book")
                Button {
                    model.darkMode.toggle()
                } label: {
                    Image(systemName: model.darkMode ? "sun.max" : "moon")
                }
                // Inline, not overflow: the reader cover owns its whole nav
                // bar (no tab bar beside it), and overflow menu item taps are
                // dropped intermittently on iPadOS.
                Button {
                    model.textZoom = max(80, model.textZoom - 10)
                } label: {
                    Image(systemName: "textformat.size.smaller")
                }
                .disabled(model.textZoom <= 80)
                .accessibilityLabel("Smaller text")
                Button {
                    model.textZoom = min(250, model.textZoom + 10)
                } label: {
                    Image(systemName: "textformat.size.larger")
                }
                .disabled(model.textZoom >= 250)
                .accessibilityLabel("Larger text")
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    model.previousPage()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!model.canGoBack)
                Spacer()
                Text(model.pageLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.nextPage()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!model.canGoForward)
            }
        }
    }
}

private struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
