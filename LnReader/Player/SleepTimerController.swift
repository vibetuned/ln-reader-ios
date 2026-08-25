import Foundation
import Observation
import UserNotifications
import LnReaderCore

enum SleepTimerMode: Equatable {
    /// Counts elapsed *play* time — pausing freezes the countdown.
    case time(minutes: Int)
    /// Stops at the end of the Nth chapter from the arming position (1 = current).
    case chapters(count: Int)
}

struct SleepTimerConfig: Equatable {
    var mode: SleepTimerMode
    /// 0 = no fade. Volume ramps down over the last `fadeOutSeconds`.
    var fadeOutSeconds: Int
}

struct SleepTimerState: Equatable {
    var config: SleepTimerConfig
    /// Time mode: seconds of play time left. Chapter mode: an estimate to the target.
    var remainingSeconds: Int
    /// Chapter mode only: the book-absolute position where playback stops.
    var targetMs: Int64?
}

/// Drives playback through the same PlayerEngine the UI uses — the iOS analog
/// of Android's SleepTimerController. When the timer fires it pauses, restores
/// volume, posts a notification with Postpone / Dismiss, and arms
/// shake-to-postpone.
@MainActor
@Observable
final class SleepTimerController {
    static let timePresetsMinutes = [5, 15, 30, 45, 60, 90]
    static let chapterPresets = [1, 2, 3, 5]
    static let fadePresetsSeconds = [0, 10, 30, 60, 300]

    private(set) var state: SleepTimerState?
    private(set) var expiredConfig: SleepTimerConfig?

    private let engine: PlayerEngine
    private let notifier = SleepTimerNotifier()
    private let shakeDetector = ShakeDetector()
    private var tickTask: Task<Void, Never>?
    /// Time mode: accumulated whole seconds of play time.
    private var playedSeconds = 0

    init(engine: PlayerEngine) {
        self.engine = engine
        notifier.onPostpone = { [weak self] in self?.postpone() }
        notifier.onDismiss = { [weak self] in self?.dismissExpired() }
        shakeDetector.onShake = { [weak self] in self?.postpone() }
    }

    func start(_ config: SleepTimerConfig) {
        cancel()
        Task { await notifier.requestPermission() }
        playedSeconds = 0
        state = SleepTimerState(
            config: config,
            remainingSeconds: initialRemaining(config),
            targetMs: chapterTarget(config)
        )
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.tick()
            }
        }
    }

    func cancel() {
        tickTask?.cancel()
        tickTask = nil
        state = nil
        engine.setVolume(1)
    }

    /// Restarts the same timer and resumes playback (notification action / shake).
    func postpone() {
        guard let config = expiredConfig else { return }
        clearExpired()
        engine.play()
        start(config)
    }

    func dismissExpired() {
        clearExpired()
    }

    private func clearExpired() {
        expiredConfig = nil
        shakeDetector.stop()
        notifier.clearExpired()
    }

    // MARK: - Ticking

    private func tick() {
        guard var state else { return }
        switch state.config.mode {
        case .time(let minutes):
            guard engine.isPlaying else { return } // pause freezes the countdown
            // Two ticks per second; count one second every second tick.
            halfTicks += 1
            if halfTicks % 2 == 0 { playedSeconds += 1 }
            let total = minutes * 60
            let remaining = max(0, total - playedSeconds)
            state.remainingSeconds = remaining
            self.state = state
            applyFade(remainingSeconds: Double(remaining), config: state.config)
            if remaining <= 0 { fire() }

        case .chapters:
            guard let targetMs = state.targetMs else { return }
            let remainingMs = targetMs - engine.positionMs
            state.remainingSeconds = Int(max(0, remainingMs) / 1000)
            self.state = state
            if engine.isPlaying {
                applyFade(remainingSeconds: Double(remainingMs) / 1000 / engine.rate, config: state.config)
            }
            if engine.isPlaying, remainingMs <= 0 { fire() }
        }
    }

    private var halfTicks = 0

    private func applyFade(remainingSeconds: Double, config: SleepTimerConfig) {
        let fade = Double(config.fadeOutSeconds)
        guard fade > 0 else { return }
        guard remainingSeconds < fade else {
            engine.setVolume(1)
            return
        }
        engine.setVolume(Float(max(0, remainingSeconds / fade)))
    }

    private func fire() {
        guard let config = state?.config else { return }
        tickTask?.cancel()
        tickTask = nil
        state = nil
        engine.pause()
        engine.setVolume(1)
        expiredConfig = config
        notifier.postExpired()
        shakeDetector.start()
    }

    // MARK: - Config helpers

    private func initialRemaining(_ config: SleepTimerConfig) -> Int {
        switch config.mode {
        case .time(let minutes): minutes * 60
        case .chapters: Int(max(0, (chapterTarget(config) ?? 0) - engine.positionMs) / 1000)
        }
    }

    private func chapterTarget(_ config: SleepTimerConfig) -> Int64? {
        guard case .chapters(let count) = config.mode,
              let current = engine.locator.window(atMs: engine.positionMs) else { return nil }
        let lastIndex = min(current.index + count - 1, engine.chapters.count - 1)
        return engine.locator.window(atIndex: lastIndex)?.endMs
    }
}
