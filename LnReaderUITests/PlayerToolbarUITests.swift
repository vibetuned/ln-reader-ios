import XCTest

final class PlayerToolbarUITests: XCTestCase {
    /// Regression test for the iPadOS toolbar overflow: when player toolbar
    /// items collapse into "…", tapping it must open a menu with the hidden
    /// items (a Menu among toolbar items used to break it silently).
    @MainActor
    func testPlayerToolbarOverflowMenuOpens() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-autoImport", "/Users/osf/Documents/books/toaru/A Certain Magical Index - Volume 03.m4b",
            "-autoPlay",
        ]
        app.launch()

        // -autoPlay lands on the Player tab; wait for the toolbar to settle.
        let speedButton = app.buttons["Playback speed"].firstMatch
        _ = speedButton.waitForExistence(timeout: 20)

        // Unique labels only ("Images" collides with the tab button).
        let candidates = ["Playback speed", "Sleep timer", "Read", "View images"]
        let hiddenBefore = candidates.filter {
            let element = app.buttons[$0].firstMatch
            return !element.exists || !element.isHittable
        }

        let overflow = app.buttons.matching(
            NSPredicate(format: "identifier CONTAINS[c] 'overflow' OR label IN {'More', 'Plus'}")
        ).firstMatch

        guard overflow.exists, !hiddenBefore.isEmpty else {
            throw XCTSkip("No toolbar overflow at this window size — all items visible")
        }

        overflow.tap()
        Thread.sleep(forTimeInterval: 2)
        print("OVERFLOW-OPEN\n\(app.debugDescription)\nOVERFLOW-END")

        let reappeared = hiddenBefore.first { label in
            let element = app.buttons[label].firstMatch
            return element.waitForExistence(timeout: 5) && element.isHittable
        }
        XCTAssertNotNil(
            reappeared,
            "Overflow menu did not open; hidden items \(hiddenBefore) never became tappable"
        )

        // The revealed item must actually work.
        if reappeared == "Playback speed" {
            app.buttons["Playback speed"].firstMatch.tap()
            XCTAssertTrue(
                app.staticTexts["Playback speed"].waitForExistence(timeout: 5),
                "Speed sheet did not open from the overflow menu"
            )
        } else if reappeared == "Sleep timer" {
            app.buttons["Sleep timer"].firstMatch.tap()
            XCTAssertTrue(
                app.staticTexts["Sleep Timer"].waitForExistence(timeout: 5),
                "Timer sheet did not open from the overflow menu"
            )
        }
    }
}
