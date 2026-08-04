import CoreMotion
import Foundation
import Observation

@MainActor
@Observable
final class PhotoPaperMotionProvider {
    private(set) var offset: CGSize = .zero

    private let motionManager = CMMotionManager()
    private var isRunning = false
    private var smoothedRoll = 0.0
    private var smoothedPitch = 0.0

    func start() {
        guard !isRunning, motionManager.isDeviceMotionAvailable else { return }

        let metrics = PaperEffectMetrics.active
        motionManager.deviceMotionUpdateInterval = metrics.updateInterval
        motionManager.startDeviceMotionUpdates(
            using: .xArbitraryZVertical,
            to: .main
        ) { [weak self] motion, _ in
            guard let motion else { return }
            self?.update(with: motion)
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }

        motionManager.stopDeviceMotionUpdates()
        isRunning = false
        smoothedRoll = 0
        smoothedPitch = 0
        offset = .zero
    }

    private func update(with motion: CMDeviceMotion) {
        let metrics = PaperEffectMetrics.active
        let normalizedRoll = normalized(motion.attitude.roll)
        let normalizedPitch = normalized(motion.attitude.pitch)

        smoothedRoll += (normalizedRoll - smoothedRoll) * metrics.motionSmoothing
        smoothedPitch += (normalizedPitch - smoothedPitch) * metrics.motionSmoothing

        let nextOffset = CGSize(
            width: smoothedRoll,
            height: -smoothedPitch
        )

        guard abs(nextOffset.width - offset.width) > metrics.motionPublishThreshold
                || abs(nextOffset.height - offset.height) > metrics.motionPublishThreshold else {
            return
        }
        offset = nextOffset
    }

    private func normalized(_ angle: Double) -> Double {
        let limit = PaperEffectMetrics.active.motionAngleLimit
        let limited = max(-1, min(1, angle / limit))
        let metrics = PaperEffectMetrics.active
        let magnitude = abs(limited)

        guard magnitude > metrics.motionDeadZone else {
            return 0
        }

        let remapped = (magnitude - metrics.motionDeadZone)
            / (1 - metrics.motionDeadZone)
        let curved = pow(remapped, metrics.motionResponseExponent)
        return limited < 0 ? -curved : curved
    }
}
