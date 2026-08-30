import SwiftUI

/// Custom scrubber that owns its gesture, unlike SwiftUI's Slider whose
/// editing callbacks are unreliable (accessibility adjustments deliver value
/// changes with no release). Semantics are explicit and Android-like:
/// `onScrubChanged` fires with every preview position while the finger is
/// down, `onScrubEnded` fires exactly once, on release, with the final value.
/// Tap-to-seek comes free (a zero-distance drag is a tap).
struct ChapterScrubber: View {
    /// Current position, chapter-local, 0...duration.
    let value: Double
    /// Chapter duration (upper bound of `value`).
    let duration: Double
    let onScrubChanged: (Double) -> Void
    let onScrubEnded: (Double) -> Void

    private let thumbRadius: CGFloat = 10
    private let trackHeight: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            let usable = max(1, proxy.size.width - thumbRadius * 2)
            let fraction = duration > 0 ? min(max(0, value / duration), 1) : 0
            let thumbCenterX = thumbRadius + usable * CGFloat(fraction)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(uiColor: .systemFill))
                    .frame(height: trackHeight)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: thumbCenterX, height: trackHeight)
                Circle()
                    .fill(.white)
                    .frame(width: thumbRadius * 2, height: thumbRadius * 2)
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                    .position(x: thumbCenterX, y: proxy.size.height / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        onScrubChanged(position(for: gesture.location.x, usable: usable))
                    }
                    .onEnded { gesture in
                        onScrubEnded(position(for: gesture.location.x, usable: usable))
                    }
            )
        }
        .frame(height: max(28, thumbRadius * 2 + 8))
        .accessibilityElement()
        .accessibilityLabel("Chapter position")
        .accessibilityValue("\(Int(duration > 0 ? value / duration * 100 : 0)) percent")
        .accessibilityAdjustableAction { direction in
            // VoiceOver adjustments commit directly — 5% steps.
            let step = max(1, duration * 0.05)
            switch direction {
            case .increment: onScrubEnded(min(duration, value + step))
            case .decrement: onScrubEnded(max(0, value - step))
            @unknown default: break
            }
        }
    }

    private func position(for x: CGFloat, usable: CGFloat) -> Double {
        let fraction = min(max(0, (x - thumbRadius) / usable), 1)
        return Double(fraction) * duration
    }
}
