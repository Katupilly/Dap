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

// MARK: - Music Note

struct MusicNote: Codable, Sendable, Equatable, Identifiable {
    let step: Int
    let row: Int
    let midiNote: Int
    let velocity: Float

    var id: String { "\(step)-\(row)" }
}

// MARK: - Music Sequence

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
}

// MARK: - PhotoSound

struct PhotoSound: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String?
    var description: String?
    let createdAt: Date
    let coverFilename: String
    let sequence: MusicSequence
}

// MARK: - Pipeline result (not persisted)

struct ProcessedPhotoSound: Sendable {
    let sound: PhotoSound
    let coverData: Data
}
