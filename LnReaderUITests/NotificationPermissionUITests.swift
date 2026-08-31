import XCTest

/// One-shot helper for scripted screenshot runs: arming the sleep timer asks
/// for notification permission; this taps the system dialog's Allow button so
/// it never appears in captures. Idempotent — passes when no dialog shows.
final class NotificationPermissionUITests: XCTestCase {
    @MainActor
    func testGrantNotificationPermission() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-armTimer", "30", "-tab", "timer"]
        app.launch()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        if alert.waitForExistence(timeout: 10) {
            // Allow is the trailing button whatever the system language
            // ("Allow" / "Autoriser").
            let allow = alert.buttons.element(boundBy: alert.buttons.count - 1)
            allow.tap()
            sleep(1)
        }
    }
}
