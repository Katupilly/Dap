import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class JamSessionState {
    var activeJamID: UUID?
    var jamName = "Untitled Jam"
    var jamCreatedAt: Date?
    var slotAssignments = JamSlotAssignments()
    var bassVariation = JamBassVariation.initial
    var harmonyVariation = JamHarmonyVariation.initial
    var melodyVariation = JamMelodyVariation.initial
    var drumKitSelection: MusicDrumKitSelection = .auto
    var effectSettings = JamEffectSettings.default
    var activeArrangement: JamArrangement?
    var isPlaying = false
    var vibePosition = CGPoint(x: 0.5, y: 0.5)
}
