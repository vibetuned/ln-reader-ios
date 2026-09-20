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
            ScrollViewReader { proxy in
                Form {
                    StatsSection(
                        stats: stats,
                        granularity: $granularity,
                        onOpenSessions: { showSessions = true }
                    )
                    .id(Anchor.stats)
                    TimerSections(header: "Sleep timer")
                        .id(Anchor.timer)
                }
                .navigationTitle("Settings")
                .navigationDestination(isPresented: $showSessions) { SessionsScreen() }
                // The log grows while you listen, so re-aggregate whenever this screen appears
                // and whenever the range changes.
                .task(id: granularity) { await reload() }
                .miniPlayerInset()
                .onAppear { openRequestedSection(proxy) }
            }
        }
    }

    @State private var showSessions = false

    private enum Anchor: Hashable { case stats, timer }

    /// Dev hook for scripted screenshots: `-settingsSection timer` opens this screen already
    /// scrolled to the sleep timer, which otherwise sits well below the fold. A scripted run
    /// cannot scroll it by hand — simctl has no input verbs and Xcode 26 dropped Simulator.app,
    /// so there is no window to send events to either. The app has to do the scrolling.
    private func openRequestedSection(_ proxy: ScrollViewProxy) {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-settingsSection"),
              index + 1 < arguments.count else { return }
        let anchor: Anchor = arguments[index + 1] == "timer" ? .timer : .stats
        // After the first layout pass: the chart's height is not known until its data arrives,
        // and scrolling before that lands at the wrong offset.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            proxy.scrollTo(anchor, anchor: .top)
        }
        #endif
    }

    private func reload() async {
        stats = try? await container.readLogRepository.stats(granularity: granularity)
    }
}
