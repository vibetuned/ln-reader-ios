import SwiftUI

@main
struct LnReaderApp: App {
    private let container = AppContainer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.appContainer, container)
        }
    }
}
