import XCTest

final class ReaderZoomUITests: XCTestCase {
    /// "Larger text" must visibly scale the page: tap it repeatedly and assert
    /// a web text element's frame actually grows, then shrinks back — run
    /// against BOTH books, whose EPUB stylesheets differ (viewport-relative
    /// CSS can invert naive zoom approaches).
    @MainActor
    func testLargerTextGrowsRenderedText() throws {
        try runZoomCheck(
            book: "/Users/osf/Documents/books/toaru/A Certain Magical Index - Volume 03.m4b")
    }

    @MainActor
    func testLargerTextGrowsRenderedTextAscendance() throws {
        try runZoomCheck(
            book: "/Users/osf/Documents/books/ascendance/Ascendance of a Bookworm - Part 5 Avatar of a Goddess v12.m4b")
    }

    @MainActor
    private func runZoomCheck(book: String) throws {
        let app = XCUIApplication()
        // Pin the starting zoom so growth expectations are deterministic.
        app.launchArguments = ["-autoImport", book, "-autoPlay", "-showReader", "-textZoom", "100"]
        app.launch()

        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 60), "Reader did not render")

        // Pause so auto-follow can't move the page under the measurement.
        let pause = app.buttons["pause.fill"].firstMatch
        if pause.waitForExistence(timeout: 5) { pause.tap() }
        Thread.sleep(forTimeInterval: 1)

        // The book may open on a cover/illustration page whose width-clamped
        // image is zoom-immune — page forward (which also disables follow)
        // until a page with real prose shows up, and measure a paragraph.
        let nextPage = app.buttons["chevron.right"].firstMatch
        var sampleLabel = ""
        for _ in 0 ..< 15 {
            let prose = app.webViews.staticTexts.matching(
                NSPredicate(format: "label MATCHES %@", "(?s).{80,}")
            ).firstMatch
            if prose.exists {
                sampleLabel = prose.label
                break
            }
            XCTAssertTrue(nextPage.waitForExistence(timeout: 5), "Next-page button missing")
            nextPage.tap()
            Thread.sleep(forTimeInterval: 1.2)
        }
        XCTAssertFalse(sampleLabel.isEmpty, "No prose page found to measure")
        let sample = app.webViews.staticTexts.matching(
            NSPredicate(format: "label == %@", sampleLabel)
        ).firstMatch
        let before = sample.frame.height
        XCTAssertGreaterThan(before, 0)

        // Also track a SHORT single-line text: its WIDTH is glyph advance —
        // paragraph height alone grows from line-box scaling even when glyphs
        // don't (the historic iPad bug this test must catch).
        let shortQuery = app.webViews.staticTexts.matching(
            NSPredicate(format: "label MATCHES %@", "(?s).{5,45}"))
        let shortLabel = shortQuery.firstMatch.exists ? shortQuery.firstMatch.label : ""
        let shortWidthBefore = shortLabel.isEmpty
            ? 0
            : app.webViews.staticTexts.matching(
                NSPredicate(format: "label == %@", shortLabel)).firstMatch.frame.width

        // A+ is a direct toolbar button now. +10% x4 = at least +40%.
        let larger = app.buttons["Larger text"].firstMatch
        XCTAssertTrue(larger.waitForExistence(timeout: 10), "Larger text button missing")
        for _ in 0 ..< 4 {
            larger.tap()
        }

        // Give the zoom a beat to apply, then re-measure the SAME text.
        Thread.sleep(forTimeInterval: 1)
        let same = app.webViews.staticTexts.matching(
            NSPredicate(format: "label == %@", sampleLabel)
        ).firstMatch
        XCTAssertTrue(same.waitForExistence(timeout: 10), "Measured text vanished after zoom")
        let after = same.frame.height
        XCTAssertGreaterThan(
            after, before * 1.2,
            "Text did not grow after four Larger-text taps (\(before) -> \(after))"
        )
        if !shortLabel.isEmpty, shortWidthBefore > 0 {
            let shortElement = app.webViews.staticTexts.matching(
                NSPredicate(format: "label == %@", shortLabel)).firstMatch
            if shortElement.exists {
                let shortWidthAfter = shortElement.frame.width
                XCTAssertGreaterThan(
                    shortWidthAfter, shortWidthBefore * 1.2,
                    "Glyphs did not scale: short line width \(shortWidthBefore) -> \(shortWidthAfter)"
                )
            }
        }

        // And the opposite direction: Smaller must shrink it back down.
        let smaller = app.buttons["Smaller text"].firstMatch
        XCTAssertTrue(smaller.waitForExistence(timeout: 10), "Smaller text button missing")
        for _ in 0 ..< 6 {
            smaller.tap()
        }
        Thread.sleep(forTimeInterval: 1)
        let shrunk = app.webViews.staticTexts.matching(
            NSPredicate(format: "label == %@", sampleLabel)
        ).firstMatch.frame.height
        XCTAssertLessThan(
            shrunk, after * 0.85,
            "Text did not shrink after six Smaller-text taps (\(after) -> \(shrunk))"
        )
    }
}
