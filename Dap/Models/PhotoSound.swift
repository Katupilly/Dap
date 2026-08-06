import Foundation

// MARK: - Scale

enum MusicScale: String, Codable, Sendable, CaseIterable {
    case majorPentatonic, minorPentatonic, dorian, wholeTone

    var degrees: [Int] {
        switch self {
        case .majorPentatonic: [0, 2, 4, 7, 9]
        case .minorPentatonic: [0, 3, 5, 7, 10]
        case .dorian:          [0, 2, 3, 5, 7, 9, 10]
        case .wholeTone:       [0, 2, 4, 6, 8, 10]
        }
    }

    var displayName: String {
        switch self {
        case .majorPentatonic: "Major Pentatonic"
        case .minorPentatonic: "Minor Pentatonic"
        case .dorian:          "Dorian"
        case .wholeTone:       "Whole Tone"
        }
    }
}

// MARK: - Waveform

enum MusicWaveform: String, Codable, Sendable {
    case square, triangle
}

// MARK: - Pitch Class

enum PitchClass: Int, Codable, CaseIterable, Sendable {
    case c = 0, cSharp, d, dSharp, e, f, fSharp, g, gSharp, a, aSharp, b

    private static let modulus = 12

    init(normalizing value: Int) {
        let r = value % Self.modulus
        self = PitchClass(rawValue: r >= 0 ? r : r + Self.modulus) ?? .c
    }

    init(midiNote: Int) {
        self.init(normalizing: midiNote)
    }

    var symbol: String {
        switch self {
        case .c:      "C"
        case .cSharp: "C♯"
        case .d:      "D"
        case .dSharp: "D♯"
        case .e:      "E"
        case .f:      "F"
        case .fSharp: "F♯"
        case .g:      "G"
        case .gSharp: "G♯"
        case .a:      "A"
        case .aSharp: "A♯"
        case .b:      "B"
        }
    }
}

// MARK: - Sound Profile

struct SoundProfile: Codable, Sendable, Equatable {
    let gate: Double
    let octaveRange: Double
    let waveform: MusicWaveform
}

// MARK: - Music Harmony

struct MusicHarmony: Codable, Sendable, Equatable {
    let rootPitchClass: Int
    let scale: MusicScale
    let bpm: Int

    var rootName: String {
        PitchClass(rawValue: rootPitchClass)?.symbol ?? PitchClass.c.symbol
    }
}

enum MusicVoiceRole: String, Codable, Sendable {
    case bass
    case harmony
    case melody
}

// MARK: - Music Note

struct MusicNote: Codable, Sendable, Equatable, Identifiable {
    let step: Int
    let row: Int
    let midiNote: Int
    let velocity: Float
    var voiceRole: MusicVoiceRole? = nil
    var timingOffsetSteps: Float? = nil

    var id: String { "\(step)-\(row)" }
}

// MARK: - Music Sequence

struct MusicPercussionHit: Sendable, Equatable {
    let step: Int
    let velocity: Float

    init(step: Int, velocity: Float) {
        self.step = step
        self.velocity = min(max(velocity, 0), 1)
    }
}

enum MusicDrumKitSelection: String, CaseIterable, Sendable, Equatable {
    case auto
    case soft
    case club
    case breakbeat
    case metal
}

extension MusicDrumKitSelection {
    var displayName: String {
        switch self {
        case .auto:
            "Auto"
        case .soft:
            "Soft"
        case .club:
            "Club"
        case .breakbeat:
            "Break"
        case .metal:
            "Metal"
        }
    }
}

enum MusicDrumKit: Sendable, Equatable {
    case soft
    case club
    case breakbeat
    case metal
}

enum MusicRimStyle: Sendable, Equatable {
    case soft
    case main
    case hard
}

struct MusicRimHit: Sendable, Equatable {
    let step: Int
    let velocity: Float
    let style: MusicRimStyle

    init(step: Int, velocity: Float, style: MusicRimStyle) {
        self.step = step
        self.velocity = min(max(velocity, 0), 1)
        self.style = style
    }
}

struct MusicPercussionPattern: Equatable, Sendable {
    let kit: MusicDrumKit
    let kickHits: [MusicPercussionHit]
    let snareHits: [MusicPercussionHit]
    let closedHatHits: [MusicPercussionHit]
    let openHatHits: [MusicPercussionHit]
    let rimHits: [MusicRimHit]
}

struct MusicSequence: Codable, Sendable, Equatable {
    static let steps = 16
    static let rows  = 8

    let harmony: MusicHarmony
    let notes: [MusicNote]
    let soundProfile: SoundProfile

    /// Most-frequent pitch class in the sequence (tie broken by first occurrence).
    var dominantPitchClass: PitchClass {
        guard !notes.isEmpty else {
            return PitchClass(rawValue: harmony.rootPitchClass) ?? .c
        }
        let ordered = notes.sorted {
            $0.step != $1.step ? $0.step < $1.step : $0.row < $1.row
        }
        var counts: [PitchClass: Int] = [:]
        var firstAt: [PitchClass: Int] = [:]
        for (i, note) in ordered.enumerated() {
            let pc = PitchClass(midiNote: note.midiNote)
            counts[pc, default: 0] += 1
            if firstAt[pc] == nil { firstAt[pc] = i }
        }
        return counts.max { lhs, rhs in
            lhs.value != rhs.value
                ? lhs.value < rhs.value
                : (firstAt[lhs.key] ?? .max) > (firstAt[rhs.key] ?? .max)
        }?.key ?? (PitchClass(rawValue: harmony.rootPitchClass) ?? .c)
    }

    var displayLabel: String {
        "\(harmony.rootName) · \(harmony.scale.displayName)"
    }

    var stepDuration: TimeInterval {
        guard harmony.bpm > 0 else { return 0 }
        return 60.0 / Double(harmony.bpm) / 4.0
    }

    var nominalDuration: TimeInterval {
        stepDuration * Double(Self.steps)
    }

    /// Resolves to the final note when it is already a stable tonal anchor;
    /// otherwise returns a root-centered note for the completion accent.
    var completionAccentMIDINote: Int {
        let root = PitchClass(normalizing: harmony.rootPitchClass).rawValue
        let fifth = PitchClass(normalizing: root + 7).rawValue
        let resolutionPitchClasses = Set(
            [root] + (harmony.scale.degrees.contains(7) ? [fifth] : [])
        )
        let candidates = (64...79).filter { midiNote in
            let degree = (PitchClass(normalizing: midiNote).rawValue - root + 12) % 12
            return harmony.scale.degrees.contains(degree)
                && resolutionPitchClasses.contains(PitchClass(normalizing: midiNote).rawValue)
        }

        let finalNote = notes.max {
            $0.step != $1.step
                ? $0.step < $1.step
                : $0.row < $1.row
        }
        if let finalNote,
           resolutionPitchClasses.contains(PitchClass(normalizing: finalNote.midiNote).rawValue),
           let resolvedFinal = candidates.min(by: {
               abs($0 - finalNote.midiNote) < abs($1 - finalNote.midiNote)
           }) {
            return resolvedFinal
        }

        return candidates.first(where: {
            PitchClass(normalizing: $0).rawValue == root
        }) ?? 72
    }
}

// MARK: - PhotoSound

enum PhotoNameSource: String, Codable, Equatable, Sendable {
    case manual
    case generated
}

struct PhotoSound: Identifiable, Codable, Equatable, Sendable {
    static let legacyAlgorithmVersion = 2

    let id: UUID
    var name: String?
    var nameSource: PhotoNameSource?
    var description: String?
    let createdAt: Date
    let coverFilename: String
    let sequence: MusicSequence
    /// Version of the photo-to-music algorithm that created `sequence`.
    /// Missing values are legacy v2 records and are intentionally not regenerated.
    let algorithmVersion: Int
    /// Stable signature of normalized visual content. Legacy records have nil.
    let visualSignature: UInt64?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case nameSource
        case description
        case createdAt
        case coverFilename
        case sequence
        case algorithmVersion
        case visualSignature
    }

    init(
        id: UUID,
        name: String?,
        nameSource: PhotoNameSource?,
        description: String?,
        createdAt: Date,
        coverFilename: String,
        sequence: MusicSequence,
        algorithmVersion: Int = PhotoSound.legacyAlgorithmVersion,
        visualSignature: UInt64? = nil
    ) {
        self.id = id
        self.name = name
        self.nameSource = nameSource
        self.description = description
        self.createdAt = createdAt
        self.coverFilename = coverFilename
        self.sequence = sequence
        self.algorithmVersion = algorithmVersion
        self.visualSignature = visualSignature
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        nameSource = try container.decodeIfPresent(PhotoNameSource.self, forKey: .nameSource)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        coverFilename = try container.decode(String.self, forKey: .coverFilename)
        sequence = try container.decode(MusicSequence.self, forKey: .sequence)
        algorithmVersion = try container.decodeIfPresent(Int.self, forKey: .algorithmVersion)
            ?? Self.legacyAlgorithmVersion
        visualSignature = try container.decodeIfPresent(UInt64.self, forKey: .visualSignature)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(nameSource, forKey: .nameSource)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(coverFilename, forKey: .coverFilename)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(algorithmVersion, forKey: .algorithmVersion)
        try container.encodeIfPresent(visualSignature, forKey: .visualSignature)
    }

    var trimmedName: String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var displayTitle: String {
        if let trimmedName {
            return trimmedName
        }

        let noteLabel = sequence.displayLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return noteLabel.isEmpty ? "Untitled Photo" : noteLabel
    }
}

// MARK: - Pipeline result (not persisted)

struct ProcessedPhotoSound: Sendable {
    let sound: PhotoSound
    let coverData: Data
}
