import Foundation
import Observation

@MainActor
@Observable
final class JamVisualTransportState {
    var currentStep: Int?
    var activeSoundIDs: Set<UUID> = []

    func reset() {
        currentStep = nil
        activeSoundIDs = []
    }

    func update(step: Int, activeSoundIDs: Set<UUID>) {
        guard currentStep != step || self.activeSoundIDs != activeSoundIDs else { return }
        currentStep = step
        self.activeSoundIDs = activeSoundIDs
    }
}
