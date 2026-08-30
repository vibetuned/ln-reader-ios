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

        // Each tap closes the menu; reopen for the next one. +10% x4 = at least +40%.
        for _ in 0 ..< 4 {
            let overflow = app.buttons.matching(
                NSPredicate(format: "identifier CONTAINS[c] 'overflow' OR label IN {'More', 'Plus'}")
            ).firstMatch
            XCTAssertTrue(overflow.waitForExistence(timeout: 10), "Reader overflow button missing")
            overflow.tap()
            let larger = app.buttons["Larger text"].firstMatch
            XCTAssertTrue(larger.waitForExistence(timeout: 5), "Larger text item missing from overflow")
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
    }
}
