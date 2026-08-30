import SwiftUI

/// Top-level tab layout, mirroring the Android app's bottom navigation:
/// Library, Player, Images, Timer, Settings. A mini-player floats over every
/// tab except the full player while a book is loaded.
struct RootView: View {
    @Environment(AppNavigation.self) private var navigation
    @Environment(PlayerEngine.self) private var engine
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        @Bindable var navigation = navigation
        TabView(selection: $navigation.selectedTab) {
            LibraryScreen()
                .tabItem { Label("Library", systemImage: "books.vertical") }
                .tag(RootTab.library)
            PlayerScreen()
                .tabItem { Label("Player", systemImage: "play.circle") }
                .tag(RootTab.player)
            ViewerScreen()
                .tabItem { Label("Images", systemImage: "photo.on.rectangle") }
                .tag(RootTab.images)
            TimerScreen()
                .tabItem { Label("Timer", systemImage: "moon.zzz") }
                .tag(RootTab.timer)
            SettingsScreen()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(RootTab.settings)
        }
        .overlay(alignment: .bottom) {
            if engine.book != nil, navigation.selectedTab != .player {
                MiniPlayer()
                    .padding(.horizontal, 12)
                    // iPhone's tab bar sits at the bottom; iPad's sits at the top.
                    .padding(.bottom, horizontalSizeClass == .compact ? 72 : 8)
            }
        }
        .fullScreenCover(item: readerTarget) { target in
            ReaderScreen(bookId: target.id)
                .modifier(ContinueCollectionHost(active: true))
                .modifier(SleepTimerExpiredHost(active: true))
        }
        .modifier(ContinueCollectionHost(active: navigation.readerBookId == nil))
        .modifier(SleepTimerExpiredHost(active: navigation.readerBookId == nil))
    }

    private var readerTarget: Binding<ReaderTarget?> {
        Binding(
            get: { navigation.readerBookId.map(ReaderTarget.init(id:)) },
            set: { navigation.readerBookId = $0?.id }
        )
    }

    private struct ReaderTarget: Identifiable {
        let id: String
    }
}
