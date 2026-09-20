import SwiftUI

/// Sleep-timer setup, countdown and expiry — shared by the Settings tab and the player's timer
/// drawer (mirrors Android's TimerControls reuse).
///
/// The setup controls stay on screen while a timer runs, so an armed timer can be *changed*
/// rather than only cancelled: picking new values and tapping Update restarts it, which is what
/// Android's chips have always done. The running countdown and the expiry prompt sit above the
/// controls as their own sections instead of replacing them.
struct TimerControls: View {
    /// Section title for the setup controls. The Settings tab names the section; the player's
    /// sheet is already titled "Sleep Timer", so it passes nil.
    var header: String? = nil

    var body: some View {
        Form { TimerSections(header: header) }
    }
}

/// The timer's sections on their own, so a host that already provides a `Form` — the Settings
/// tab, which stacks them under the usage chart — can embed them without nesting one Form in
/// another (which renders as a scroll view inside a scroll view).
struct TimerSections: View {
    var header: String? = nil

    @Environment(SleepTimerController.self) private var timer
    @Environment(PlayerEngine.self) private var engine

    @State private var mode: PickedMode = .time
    @State private var minutes = 30
    @State private var chapterCount = 1
    @State private var fadeSeconds = 0
    /// Whether the pickers have been seeded from the running timer's own config, so "Update"
    /// starts from what is actually armed. Reset when the timer stops.
    @State private var adoptedRunningConfig = false

    private enum PickedMode: Hashable {
        case time, chapters
    }

    private var isRunning: Bool { timer.state != nil }

    var body: some View {
        Group {
            if let state = timer.state {
                runningSection(state)
            } else if timer.expiredConfig != nil {
                expiredSection
            }

            if engine.book == nil {
                Section {
                    Text("Open a book to use the sleep timer.")
                        .foregroundStyle(.secondary)
                }
            } else {
                modeSection
                fadeSection
                actionSection
            }
        }
        .onAppear(perform: adoptRunningConfig)
        .onChange(of: isRunning) { _, running in
            if running { adoptRunningConfig() } else { adoptedRunningConfig = false }
        }
    }

    // MARK: - Running / expired

    private func runningSection(_ state: SleepTimerState) -> some View {
        Section {
            HStack {
                Image(systemName: "moon.zzz.fill")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(formatSeconds(state.remainingSeconds))
                        .font(.title2.weight(.semibold).monospacedDigit())
                    Text(describe(state.config))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .destructive) { timer.cancel() }
                    .buttonStyle(.bordered)
            }
            if case .time = state.config.mode, !engine.isPlaying {
                Label("Paused — countdown frozen", systemImage: "pause.circle")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        } header: {
            Text("Running")
        }
    }

    private var expiredSection: some View {
        Section {
            Label("Timer expired — playback paused", systemImage: "zzz")
            Text("Shake the device to postpone.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                Button { timer.postpone() } label: {
                    Label("Postpone", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Button("Dismiss") { timer.dismissExpired() }
                    .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Setup

    private var modeSection: some View {
        Section {
            Picker("Mode", selection: $mode) {
                Text("Time").tag(PickedMode.time)
                Text("Chapters").tag(PickedMode.chapters)
            }
            .pickerStyle(.segmented)

            if mode == .time {
                Picker("Stop after", selection: $minutes) {
                    ForEach(SleepTimerController.timePresetsMinutes, id: \.self) { preset in
                        Text("\(preset) min").tag(preset)
                    }
                }
            } else {
                Picker("Stop after", selection: $chapterCount) {
                    ForEach(SleepTimerController.chapterPresets, id: \.self) { preset in
                        Text(preset == 1 ? "End of current chapter" : "+\(preset) chapters").tag(preset)
                    }
                }
                .disabled(engine.chapters.isEmpty)
            }
        } header: {
            if let header {
                Text(header)
            }
        } footer: {
            if mode == .chapters, engine.chapters.isEmpty {
                Text("This book has no chapter markers.")
            }
        }
    }

    private var fadeSection: some View {
        Section("Fade out") {
            Picker("Volume fade", selection: $fadeSeconds) {
                ForEach(SleepTimerController.fadePresetsSeconds, id: \.self) { preset in
                    Text(fadeLabel(preset)).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            Text(fadeSeconds <= 0
                 ? "Playback stops without fading."
                 : "Volume eases to silence as the timer ends.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var actionSection: some View {
        Section {
            Button {
                timer.start(SleepTimerConfig(
                    mode: mode == .time ? .time(minutes: minutes) : .chapters(count: chapterCount),
                    fadeOutSeconds: fadeSeconds
                ))
            } label: {
                // Starting while one runs replaces it (`start` cancels first), so the label says so.
                Label(isRunning ? "Update timer" : "Start timer", systemImage: "moon.zzz.fill")
                    .frame(maxWidth: .infinity)
            }
            .disabled(mode == .chapters && engine.chapters.isEmpty)
        } footer: {
            if isRunning {
                Text("Replaces the running timer with these settings.")
            }
        }
    }

    // MARK: - Helpers

    /// Seeds the pickers from a running timer so changing it starts from what is armed, not from
    /// whatever the defaults happen to be.
    private func adoptRunningConfig() {
        guard !adoptedRunningConfig, let config = timer.state?.config else { return }
        adoptedRunningConfig = true
        switch config.mode {
        case .time(let armedMinutes):
            mode = .time
            if SleepTimerController.timePresetsMinutes.contains(armedMinutes) { minutes = armedMinutes }
        case .chapters(let armedCount):
            mode = .chapters
            if SleepTimerController.chapterPresets.contains(armedCount) { chapterCount = armedCount }
        }
        fadeSeconds = config.fadeOutSeconds
    }

    private func fadeLabel(_ seconds: Int) -> String {
        switch seconds {
        case 0: "Off"
        case ..<60: "\(seconds) s"
        default: "\(seconds / 60) min"
        }
    }

    private func describe(_ config: SleepTimerConfig) -> String {
        let base = switch config.mode {
        case .time(let minutes): "Stopping after \(minutes) min of listening"
        case .chapters(let count): count == 1 ? "Stopping at the end of this chapter" : "Stopping after \(count) chapters"
        }
        return config.fadeOutSeconds > 0 ? base + " · \(fadeLabel(config.fadeOutSeconds)) fade" : base
    }

    private func formatSeconds(_ total: Int) -> String {
        total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}
