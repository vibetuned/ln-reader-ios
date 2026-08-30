import XCTest

final class ReaderSearchUITests: XCTestCase {
    /// Whole-book search: open the reader, search a word, open the first
    /// result, and confirm the n/m stepping counter appears.
    @MainActor
    func testWholeBookSearchFindsMatches() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-autoImport", "/Users/osf/Documents/books/toaru/A Certain Magical Index - Volume 03.m4b",
            "-autoPlay", "-showReader",
        ]
        app.launch()

        let searchButton = app.buttons["Search in book"]
        XCTAssertTrue(searchButton.waitForExistence(timeout: 60), "Reader search button missing")
        searchButton.tap()

        let field = app.textFields["Search in book"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Search field did not appear")
        field.tap()
        field.typeText("wind\n")

        let firstResult = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Page '")
        ).firstMatch
        XCTAssertTrue(firstResult.waitForExistence(timeout: 20), "No search results listed")
        firstResult.tap()

        let counter = app.buttons.matching(
            NSPredicate(format: "label MATCHES '1/[0-9]+'")
        ).firstMatch
        XCTAssertTrue(counter.waitForExistence(timeout: 5), "Match counter missing after opening a result")

        // Step to the next match and back.
        app.buttons["Next match"].tap()
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label MATCHES '2/[0-9]+'")).firstMatch
                .waitForExistence(timeout: 5),
            "Stepping to the next match did not advance the counter"
        )
    }
}
