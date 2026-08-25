import Observation

enum RootTab: Hashable {
    case library, player, images, timer, settings
}

/// Process-scoped navigation state, so non-UI code (mini-player taps,
/// resume-on-launch, book taps) can switch tabs.
@MainActor
@Observable
final class AppNavigation {
    var selectedTab: RootTab = .library
    /// Explicit viewer target (detail sheet → "View images"); nil = the playing book.
    var viewerBookId: String?

    func showImages(bookId: String?) {
        viewerBookId = bookId
        selectedTab = .images
    }
}
