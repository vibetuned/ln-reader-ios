import XCTest

final class ReaderZoomUITests: XCTestCase {
    /// "Larger text" must visibly scale the page: tap it repeatedly via the
    /// toolbar overflow and assert a web text element's frame actually grows
    /// (the old -webkit-text-size-adjust CSS was a silent no-op on iPad).
    @MainActor
    func testLargerTextGrowsRenderedText() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-autoImport", "/Users/osf/Documents/books/toaru/A Certain Magical Index - Volume 03.m4b",
            "-autoPlay", "-showReader",
        ]
        app.launch()

        let webText = app.webViews.staticTexts.firstMatch
        XCTAssertTrue(webText.waitForExistence(timeout: 60), "Reader page did not render")

        // Pause via the mini-player so auto-follow can't change the page (or
        // scroll) under the measurement — and the current page has text.
        let pause = app.buttons["pause.fill"].firstMatch
        if pause.waitForExistence(timeout: 5) { pause.tap() }
        Thread.sleep(forTimeInterval: 1)

        // Track one concrete text by its content, not by position.
        let sample = app.webViews.staticTexts.firstMatch
        XCTAssertTrue(sample.waitForExistence(timeout: 10))
        let sampleLabel = sample.label
        XCTAssertFalse(sampleLabel.isEmpty)
        let before = sample.frame.height
        XCTAssertGreaterThan(before, 0)

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
