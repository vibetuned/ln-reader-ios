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

    // MARK: Whole-book search state (mirrors the Android ReaderUiState fields)

    /// The match the WebView should highlight and scroll to once its page loads.
    struct SearchTarget {
        let spineIndex: Int
        let occurrence: Int
        let jsPattern: String
    }

    private(set) var searchActive = false
    var searchQuery = ""
    private(set) var isSearching = false
    /// nil = nothing submitted yet; empty = the submitted query had no matches.
    private(set) var searchResults: [EpubSearchMatch]?
    /// JS regex for the query the results belong to (the field may have been edited since).
    private var searchPatternJs: String?
    var showSearchResults = false
    /// Index into `searchResults` of the match being viewed, for prev/next stepping.
    private(set) var searchSelection: Int?
    private var searchTarget: SearchTarget?

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

    // MARK: - Whole-book search

    func openSearch() {
        searchActive = true
        showSearchResults = searchResults != nil
    }

    func closeSearch() {
        searchActive = false
        searchQuery = ""
        isSearching = false
        searchResults = nil
        searchPatternJs = nil
        showSearchResults = false
        searchSelection = nil
        searchTarget = nil
        webView.evaluateJavaScript(Self.clearSearchJs)
    }

    func submitSearch() {
        let query = searchQuery
        guard let rootDir = extractionDir,
              let jsPattern = EpubTextSearch.jsPattern(for: query),
              !spine.isEmpty else { return }
        // Clearing the target also drops highlights from the previous query.
        isSearching = true
        showSearchResults = true
        searchSelection = nil
        searchTarget = nil
        searchPatternJs = jsPattern
        let paths = spine
        Task { [weak self] in
            let matches = await Task.detached(priority: .userInitiated) {
                EpubTextSearch.search(rootDir: rootDir, spinePaths: paths, query: query)
            }.value
            guard let self else { return }
            // The user may have edited the query and resubmitted while this scan ran.
            guard self.searchQuery == query else { return }
            self.isSearching = false
            self.searchResults = matches
        }
    }

    func openSearchResult(_ index: Int) {
        guard let result = searchResults?.indices.contains(index) == true ? searchResults?[index] : nil,
              let pattern = searchPatternJs else { return }
        followEnabled = false // jumping to a match leaves auto-follow, like manual paging
        showSearchResults = false
        searchSelection = index
        searchTarget = SearchTarget(
            spineIndex: result.spineIndex, occurrence: result.occurrence, jsPattern: pattern)
        if result.spineIndex != currentIndex {
            loadPage(result.spineIndex) // highlight applied on didFinish
        } else {
            applySearchHighlight()
        }
    }

    func stepSearchResult(_ delta: Int) {
        guard let selection = searchSelection else { return }
        openSearchResult(selection + delta)
    }

    private func applySearchHighlight() {
        guard let target = searchTarget, target.spineIndex == currentIndex else { return }
        webView.evaluateJavaScript(Self.searchHighlightJs(
            jsPattern: target.jsPattern, occurrence: target.occurrence))
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            applyAppearance()
            if followEnabled, let activeBeatId {
                highlight(beatId: activeBeatId)
            }
            applySearchHighlight()
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
        /* System font (San Francisco) instead of WebKit's Times default. */
        body { font-family: -apple-system, "Helvetica Neue", sans-serif !important; }
        body * { font-family: inherit !important; }
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
        })();
        """
        webView.evaluateJavaScript(js)
        // -webkit-text-size-adjust is an iPhone-Safari-only feature (a silent
        // no-op in WKWebView on iPad); pageZoom is the native equivalent of
        // Android's settings.textZoom.
        webView.pageZoom = CGFloat(textZoom) / 100
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
        Self.jsQuote(value)
    }

    private static func jsQuote(_ value: String) -> String {
        String(data: try! JSONEncoder().encode([value]), encoding: .utf8)!
            .dropFirst().dropLast().description
    }

    // MARK: - Search JS (ported verbatim from the Android ReaderSearch.kt)

    /// Removes every search highlight span, restoring the original text nodes.
    static let clearSearchJs = """
    (function(){
      document.querySelectorAll('span.lnvox-search, span.lnvox-search-current').forEach(function(el){
        var p = el.parentNode;
        while (el.firstChild) p.insertBefore(el.firstChild, el);
        p.removeChild(el);
        p.normalize();
      });
    })();
    """

    /// Highlights every match of `jsPattern` on the loaded page and scrolls to
    /// the match with document-order index `occurrence`. Walks the body's text
    /// nodes, searches their concatenation (so matches spanning inline tags are
    /// found), then wraps each match's per-node slices in spans — strictly
    /// right to left, so earlier offsets stay valid as nodes get split.
    /// Occurrence indexes agree with EpubTextSearch, which mirrors this
    /// text extraction.
    static func searchHighlightJs(jsPattern: String, occurrence: Int) -> String {
        """
        (function(){
          var STYLE_ID = 'lnvox-search-style';
          if (!document.getElementById(STYLE_ID)) {
            var st = document.createElement('style');
            st.id = STYLE_ID;
            st.textContent =
              '.lnvox-search{background:rgba(255,213,79,0.45) !important;border-radius:2px;}' +
              '.lnvox-search-current{background:rgba(255,152,0,0.95) !important;border-radius:2px;}' +
              '.lnvox-search-current{color:#1a1a1a !important;}';
            (document.head || document.documentElement).appendChild(st);
          }
          \(clearSearchJs)
          var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
          var nodes = [], starts = [], lens = [], text = '';
          var n;
          while ((n = walker.nextNode())) {
            var tag = n.parentNode && n.parentNode.nodeName;
            if (tag === 'SCRIPT' || tag === 'STYLE') continue;
            starts.push(text.length);
            lens.push(n.nodeValue.length);
            nodes.push(n);
            text += n.nodeValue;
          }
          var re = new RegExp(\(jsQuote(jsPattern)), 'gi');
          var matches = [], m;
          while ((m = re.exec(text))) {
            if (m[0].length === 0) { re.lastIndex++; continue; }
            matches.push([m.index, m.index + m[0].length]);
            if (matches.length > 2000) break;
          }
          var K = \(occurrence);
          var j = nodes.length - 1;
          for (var i = matches.length - 1; i >= 0; i--) {
            var ms = matches[i][0], me = matches[i][1];
            var cls = (i === K) ? 'lnvox-search-current' : 'lnvox-search';
            while (j > 0 && starts[j] >= me) j--;
            var firstSpan = null;
            for (var k = j; k >= 0; k--) {
              var ns = starts[k], ne = ns + lens[k];
              if (ne <= ms) break;
              if (ns >= me) continue;
              var s = Math.max(ms, ns) - ns, e = Math.min(me, ne) - ns;
              if (e <= s || nodes[k].nodeValue.length < e) continue;
              var r = document.createRange();
              r.setStart(nodes[k], s);
              r.setEnd(nodes[k], e);
              var span = document.createElement('span');
              span.className = cls;
              try { r.surroundContents(span); firstSpan = span; } catch (ex) {}
            }
            if (i === K && firstSpan) firstSpan.scrollIntoView({block:'center'});
          }
        })();
        """
    }
}
