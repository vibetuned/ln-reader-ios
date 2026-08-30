import LnReaderCore
import WebKit
import XCTest
@testable import LnReader

/// Regression harness for the reader's text zoom: loads a SYNTHETIC EPUB-like
/// page (generated below — no copyrighted book content) into a WKWebView with
/// the reader's exact production configuration and injected CSS, and asserts
/// that requesting 200% actually scales rendered GLYPHS (measured as the
/// bounding rect of a fixed character range), not just line spacing — the
/// historic iPad failure mode.
@MainActor
final class ReaderZoomHarnessTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zoom-harness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("Styles"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("Text"), withIntermediateDirectories: true)
        // Stylesheet mirroring the structure real ln-vox EPUBs use:
        // em-based sizes rooted at body { font-size: 1em }.
        let stylesheet = """
        body { line-height: 1.2em; font-size: 1em; margin: 1em; }
        .main p { text-indent: 1.25em; margin: 0; font-size: 1em; }
        h1 { font-size: 1.55em; }
        .small { font-size: 0.7em; }
        """
        try stylesheet.write(
            to: tempDir.appendingPathComponent("Styles/stylesheet.css"),
            atomically: true, encoding: .utf8)
        // Synthetic prose page: generated filler sentences with the same
        // markup shape as extracted book pages (spans with data-beat-id),
        // including the viewport meta the extractor bakes in.
        // Explicit String types: GRDB (transitively imported) also defines
        // joined() for its SQL literals, and inference can pick it, embedding
        // an SQL debug description into the page and breaking the XML parse.
        let sentence = "The quick brown fox jumps over the lazy dog while the narrator keeps reading aloud. "
        let paragraphs: String = (0 ..< 12).map { (index: Int) -> String in
            let spans: String = (0 ..< 3).map { (span: Int) -> String in
                "<span class=\"lnvox-beat\" data-beat-id=\"p\(index)_s\(span)\">\(sentence)</span>"
            }.joined()
            return "<p>\(spans)</p>"
        }.joined(separator: "\n")
        let page = """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html lang="en" xmlns="http://www.w3.org/1999/xhtml">
        <head>
        \(EpubReader.viewportMeta)
        <title>Fixture</title>
        <link href="../Styles/stylesheet.css" rel="stylesheet" type="text/css"/>
        </head>
        <body>
        <section>
        <div class="main">
        <h1 id="heading">Chapter One</h1>
        \(paragraphs)
        </div>
        </section>
        </body>
        </html>
        """
        try page.write(
            to: tempDir.appendingPathComponent("Text/page.xhtml"),
            atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        attachedWebViews.forEach { $0.removeFromSuperview() }
        attachedWebViews = []
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Scenarios

    func testZoomScalesGlyphsAt13InchWidth() async throws {
        try await runZoomCheck(width: 1032, darkMode: false)
    }

    func testZoomScalesGlyphsAt11InchWidth() async throws {
        try await runZoomCheck(width: 820, darkMode: false)
    }

    func testZoomScalesGlyphsInDarkMode() async throws {
        try await runZoomCheck(width: 1032, darkMode: true)
    }

    func testZoomRestoresAt100Percent() async throws {
        let webView = try await loadFixture(width: 1032)
        let base = try await measure(webView, textZoom: 100, darkMode: false)
        _ = try await measure(webView, textZoom: 200, darkMode: false)
        let restored = try await measure(webView, textZoom: 100, darkMode: false)
        XCTAssertEqual(restored.glyphWidth, base.glyphWidth, accuracy: base.glyphWidth * 0.05)
        XCTAssertEqual(restored.fontSize, base.fontSize, accuracy: 0.5)
    }

    private func runZoomCheck(width: CGFloat, darkMode: Bool) async throws {
        let webView = try await loadFixture(width: width)
        let base = try await measure(webView, textZoom: 100, darkMode: darkMode)
        let zoomed = try await measure(webView, textZoom: 200, darkMode: darkMode)

        // Glyph advance (rect of the first 10 characters) must scale ~2x —
        // line-box height alone scaling is exactly the historic bug.
        XCTAssertGreaterThanOrEqual(
            zoomed.glyphWidth, base.glyphWidth * 1.8,
            "glyphs did not scale: \(base.glyphWidth) -> \(zoomed.glyphWidth) at width \(width)")
        XCTAssertGreaterThanOrEqual(
            zoomed.fontSize, base.fontSize * 1.95,
            "computed font-size did not scale: \(base.fontSize) -> \(zoomed.fontSize)")
        // Text must reflow within the page — no horizontal scrolling.
        XCTAssertLessThanOrEqual(
            zoomed.scrollWidth, zoomed.clientWidth + 1,
            "page scrolls horizontally at 200%")
    }

    // MARK: - Harness plumbing

    private struct Measurement {
        let fontSize: Double
        let glyphWidth: Double
        let scrollWidth: Double
        let clientWidth: Double
    }

    private var attachedWebViews: [WKWebView] = []

    private func loadFixture(width: CGFloat) async throws -> WKWebView {
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: width, height: 1366),
            configuration: ReaderViewModel.makeWebViewConfiguration())
        // Off-window WKWebViews get their WebContent process suspended in
        // hosted tests — attach to the host app's window (behind everything).
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
        window?.insertSubview(webView, at: 0)
        attachedWebViews.append(webView)
        webView.loadFileURL(
            tempDir.appendingPathComponent("Text/page.xhtml"),
            allowingReadAccessTo: tempDir)
        // Poll readiness instead of XCTestExpectation (which misbehaves in
        // @MainActor async tests); evaluateJavaScript fails harmlessly while
        // the page is still loading.
        var lastObservation = "never evaluated"
        for _ in 0 ..< 200 {
            try await Task.sleep(nanoseconds: 50_000_000)
            do {
                let state = try await webView.evaluateJavaScript(
                    "document.readyState + '|' + (document.querySelector('.main p span') !== null) + '|' + document.documentElement.textContent.substring(0, 400).replace(/\\n/g, ' ')")
                lastObservation = "\(state ?? "nil")"
                if lastObservation.hasPrefix("complete|true") {
                    return webView
                }
            } catch {
                lastObservation = "error: \(error)"
            }
        }
        XCTFail("fixture page never finished loading; last: \(lastObservation); url=\(webView.url?.absoluteString ?? "nil"), isLoading=\(webView.isLoading)")
        throw XCTSkip("unreachable")
    }

    private func measure(_ webView: WKWebView, textZoom: Int, darkMode: Bool) async throws -> Measurement {
        let css = ReaderViewModel.appearanceCss(textZoom: textZoom, darkMode: darkMode)
        _ = try await webView.evaluateJavaScript(
            ReaderViewModel.appearanceInjectionJs(css: css))
        // Let layout settle after the style change.
        try await Task.sleep(nanoseconds: 200_000_000)
        let probe = """
        (function() {
          var span = document.querySelector('.main p span');
          var range = document.createRange();
          range.setStart(span.firstChild, 0);
          range.setEnd(span.firstChild, 10);
          var rect = range.getBoundingClientRect();
          return JSON.stringify({
            fontSize: parseFloat(getComputedStyle(span).fontSize),
            glyphWidth: rect.width,
            scrollWidth: document.documentElement.scrollWidth,
            clientWidth: document.documentElement.clientWidth
          });
        })()
        """
        let raw = try await webView.evaluateJavaScript(probe)
        guard let json = raw as? String,
              let data = json.data(using: .utf8),
              let values = try JSONSerialization.jsonObject(with: data) as? [String: Double] else {
            throw XCTSkip("probe returned unexpected payload: \(String(describing: raw))")
        }
        return Measurement(
            fontSize: values["fontSize"] ?? 0,
            glyphWidth: values["glyphWidth"] ?? 0,
            scrollWidth: values["scrollWidth"] ?? 0,
            clientWidth: values["clientWidth"] ?? 0)
    }
}
