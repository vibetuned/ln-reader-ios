import SwiftUI

/// Top-level tab layout, mirroring the Android app's bottom navigation:
/// Library, Player, Images, Timer, Settings.
struct RootView: View {
    enum Tab: Hashable {
        case library, player, images, timer, settings
    }

    @State private var selection: Tab = .library

    var body: some View {
        TabView(selection: $selection) {
            LibraryScreen()
                .tabItem { Label("Library", systemImage: "books.vertical") }
                .tag(Tab.library)
            PlayerScreen()
                .tabItem { Label("Player", systemImage: "play.circle") }
                .tag(Tab.player)
            ViewerScreen()
                .tabItem { Label("Images", systemImage: "photo.on.rectangle") }
                .tag(Tab.images)
            TimerScreen()
                .tabItem { Label("Timer", systemImage: "moon.zzz") }
                .tag(Tab.timer)
            SettingsScreen()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
    }
}

#Preview {
    RootView()
}
