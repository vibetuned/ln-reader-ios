import SwiftUI

/// Manual DI container, mirroring the Android app's AppContainer: process-scoped
/// lazy singletons, no framework. Reached from SwiftUI via `@Environment(\.appContainer)`.
final class AppContainer {
    // Singletons land here as features are ported:
    // database, bookRepository, collectionRepository, positionRepository,
    // playerHolder, sleepTimerController, preferences…
}

private struct AppContainerKey: EnvironmentKey {
    static let defaultValue = AppContainer()
}

extension EnvironmentValues {
    var appContainer: AppContainer {
        get { self[AppContainerKey.self] }
        set { self[AppContainerKey.self] = newValue }
    }
}
