import SwiftUI

/// Stand-in for screens not yet ported.
struct PlaceholderScreen: View {
    let title: String
    let systemImage: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView(title, systemImage: systemImage, description: Text("Coming soon"))
                .navigationTitle(title)
        }
    }
}
