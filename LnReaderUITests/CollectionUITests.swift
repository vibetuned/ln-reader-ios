import XCTest

final class CollectionUITests: XCTestCase {
    @MainActor
    func testCreateCollectionFromLibraryPlusMenu() throws {
        let app = XCUIApplication()
        app.launch()

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
}
