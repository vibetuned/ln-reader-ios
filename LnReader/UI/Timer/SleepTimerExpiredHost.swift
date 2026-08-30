import SwiftUI

/// Global host for the sleep-timer-expired prompt: an alert over whatever
/// screen is showing when the timer fires while the app is open (the
/// notification covers the background case). The alert, the notification
/// actions, and shake-to-postpone all drive the same controller state, so
/// acting on any one clears the others. Attached to the tab root and to the
/// reader cover, one `active` at a time — like ContinueCollectionHost.
struct SleepTimerExpiredHost: ViewModifier {
    @Environment(SleepTimerController.self) private var timer
    let active: Bool

    func body(content: Content) -> some View {
        content.alert(
            "Sleep timer ended",
            isPresented: Binding(
                get: { active && timer.expiredConfig != nil },
                set: { presented in
                    // Buttons act first; this only catches non-button dismissal.
                    if !presented, active, timer.expiredConfig != nil {
                        timer.dismissExpired()
                    }
                }
            )
        ) {
            Button("Postpone") { timer.postpone() }
            Button("Dismiss", role: .cancel) { timer.dismissExpired() }
        } message: {
            Text(describe(timer.expiredConfig))
        }
    }

    private func describe(_ config: SleepTimerConfig?) -> String {
        switch config?.mode {
        case .time(let minutes):
            "Postpone to listen for another \(minutes) minutes, or shake the device."
        case .chapters(let count) where count == 1:
            "Postpone to keep going to the end of the current chapter, or shake the device."
        case .chapters(let count):
            "Postpone to listen for \(count) more chapters, or shake the device."
        case nil:
            ""
        }
    }
}
