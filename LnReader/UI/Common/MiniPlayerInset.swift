import SwiftUI

/// Reserves room at the bottom of a scrolling screen so its last content isn't hidden under the
/// floating mini-player.
///
/// The bar is an `overlay` on the `TabView` — an iOS-style floating now-playing bar rather than
/// part of the layout — so it contributes no safe area of its own and scroll views run happily
/// underneath it. That is fine for a grid of covers you can scroll past, and not fine when the
/// last thing on the screen is a button: Settings' Start/Update timer sits exactly where the bar
/// floats.
///
/// The reserved height is the bar's own height plus the slack between it and the tab bar
/// (`floatingBottomPadding + barHeight − tabBarHeight`). Measured on an iPhone: the bar's card
/// occupies ~700–766pt of an 874pt screen while the content area runs to ~791pt, so 96pt covers
/// it with a few points to spare. A regular-width layout puts the tab bar at the top and floats
/// the bar 8pt from the bottom instead of 72pt, so it needs less.
///
/// The reader doesn't use this: it hosts the mini-player as a real `safeAreaInset` of its own,
/// which lays out correctly without help.
struct MiniPlayerInset: ViewModifier {
    @Environment(PlayerEngine.self) private var engine
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            // Matches RootView's own condition for showing the bar, so the gap appears and
            // disappears with it rather than stranding empty space when nothing is playing.
            if engine.book != nil, navigation.selectedTab != .player {
                Color.clear.frame(height: horizontalSizeClass == .compact ? 96 : 76)
            }
        }
    }
}

extension View {
    /// Reserves room for the floating mini-player. See ``MiniPlayerInset``.
    func miniPlayerInset() -> some View { modifier(MiniPlayerInset()) }
}
