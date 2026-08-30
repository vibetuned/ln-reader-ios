import GoogleCast
import SwiftUI

/// Google Cast button — shows the device picker and reflects connection state.
struct CastButton: UIViewRepresentable {
    func makeUIView(context: Context) -> GCKUICastButton {
        let button = GCKUICastButton(frame: CGRect(x: 0, y: 0, width: 28, height: 28))
        button.tintColor = UIColor.label
        return button
    }

    func updateUIView(_ uiView: GCKUICastButton, context: Context) {}
}
