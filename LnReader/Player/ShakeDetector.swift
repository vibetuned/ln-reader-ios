import CoreMotion
import Foundation

/// Accelerometer-driven shake detection, armed only while the expired sleep
/// timer is pending (mirrors Android's ShakeDetector). Uses device motion's
/// gravity-free user acceleration; magnitude above ~1.3 g with a 1.2 s
/// cooldown counts as a shake.
@MainActor
final class ShakeDetector {
    var onShake: (() -> Void)?

    private let motionManager = CMMotionManager()
    private var lastShake: Date = .distantPast

    func start() {
        guard motionManager.isDeviceMotionAvailable, !motionManager.isDeviceMotionActive else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let acceleration = motion?.userAcceleration else { return }
            let magnitude = sqrt(
                acceleration.x * acceleration.x
                    + acceleration.y * acceleration.y
                    + acceleration.z * acceleration.z)
            if magnitude > 1.3, Date().timeIntervalSince(self.lastShake) > 1.2 {
                self.lastShake = Date()
                self.onShake?()
            }
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
    }
}
