import SwiftUI
import LnReaderCore

/// The Settings tab, mirroring Android's: a single place for the app's occasional knobs.
///
/// Android has three sections here — Downloads, Time spent and Sleep timer. iOS has no download
/// location to choose (every import is copied into the app container), so it carries the other two.
struct SettingsScreen: View {
    @Environment(\.appContainer) private var container
    @State private var granularity: StatsGranularity = .day
    @State private var stats: ReadingStats?

    var body: some View {
        NavigationStack {
            Form {
                StatsSection(
                    stats: stats,
                    granularity: $granularity,
                    onOpenSessions: { showSessions = true }
                )
                TimerSections(header: "Sleep timer")
            }
            .navigationTitle("Settings")
            .navigationDestination(isPresented: $showSessions) { SessionsScreen() }
            // The log grows while you listen, so re-aggregate whenever this screen appears
            // and whenever the range changes.
            .task(id: granularity) { await reload() }
            .miniPlayerInset()
        }
    }

    @State private var showSessions = false

    private func reload() async {
        stats = try? await container.readLogRepository.stats(granularity: granularity)
    }
}
