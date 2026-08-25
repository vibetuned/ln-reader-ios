import Foundation
import Observation
import WebKit
import LnReaderCore

/// Owns the reader's WKWebView, the spine position, appearance (dark + text
/// zoom, persisted app-wide), and the audio-sync follow loop — the iOS analog
/// of Android's ReaderViewModel + WebView plumbing.
@MainActor
@Observable
final class ReaderViewModel: NSObject, WKNavigationDelegate {
    private let repository: BookRepository
    private let fileStore: FileStore
    private let engine: PlayerEngine
    private let defaults = UserDefaults.standard

    let webView: WKWebView
    private(set) var book: Book?
    private(set) var spine: [String] = []
    private(set) var currentIndex = 0
    private(set) var manifest: SyncManifest?
    private(set) var followEnabled = false
    private(set) var loadError: String?

    var hasSync: Bool { manifest != nil }
    var pageLabel: String { spine.isEmpty ? "" : "\(currentIndex + 1) / \(spine.count)" }

    var darkMode: Bool {
        didSet {
            defaults.set(darkMode, forKey: "reader.darkMode")
            applyAppearance()
        }
    }

    /// Font scale in percent, 80–250 like Android's textZoom.
    var textZoom: Int {
        didSet {
            defaults.set(textZoom, forKey: "reader.textZoom")
            applyAppearance()
        }
    }

    private var extractionDir: URL?
    private var activeBeatId: String?
    private var followTask: Task<Void, Never>?

    init(repository: BookRepository, fileStore: FileStore, engine: PlayerEngine) {
        self.repository = repository
        self.fileStore = fileStore
        self.engine = engine
        darkMode = defaults.object(forKey: "reader.darkMode") as? Bool ?? false
        textZoom = defaults.object(forKey: "reader.textZoom") as? Int ?? 100
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        super.init()
        webView.navigationDelegate = self
    }

    // MARK: - Loading

    func load(bookId: String) async {
        guard let detail = try? await repository.detail(bookId: bookId),
              let epubPath = detail.book.epubPath else {
            loadError = "This book has no EPUB attached."
            return
        }
        book = detail.book

        let dir = fileStore.epubExtractionDir(bookId: bookId)
        do {
            let epubURL = fileStore.url(for: epubPath)
            // Extraction can take a moment for a big EPUB; off the main actor.
            try await Task.detached(priority: .userInitiated) {
                try EpubReader.ensureExtracted(epubURL: epubURL, to: dir)
            }.value
            let parsed = try EpubReader.parse(extractedDir: dir)
            extractionDir = dir
            spine = parsed.spine
        } catch {
            loadError = "Could not open EPUB: \(error.localizedDescription)"
            return
        }

        if let syncPath = detail.book.syncPath {
            manifest = SyncManifestParser.parse(fileURL: fileStore.url(for: syncPath))
        }

        // With sync + this book loaded in the player, follow from the current
        // beat; otherwise start at the first page.
        if manifest != nil, engine.book?.id == bookId {
            followEnabled = true
            if let beat = currentBeat() {
                activeBeatId = nil // force re-highlight after the page loads
                loadPage(spineIndex(for: beat) ?? 0)
            } else {
                loadPage(0)
            }
            startFollowLoop()
        } else {
            loadPage(0)
        }
    }

    // MARK: - Paging

    var canGoBack: Bool { currentIndex > 0 }
    var canGoForward: Bool { currentIndex + 1 < spine.count }

    /// Manual paging pauses auto-follow (Resume re-engages), like Android.
    func nextPage() {
        guard canGoForward else { return }
        followEnabled = false
        loadPage(currentIndex + 1)
    }

    func previousPage() {
        guard canGoBack else { return }
        followEnabled = false
        loadPage(currentIndex - 1)
    }

    func resumeFollow() {
        guard manifest != nil else { return }
        followEnabled = true
        activeBeatId = nil
        tickFollow()
    }

    private func loadPage(_ index: Int) {
        guard let extractionDir, spine.indices.contains(index) else { return }
        currentIndex = index
        let pageURL = extractionDir.appendingPathComponent(spine[index])
        webView.loadFileURL(pageURL, allowingReadAccessTo: extractionDir)
    }

    // MARK: - Audio-sync follow

    private func startFollowLoop() {
        followTask?.cancel()
        followTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                self?.tickFollow()
            }
        }
    }

    func stop() {
        followTask?.cancel()
        followTask = nil
    }

    private func currentBeat() -> SyncBeat? {
        guard let manifest, let book, engine.book?.id == book.id else { return nil }
        return manifest.beat(atMs: engine.positionMs)
    }

    private func tickFollow() {
        guard followEnabled, let beat = currentBeat(), beat.dataBeatId != activeBeatId else { return }
        activeBeatId = beat.dataBeatId
        if let pageIndex = spineIndex(for: beat), pageIndex != currentIndex {
            loadPage(pageIndex) // highlight applied on didFinish
        } else {
            highlight(beatId: beat.dataBeatId)
        }
    }

    private func spineIndex(for beat: SyncBeat) -> Int? {
        spine.firstIndex(of: beat.xhtml)
            ?? spine.firstIndex { $0.hasSuffix(beat.xhtml) || beat.xhtml.hasSuffix($0) }
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            applyAppearance()
            if followEnabled, let activeBeatId {
                highlight(beatId: activeBeatId)
            }
        }
    }

    // MARK: - JS injection

    private func applyAppearance() {
        let dataAttr = manifest?.dataAttr ?? "data-beat-id"
        _ = dataAttr // documented for the highlight selector below
        let darkCss = """
        html, body { background: #121212 !important; color: #e2e2e2 !important; }
        body * { background-color: transparent !important; color: inherit !important; }
        a { color: #8ab4f8 !important; }
        img, svg { opacity: 0.92; }
        """
        let highlightColor = darkMode ? "rgba(255, 214, 79, 0.35)" : "rgba(255, 214, 79, 0.55)"
        let css = """
        \(darkMode ? darkCss : "")
        .lnvox-active { background-color: \(highlightColor) !important; border-radius: 3px; }
        """
        let js = """
        (function() {
          var s = document.getElementById('lnreader-style');
          if (!s) {
            s = document.createElement('style');
            s.id = 'lnreader-style';
            document.head.appendChild(s);
          }
          s.textContent = \(jsString(css));
          document.documentElement.style.webkitTextSizeAdjust = '\(textZoom)%';
        })();
        """
        webView.evaluateJavaScript(js)
        webView.backgroundColor = darkMode ? UIColor(white: 0.07, alpha: 1) : .systemBackground
        webView.scrollView.backgroundColor = webView.backgroundColor
    }

    private func highlight(beatId: String) {
        let dataAttr = manifest?.dataAttr ?? "data-beat-id"
        let js = """
        (function() {
          document.querySelectorAll('.lnvox-active').forEach(function(e) {
            e.classList.remove('lnvox-active');
          });
          var el = document.querySelector('[\(dataAttr)="' + \(jsString(beatId)) + '"]');
          if (el) {
            el.classList.add('lnvox-active');
            el.scrollIntoView({ block: 'center', behavior: 'smooth' });
          }
        })();
        """
        webView.evaluateJavaScript(js)
    }

    /// JSON-encodes a string for safe embedding in evaluateJavaScript source.
    private func jsString(_ value: String) -> String {
        String(data: try! JSONEncoder().encode([value]), encoding: .utf8)!
            .dropFirst().dropLast().description
    }
}
