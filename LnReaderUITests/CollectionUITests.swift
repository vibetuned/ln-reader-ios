import XCTest

final class CollectionUITests: XCTestCase {
    /// Launches and lands on the Library tab — resume-on-launch may open the
    /// app on the Player tab when a saved position exists.
    @MainActor
    private func launchAtLibrary() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        // firstMatch: the tab bar exposes each tab twice in the accessibility tree.
        let libraryTab = app.buttons["Library"].firstMatch
        if libraryTab.waitForExistence(timeout: 10) {
            libraryTab.tap()
        }
        return app
    }

    @MainActor
    func testCreateCollectionFromLibraryPlusMenu() throws {
        let app = launchAtLibrary()

        let add = app.buttons["Add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "Add button missing from Library toolbar")
        add.tap()

        let newCollection = app.buttons["New collection"]
        XCTAssertTrue(newCollection.waitForExistence(timeout: 5), "New collection menu item missing")
        newCollection.tap()

        let nameField = app.textFields["Name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "Name field did not appear")
        // The field auto-focuses; type without tapping to keep the test fast.
        let name = "Shelf \(Int.random(in: 10_000 ... 99_999))"
        nameField.tap()
        nameField.typeText(name)

        app.buttons["Create"].tap()

        XCTAssertTrue(
            app.staticTexts[name].waitForExistence(timeout: 5),
            "Created collection \"\(name)\" not visible in the library grid"
        )
    }

    @MainActor
    func testTappingBookOpensDetailSheet() throws {
        let app = launchAtLibrary()

        let cell = app.descendants(matching: .any).matching(identifier: "book-cell").firstMatch
        guard cell.waitForExistence(timeout: 10) else {
            throw XCTSkip("No book in the library — import one to exercise this test")
        }
        cell.tap()

        XCTAssertTrue(
            app.buttons["Open"].waitForExistence(timeout: 5),
            "Detail sheet with Open button should appear on book tap"
        )
        // The membership control is a Menu ("Add to collection") or a button
        // ("Remove from …") depending on state; match by label either way.
        let membershipControl = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'collection'"))
            .firstMatch
        XCTAssertTrue(
            membershipControl.waitForExistence(timeout: 3),
            "Detail sheet should offer collection membership"
        )
    }
}
