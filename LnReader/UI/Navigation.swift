import Foundation
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
    /// Book whose EPUB the full-screen reader shows; nil = reader closed.
    var readerBookId: String?
    /// An .epub / sync .json that arrived via AirDrop / "Open in…" and waits
    /// for the user to pick which book to attach it to.
    var pendingAttachment: URL?

    func showImages(bookId: String?) {
        viewerBookId = bookId
        selectedTab = .images
    }

    func showReader(bookId: String) {
        readerBookId = bookId
    }
}
