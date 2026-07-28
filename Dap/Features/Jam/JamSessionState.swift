import CoreGraphics
import Observation

@MainActor
@Observable
final class JamSessionState {
    var slotAssignments = JamSlotAssignments()
    var drumKitSelection: MusicDrumKitSelection = .auto
    var effectSettings = JamEffectSettings.default
    var activeArrangement: JamArrangement?
    var isPlaying = false
    var vibePosition = CGPoint(x: 0.5, y: 0.5)
}
