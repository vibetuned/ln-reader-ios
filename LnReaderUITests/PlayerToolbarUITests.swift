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

        // -autoPlay lands on the Player tab; wait for the body row to settle
        // (Sleep timer lives in the player body, never in the bar).
        _ = app.buttons["Sleep timer"].firstMatch.waitForExistence(timeout: 20)

        // Overflow-only items with unique labels ("Images" collides with the tab).
        let candidates = ["Chapters", "View images"]
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
        if reappeared == "Chapters" {
            app.buttons["Chapters"].firstMatch.tap()
            XCTAssertTrue(
                app.staticTexts["Chapters"].waitForExistence(timeout: 5),
                "Chapter sheet did not open from the overflow menu"
            )
        }
    }

    /// The stateful controls must be visible in the player body at every
    /// width — never collapsed into a toolbar overflow (11-inch regression).
    @MainActor
    func testStatefulControlsAlwaysVisible() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-autoImport", "/Users/osf/Documents/books/toaru/A Certain Magical Index - Volume 03.m4b",
            "-autoPlay",
        ]
        app.launch()

        for label in ["Sleep timer", "AirPlay", "Read"] {
            let element = app.buttons[label].firstMatch.exists
                ? app.buttons[label].firstMatch
                : app.otherElements[label].firstMatch
            XCTAssertTrue(
                element.waitForExistence(timeout: 30) && element.isHittable,
                "\(label) control is not visible/hittable in the player"
            )
        }
    }
}
