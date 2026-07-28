import CoreGraphics
import Foundation

struct PersistedJam: Codable, Identifiable, Hashable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    var name: String
    let createdAt: Date
    var updatedAt: Date
    var slotAssignments: PersistedJamSlotAssignments
    var vibePosition: PersistedPoint
    var drumKitSelection: String
    var effectSettings: PersistedJamEffectSettings
}

struct PersistedJamSlotAssignments: Codable, Hashable {
    var bass: UUID?
    var harmony: UUID?
    var melody: UUID?
    var reserve: [UUID]
}

struct PersistedPoint: Codable, Hashable {
    var x: Double
    var y: Double
}

struct PersistedJamEffectSettings: Codable, Hashable {
    var reverbEnabled: Bool
    var reverbMix: Float
    var delayEnabled: Bool
    var delayMix: Float
    var lfoEnabled: Bool
    var lfoAmount: Float
}

extension PersistedJam {
    static let defaultName = "Untitled Jam"

    static func normalizedName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? defaultName : trimmed
        return String(base.prefix(80))
    }
}

extension PersistedJamSlotAssignments {
    var activePhotoIDs: [UUID] {
        [bass, harmony, melody].compactMap { $0 }
    }

    var allPhotoIDs: [UUID] {
        activePhotoIDs + reserve
    }

    init(_ assignments: JamSlotAssignments) {
        self.init(
            bass: assignments.bass,
            harmony: assignments.harmony,
            melody: assignments.melody,
            reserve: assignments.reserve
        )
    }

    var jamSlotAssignments: JamSlotAssignments {
        JamSlotAssignments(
            bass: bass,
            harmony: harmony,
            melody: melody,
            reserve: reserve
        )
    }
}

extension PersistedPoint {
    init(_ point: CGPoint) {
        self.init(
            x: min(max(Double(point.x), 0), 1),
            y: min(max(Double(point.y), 0), 1)
        )
    }

    var cgPoint: CGPoint {
        CGPoint(
            x: min(max(x, 0), 1),
            y: min(max(y, 0), 1)
        )
    }
}

extension PersistedJamEffectSettings {
    init(_ settings: JamEffectSettings) {
        self.init(
            reverbEnabled: settings.reverbEnabled,
            reverbMix: Self.clampedUnit(settings.reverbMix),
            delayEnabled: settings.delayEnabled,
            delayMix: Self.clampedUnit(settings.delayMix),
            lfoEnabled: settings.lfoEnabled,
            lfoAmount: Self.clampedUnit(settings.lfoAmount)
        )
    }

    var jamEffectSettings: JamEffectSettings {
        JamEffectSettings(
            reverbEnabled: reverbEnabled,
            reverbMix: Self.clampedUnit(reverbMix),
            delayEnabled: delayEnabled,
            delayMix: Self.clampedUnit(delayMix),
            lfoEnabled: lfoEnabled,
            lfoAmount: Self.clampedUnit(lfoAmount)
        )
    }

    private static func clampedUnit(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }
}

extension MusicDrumKitSelection {
    init(persistedValue: String) {
        self = MusicDrumKitSelection(rawValue: persistedValue) ?? .auto
    }

    var persistedValue: String {
        rawValue
    }
}
