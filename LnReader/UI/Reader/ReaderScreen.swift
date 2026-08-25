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

    var body: some View {
        Group {
            if let error = model.loadError {
                ContentUnavailableView("Cannot read", systemImage: "book.closed", description: Text(error))
            } else {
                WebViewContainer(webView: model.webView)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if model.hasSync, !model.followEnabled {
                    Button {
                        model.resumeFollow()
                    } label: {
                        Label("Resume", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                }
                Button {
                    model.darkMode.toggle()
                } label: {
                    Image(systemName: model.darkMode ? "sun.max" : "moon")
                }
                Button {
                    model.textZoom = max(80, model.textZoom - 10)
                } label: {
                    Image(systemName: "textformat.size.smaller")
                }
                .disabled(model.textZoom <= 80)
                Button {
                    model.textZoom = min(250, model.textZoom + 10)
                } label: {
                    Image(systemName: "textformat.size.larger")
                }
                .disabled(model.textZoom >= 250)
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
