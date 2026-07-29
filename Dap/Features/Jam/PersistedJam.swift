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
    var melodyVariation: JamMelodyVariation
    var bassVariation: JamBassVariation
    var harmonyVariation: JamHarmonyVariation

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case name
        case createdAt
        case updatedAt
        case slotAssignments
        case vibePosition
        case drumKitSelection
        case effectSettings
        case melodyVariation
        case bassVariation
        case harmonyVariation
    }

    init(
        schemaVersion: Int,
        id: UUID,
        name: String,
        createdAt: Date,
        updatedAt: Date,
        slotAssignments: PersistedJamSlotAssignments,
        vibePosition: PersistedPoint,
        drumKitSelection: String,
        effectSettings: PersistedJamEffectSettings,
        melodyVariation: JamMelodyVariation,
        bassVariation: JamBassVariation = .initial,
        harmonyVariation: JamHarmonyVariation = .initial
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.slotAssignments = slotAssignments
        self.vibePosition = vibePosition
        self.drumKitSelection = drumKitSelection
        self.effectSettings = effectSettings
        self.melodyVariation = melodyVariation
        self.bassVariation = bassVariation
        self.harmonyVariation = harmonyVariation
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        slotAssignments = try container.decode(PersistedJamSlotAssignments.self, forKey: .slotAssignments)
        vibePosition = try container.decode(PersistedPoint.self, forKey: .vibePosition)
        drumKitSelection = try container.decode(String.self, forKey: .drumKitSelection)
        effectSettings = try container.decode(PersistedJamEffectSettings.self, forKey: .effectSettings)
        melodyVariation = try container.decodeIfPresent(JamMelodyVariation.self, forKey: .melodyVariation) ?? .initial
        bassVariation = try container.decodeIfPresent(JamBassVariation.self, forKey: .bassVariation) ?? .initial
        harmonyVariation = try container.decodeIfPresent(JamHarmonyVariation.self, forKey: .harmonyVariation) ?? .initial
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(slotAssignments, forKey: .slotAssignments)
        try container.encode(vibePosition, forKey: .vibePosition)
        try container.encode(drumKitSelection, forKey: .drumKitSelection)
        try container.encode(effectSettings, forKey: .effectSettings)
        try container.encode(melodyVariation, forKey: .melodyVariation)
        try container.encode(bassVariation, forKey: .bassVariation)
        try container.encode(harmonyVariation, forKey: .harmonyVariation)
    }
}

struct JamMelodyVariation: Codable, Hashable, Sendable {
    var generation: UInt64

    static let initial = JamMelodyVariation(generation: 0)
}

enum BassPatternIntent: String, Codable, Hashable, CaseIterable, Sendable {
    case steady
    case syncopated
    case driving
}

struct JamBassVariation: Codable, Hashable, Sendable {
    var generation: UInt64
    var intent: BassPatternIntent?

    static let initial = JamBassVariation(generation: 0, intent: nil)
}

enum HarmonyPatternIntent: String, Codable, Hashable, CaseIterable, Sendable {
    case sustained
    case rhythmic
    case open
}

struct JamHarmonyVariation: Codable, Hashable, Sendable {
    var generation: UInt64
    var intent: HarmonyPatternIntent?

    static let initial = JamHarmonyVariation(generation: 0, intent: nil)
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
