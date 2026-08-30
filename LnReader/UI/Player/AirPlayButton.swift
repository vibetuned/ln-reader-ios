import AVKit
import SwiftUI

/// Native route picker — the iOS counterpart of Android's Cast button. AVPlayer
/// streams to the chosen AirPlay device; everything driven through the engine
/// (mini-player, sleep timer, reader auto-follow, position saving) keeps
/// working, and the icon reflects the connection state on its own.
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.tintColor = UIColor(named: "AccentColor") ?? picker.tintColor
        picker.activeTintColor = .systemBlue
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
