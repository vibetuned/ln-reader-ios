import SwiftUI

@main
struct LnReaderApp: App {
    private let container = AppContainer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.appContainer, container)
            #if DEBUG
                .task { await autoImportIfRequested() }
            #endif
        }
    }

    #if DEBUG
    /// Dev hook: `simctl launch booted com.vibetuned.lnreader -autoImport <path>`
    /// imports a book without driving the file picker (simulator can read host paths).
    private func autoImportIfRequested() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-autoImport"), flag + 1 < arguments.count else { return }
        do {
            let book = try await container.bookRepository.importBook(
                from: URL(fileURLWithPath: arguments[flag + 1]))
            print("autoImport: imported \(book.title)")
        } catch {
            print("autoImport failed: \(error)")
        }
    }
    #endif
}
