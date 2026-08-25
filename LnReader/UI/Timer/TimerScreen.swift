import SwiftUI

struct TimerScreen: View {
    @Environment(SleepTimerController.self) private var timer
    @Environment(PlayerEngine.self) private var engine

    @State private var mode: PickedMode = .time
    @State private var minutes = 30
    @State private var chapterCount = 1
    @State private var fadeSeconds = 0

    private enum PickedMode: Hashable {
        case time, chapters
    }

    var body: some View {
        NavigationStack {
            Group {
                if let state = timer.state {
                    runningView(state)
                } else if timer.expiredConfig != nil {
                    expiredView
                } else {
                    setupForm
                }
            }
            .navigationTitle("Sleep Timer")
        }
    }

    // MARK: - Setup

    private var setupForm: some View {
        Form {
            Section("Mode") {
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
            }

            Section("Fade out") {
                Picker("Volume fade", selection: $fadeSeconds) {
                    ForEach(SleepTimerController.fadePresetsSeconds, id: \.self) { preset in
                        Text(fadeLabel(preset)).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Button {
                    timer.start(SleepTimerConfig(
                        mode: mode == .time ? .time(minutes: minutes) : .chapters(count: chapterCount),
                        fadeOutSeconds: fadeSeconds
                    ))
                } label: {
                    Label("Start timer", systemImage: "moon.zzz.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(engine.book == nil || (mode == .chapters && engine.chapters.isEmpty))
            } footer: {
                if engine.book == nil {
                    Text("Open a book first — the timer pauses whatever is playing.")
                }
            }
        }
    }

    // MARK: - Running

    private func runningView(_ state: SleepTimerState) -> some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
            Text(formatSeconds(state.remainingSeconds))
                .font(.system(size: 56, weight: .light).monospacedDigit())
            Text(describe(state.config))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if case .time = state.config.mode, !engine.isPlaying {
                Label("Paused — countdown frozen", systemImage: "pause.circle")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            Button(role: .destructive) {
                timer.cancel()
            } label: {
                Label("Cancel timer", systemImage: "xmark.circle")
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var expiredView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "zzz")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Timer expired — playback paused")
                .font(.headline)
            Text("Shake the device to postpone.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Button {
                    timer.postpone()
                } label: {
                    Label("Postpone", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    timer.dismissExpired()
                } label: {
                    Text("Dismiss")
                }
                .buttonStyle(.bordered)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Formatting

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
