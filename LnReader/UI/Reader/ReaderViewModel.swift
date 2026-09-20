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
    private let readingPositionRepository: ReadingPositionRepository
    private let readLogRepository: ReadLogRepository
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

    // MARK: Reading position + usage log

    /// Scroll offset (0…1) to apply once the current page finishes loading — the saved reading
    /// position being restored. One-shot: cleared after it lands, so paging on doesn't re-scroll.
    private var pendingRestoreFraction: Double?
    /// Samples the page's scroll offset while a page is up, so the place is kept as you read.
    private var scrollSampleTask: Task<Void, Never>?
    private var lastSavedIndex = -1
    private var lastSavedFraction = -1.0
    /// The open `readLog` read session, as a Task (the insert is asynchronous).
    private var readSession: Task<String, Error>?
    private var readHeartbeatTask: Task<Void, Never>?

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

    init(
        repository: BookRepository,
        readingPositionRepository: ReadingPositionRepository,
        readLogRepository: ReadLogRepository,
        fileStore: FileStore,
        engine: PlayerEngine
    ) {
        self.repository = repository
        self.readingPositionRepository = readingPositionRepository
        self.readLogRepository = readLogRepository
        self.fileStore = fileStore
        self.engine = engine
        darkMode = defaults.object(forKey: "reader.darkMode") as? Bool ?? false
        textZoom = defaults.object(forKey: "reader.textZoom") as? Int ?? 100
        let configuration = Self.makeWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        super.init()
        webView.navigationDelegate = self
    }

    /// Shared by the reader and the zoom regression harness so tests exercise
    /// the exact production configuration.
    ///
    /// iPad WKWebView treats pages without a viewport meta as desktop content
    /// and runs "idempotent text autosizing" on them, which renormalizes glyph
    /// sizes against any zoom (line boxes scale, letters don't). Three guards
    /// keep it off: mobile content mode here, the viewport meta baked into
    /// every extracted page (EpubReader.injectViewportMeta), and this runtime
    /// fallback script for pages the baker missed.
    static func makeWebViewConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        let viewportScript = WKUserScript(
            source: """
            (function() {
              if (!document.querySelector('meta[name="viewport"]')) {
                var m = document.createElement('meta');
                m.name = 'viewport';
                m.content = 'width=device-width, initial-scale=1';
                (document.head || document.documentElement).appendChild(m);
              }
            })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(viewportScript)
        return configuration
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

        // With sync + this book loaded in the player, follow from the current beat. Otherwise —
        // an EPUB-only book, or an audiobook that isn't the one playing — come back to the saved
        // page and scroll offset.
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
            let saved = try? await readingPositionRepository.get(bookId: bookId)
            let startIndex = min(max(0, saved?.spineIndex ?? 0), max(0, spine.count - 1))
            lastSavedIndex = saved?.spineIndex ?? -1
            lastSavedFraction = saved?.scrollFraction ?? -1
            if let fraction = saved?.scrollFraction, fraction > 0 {
                pendingRestoreFraction = fraction
            }
            loadPage(startIndex)
        }
        startReadSession(bookId: bookId, title: detail.book.title)

        #if DEBUG
        // Dev hook for scripted screenshots/smoke tests: -readerSearch <query>
        // opens the search bar and runs the query once the book is loaded;
        // -readerPage <n> turns to a 1-based page (exercises the page mark).
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-readerPage"), index + 1 < arguments.count,
           let page = Int(arguments[index + 1]), spine.indices.contains(page - 1) {
            followEnabled = false
            pendingRestoreFraction = nil
            loadPage(page - 1)
            persistPosition(spineIndex: page - 1, fraction: 0)
        }
        if let index = arguments.firstIndex(of: "-readerSearch"), index + 1 < arguments.count {
            searchQuery = arguments[index + 1]
            openSearch()
            submitSearch()
            // Drop keyboard focus so captures show the results, not the keyboard.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
        #endif
    }

    // MARK: - Paging

    var canGoBack: Bool { currentIndex > 0 }
    var canGoForward: Bool { currentIndex + 1 < spine.count }

    /// Manual paging pauses auto-follow (Resume re-engages), like Android.
    func nextPage() {
        guard canGoForward else { return }
        followEnabled = false
        loadPage(currentIndex + 1)
        persistPosition(spineIndex: currentIndex, fraction: 0)
    }

    func previousPage() {
        guard canGoBack else { return }
        followEnabled = false
        loadPage(currentIndex - 1)
        persistPosition(spineIndex: currentIndex, fraction: 0)
    }

    func resumeFollow() {
        guard manifest != nil else { return }
        followEnabled = true
        activeBeatId = nil
        tickFollow()
    }

    private func loadPage(_ index: Int) {
        guard let extractionDir, spine.indices.contains(index) else { return }
        // A page being replaced must not have the incoming page's offset sampled against it.
        scrollSampleTask?.cancel()
        scrollSampleTask = nil
        currentIndex = index
        let pageURL = extractionDir.appendingPathComponent(spine[index])
        webView.loadFileURL(pageURL, allowingReadAccessTo: extractionDir)
    }

    // MARK: - Reading position (the EPUB "page mark")

    /// Restores the saved offset once the page has laid out. Run twice because a page with images
    /// grows after `didFinish`, and a single early scroll would land short.
    private func restorePendingScrollIfNeeded() {
        guard let fraction = pendingRestoreFraction else { return }
        pendingRestoreFraction = nil
        let js = Self.restoreScrollJs(fraction: fraction)
        webView.evaluateJavaScript(js)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            // Completion-handler overload: inside an async context the bare call resolves to the
            // `async throws` one, which this doesn't need to wait on.
            self?.webView.evaluateJavaScript(js, completionHandler: nil)
            self?.startScrollSampling()
        }
    }

    /// While a page is up, sample its scroll offset a few times a minute and save when it moved.
    private func startScrollSampling() {
        scrollSampleTask?.cancel()
        let index = currentIndex
        scrollSampleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, self.currentIndex == index else { return }
                let value = try? await self.webView.evaluateJavaScript(Self.scrollFractionJs)
                guard let fraction = (value as? NSNumber)?.doubleValue else { continue }
                self.reportScroll(spineIndex: index, fraction: fraction)
            }
        }
    }

    private func reportScroll(spineIndex: Int, fraction: Double) {
        guard spineIndex == currentIndex, pendingRestoreFraction == nil else { return }
        let clamped = min(1, max(0, fraction))
        // An idle page costs nothing: only a real move is written.
        guard spineIndex != lastSavedIndex || abs(clamped - lastSavedFraction) >= 0.01 else { return }
        persistPosition(spineIndex: spineIndex, fraction: clamped)
    }

    private func persistPosition(spineIndex: Int, fraction: Double) {
        guard let bookId = book?.id else { return }
        lastSavedIndex = spineIndex
        lastSavedFraction = fraction
        let repository = readingPositionRepository
        let count = spine.count
        Task { try? await repository.save(bookId: bookId, spineIndex: spineIndex, scrollFraction: fraction, spineCount: count) }
    }

    /// Fraction (0…1) of the page's scrollable height the viewport sits at; 0 when it all fits.
    static let scrollFractionJs = """
    (function(){
      var d=document.documentElement, b=document.body;
      var h=Math.max(d.scrollHeight, b?b.scrollHeight:0) - window.innerHeight;
      return h>0 ? Math.min(1, Math.max(0, window.scrollY/h)) : 0;
    })();
    """

    static func restoreScrollJs(fraction: Double) -> String {
        """
        (function(f){
          var d=document.documentElement, b=document.body;
          var h=Math.max(d.scrollHeight, b?b.scrollHeight:0) - window.innerHeight;
          if (h>0) window.scrollTo(0, f*h);
        })(\(min(1, max(0, fraction))));
        """
    }

    // MARK: - readLog: read sessions

    private func startReadSession(bookId: String, title: String) {
        endReadSession()
        let repository = readLogRepository
        let index = Int64(currentIndex)
        readSession = Task { try await repository.start(bookId: bookId, bookTitle: title, kind: .read, position: index) }
        readHeartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, let session = self.readSession else { return }
                let position = Int64(self.currentIndex)
                try? await repository.heartbeat(sessionId: try await session.value, position: position)
            }
        }
    }

    private func endReadSession() {
        readHeartbeatTask?.cancel()
        readHeartbeatTask = nil
        guard let session = readSession else { return }
        readSession = nil
        let repository = readLogRepository
        let position = Int64(currentIndex)
        // Detached so closing the row survives the reader being torn down.
        Task.detached { try? await repository.end(sessionId: try await session.value, position: position) }
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
        scrollSampleTask?.cancel()
        scrollSampleTask = nil
        endReadSession()
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
            if pendingRestoreFraction != nil {
                restorePendingScrollIfNeeded()
            } else {
                startScrollSampling()
            }
        }
    }

    // MARK: - JS injection

    /// The reader's injected stylesheet — extracted as a pure function so the
    /// zoom regression harness can inject the exact production CSS.
    ///
    /// Text zoom scales the font cascade at the root, like Android's
    /// settings.textZoom: EPUB prose is sized in em/rem rooted at html, so a
    /// root percentage scales the actual glyphs and preserves the book's
    /// relative type hierarchy. Layout-level zoom (pageZoom / CSS zoom) is
    /// useless on iPad — text autosizing renormalizes glyphs against it.
    /// `-webkit-text-size-adjust: 100%` is honored in mobile content mode and
    /// pins any device autosizing to exactly 1x.
    static func appearanceCss(textZoom: Int, darkMode: Bool) -> String {
        let darkCss = """
        html, body { background: #121316 !important; color: #e8ece9 !important; }
        body * { background-color: transparent !important; color: inherit !important; }
        a { color: #abcfb2 !important; }
        img, svg { opacity: 0.92; }
        """
        let highlightColor = darkMode ? "rgba(198, 146, 52, 0.18)" : "rgba(198, 146, 52, 0.40)"
        let highlightText = darkMode ? "#f1c465" : "#3c2f00"
        return """
        /* System font (San Francisco) instead of WebKit's Times default. */
        body { font-family: -apple-system, "Helvetica Neue", sans-serif !important; }
        body * { font-family: inherit !important; }
        html { font-size: \(textZoom)% !important; -webkit-text-size-adjust: 100%; }
        \(darkMode ? darkCss : "")
        .lnvox-active, .lnvox-active * { color: \(highlightText) !important; }
        .lnvox-active { background-color: \(highlightColor) !important; border-radius: 3px; }
        """
    }

    /// JS that installs/replaces the reader stylesheet on the loaded page —
    /// also shared with the zoom regression harness.
    static func appearanceInjectionJs(css: String) -> String {
        """
        (function() {
          var s = document.getElementById('lnreader-style');
          if (!s) {
            s = document.createElement('style');
            s.id = 'lnreader-style';
            document.head.appendChild(s);
          }
          s.textContent = \(jsQuote(css));
        })();
        """
    }

    private func applyAppearance() {
        let css = Self.appearanceCss(textZoom: textZoom, darkMode: darkMode)
        webView.evaluateJavaScript(Self.appearanceInjectionJs(css: css))
        webView.backgroundColor = darkMode ? UIColor(red: 0.071, green: 0.075, blue: 0.086, alpha: 1) : .systemBackground
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
              '.lnvox-search{background:rgba(198,146,52,0.38) !important;border-radius:2px;}' +
              '.lnvox-search-current{background:rgba(233,195,73,0.95) !important;border-radius:2px;}' +
              '.lnvox-search-current{color:#3c2f00 !important;}';
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
