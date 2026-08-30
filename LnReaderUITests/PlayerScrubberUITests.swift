import XCTest

final class PlayerScrubberUITests: XCTestCase {
    /// Dragging the chapter scrubber to its end must advance exactly ONE
    /// chapter — the window is frozen during the drag. The historic bug:
    /// the window followed the drag preview, so the slider max rolled the
    /// preview chapter forward frame after frame, cascading to the end of
    /// the book and leaving every control broken.
    @MainActor
    func testScrubToChapterEndAdvancesOneChapter() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-autoImport", "/Users/osf/Documents/books/toaru/A Certain Magical Index - Volume 03.m4b",
            "-autoPlay",
        ]
        app.launch()

        // Playing from 0 → chapter 1.
        let chapterOne = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Chapter 1 of'")
        ).firstMatch
        XCTAssertTrue(chapterOne.waitForExistence(timeout: 60), "Player did not open on chapter 1")

        let scrubber = app.otherElements["Chapter position"].firstMatch
        XCTAssertTrue(scrubber.waitForExistence(timeout: 10), "Chapter scrubber missing")
        // A real drag: press mid-track, drag to the far right, release once.
        let start = scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.5))
        start.press(forDuration: 0.3, thenDragTo: end)
        Thread.sleep(forTimeInterval: 2)

        // Exactly one chapter forward — not the end of the book.
        let chapterState = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'Chapter '")
        ).firstMatch
        let landed = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Chapter 2 of'")
        ).firstMatch.waitForExistence(timeout: 5)
        XCTAssertTrue(
            landed,
            "Scrub to chapter end did not land on the next chapter; " +
            "chapter control: '\(chapterState.exists ? chapterState.label : "missing")'"
        )
        XCTAssertFalse(
            app.staticTexts.matching(
                NSPredicate(format: "label BEGINSWITH 'Chapter 20 of'")
            ).firstMatch.exists,
            "Scrub cascaded to the end of the book"
        )
    }
}
