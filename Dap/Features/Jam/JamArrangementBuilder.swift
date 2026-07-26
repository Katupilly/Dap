import CoreGraphics
import Foundation

struct JamArrangementBuilder {
    let bpm: Int

    func assignRoles(to sounds: [PhotoSound]) -> [AssignedSound] {
        let orderedSounds = sounds.sorted { lhs, rhs in
            let lhsRegister = averageRegister(for: lhs.sequence)
            let rhsRegister = averageRegister(for: rhs.sequence)

            if lhsRegister != rhsRegister { return lhsRegister < rhsRegister }
            if lhs.sequence.notes.count != rhs.sequence.notes.count {
                return lhs.sequence.notes.count < rhs.sequence.notes.count
            }

            return lhs.id.uuidString < rhs.id.uuidString
        }

        switch orderedSounds.count {
        case 3:
            return [
                AssignedSound(sound: orderedSounds[0], role: .bass),
                AssignedSound(sound: orderedSounds[1], role: .harmony),
                AssignedSound(sound: orderedSounds[2], role: .melody),
            ]
        case 2:
            return [
                AssignedSound(sound: orderedSounds[0], role: .bass),
                AssignedSound(sound: orderedSounds[1], role: .melody),
            ]
        case 1:
            guard let sound = orderedSounds.first else { return [] }
            return [AssignedSound(sound: sound, role: .melody)]
        default:
            return []
        }
    }

    func build(
        sounds: [PhotoSound],
        vibePosition: CGPoint
    ) -> JamArrangement? {
        let assignedSounds = assignRoles(to: sounds)
        guard let melodySound = assignedSounds.first(where: { $0.role == .melody }) else {
            return nil
        }

        let preset = interpolatedPreset(for: vibePosition)
        let registerShift = Int(preset.registerBias.rounded())
        let harmony = globalHarmony(for: assignedSounds.map { $0.sound })
        let melodyProfile = melodySound.sound.sequence.soundProfile

        var activeStepsBySoundID: [UUID: Set<Int>] = [:]

        let notes = assignedSounds.flatMap { assignedSound in
            let notes = buildNotes(
                for: assignedSound,
                harmony: harmony,
                registerShift: registerShift,
                vibePosition: vibePosition
            )

            if !notes.isEmpty {
                activeStepsBySoundID[assignedSound.sound.id] = Set(notes.map(\.step))
            }

            return notes
        }

        .sorted {
            if $0.step != $1.step { return $0.step < $1.step }
            if $0.row != $1.row { return $0.row < $1.row }
            return $0.midiNote < $1.midiNote
        }

        guard !notes.isEmpty else { return nil }

        let sequence = MusicSequence(
            harmony: MusicHarmony(
                rootPitchClass: harmony.rootPitchClass,
                scale: harmony.scale,
                bpm: bpm
            ),
            notes: notes,
            soundProfile: SoundProfile(
                gate: preset.gate,
                octaveRange: melodyProfile.octaveRange,
                waveform: melodyProfile.waveform
            )
        )
        let style = grooveStyle(for: vibePosition)
        let percussion = percussionPattern(for: style)

        return JamArrangement(
            sequence: sequence,
            activeStepsBySoundID: activeStepsBySoundID,
            percussion: percussion
        )
    }

    private func grooveStyle(for vibePosition: CGPoint) -> JamGrooveStyle {
        let x = min(max(vibePosition.x, 0), 1)
        let y = min(max(vibePosition.y, 0), 1)

        if x <= 0.5 {
            return y < 0.5 ? .airy : .deep
        } else {
            return y < 0.5 ? .bright : .intense
        }
    }

    private func percussionPattern(for style: JamGrooveStyle) -> MusicPercussionPattern {
        switch style {
        case .airy:
            return MusicPercussionPattern(
                kickSteps: [0, 8],
                snareSteps: [4, 12],
                closedHatSteps: [2, 6, 10, 14]
            )
        case .bright:
            return MusicPercussionPattern(
                kickSteps: [0, 4, 8, 12],
                snareSteps: [4, 12],
                closedHatSteps: [0, 2, 4, 6, 8, 10, 12, 14]
            )
        case .deep:
            return MusicPercussionPattern(
                kickSteps: [0, 8, 12],
                snareSteps: [4, 12],
                closedHatSteps: [0, 4, 8, 12]
            )
        case .intense:
            return MusicPercussionPattern(
                kickSteps: [0, 2, 6, 8, 10, 14],
                snareSteps: [4, 12, 14],
                closedHatSteps: [
                    0, 1, 2, 3,
                    4, 5, 6, 7,
                    8, 9, 10, 11,
                    12, 13, 14, 15
                ]
            )
        }
    }

    private func buildNotes(
        for assignedSound: AssignedSound,
        harmony: GlobalHarmony,
        registerShift: Int,
        vibePosition: CGPoint
    ) -> [MusicNote] {
        let sourceNotes = sortedNotes(from: assignedSound.sound.sequence.notes)
        guard !sourceNotes.isEmpty else { return [] }

        switch assignedSound.role {
        case .bass:
            return buildBassNotes(
                from: sourceNotes,
                harmony: harmony,
                registerShift: registerShift,
                vibePosition: vibePosition
            )
        case .harmony:
            return buildHarmonyNotes(
                from: sourceNotes,
                harmony: harmony,
                registerShift: registerShift,
                vibePosition: vibePosition
            )
        case .melody:
            return buildMelodyNotes(
                from: sourceNotes,
                harmony: harmony,
                registerShift: registerShift,
                vibePosition: vibePosition
            )
        }
    }

    private func buildBassNotes(
        from sourceNotes: [MusicNote],
        harmony: GlobalHarmony,
        registerShift: Int,
        vibePosition: CGPoint
    ) -> [MusicNote] {
        let stepNotes = representativeNotesByStep(from: sourceNotes)
        let sampledNotes = sampledNotes(
            from: stepNotes,
            density: effectiveDensity(for: .bass, sourceCount: stepNotes.count, vibePosition: vibePosition)
        )

        let stablePitchClasses = [
            harmony.rootPitchClass,
            (harmony.rootPitchClass + 7) % 12
        ]

        var previousMIDINote: Int?

        return sampledNotes.map { note in
            let originalPitchClass = PitchClass(normalizing: note.midiNote).rawValue
            let chosenPitchClass = preferredBassPitchClass(
                for: originalPitchClass,
                rootPitchClass: harmony.rootPitchClass,
                fifthPitchClass: stablePitchClasses[1]
            )
            let targetMIDINote = bassMIDINote(
                pitchClass: chosenPitchClass,
                previousMIDINote: previousMIDINote,
                registerShift: registerShift
            )
            previousMIDINote = targetMIDINote

            return MusicNote(
                step: note.step,
                row: row(for: targetMIDINote),
                midiNote: targetMIDINote,
                velocity: transformedVelocity(
                    note.velocity,
                    multiplier: 0.70,
                    role: .bass
                )
            )
        }
    }

    private func buildHarmonyNotes(
        from sourceNotes: [MusicNote],
        harmony: GlobalHarmony,
        registerShift: Int,
        vibePosition: CGPoint
    ) -> [MusicNote] {
        let stepNotes = representativeNotesByStep(from: sourceNotes)
        let sampledNotes = sampledNotes(
            from: stepNotes,
            density: effectiveDensity(for: .harmony, sourceCount: stepNotes.count, vibePosition: vibePosition)
        )

        var previousMIDINote: Int?

        return sampledNotes.map { note in
            let scaleMIDINote = nearestScaleMIDINote(
                to: note.midiNote,
                rootPitchClass: harmony.rootPitchClass,
                scale: harmony.scale,
                range: 48...108
            )
            let targetMIDINote = centeredMIDINote(
                from: scaleMIDINote,
                preferredCenter: 66 + registerShift,
                previousMIDINote: previousMIDINote,
                range: 54...90
            )
            previousMIDINote = targetMIDINote

            return MusicNote(
                step: note.step,
                row: row(for: targetMIDINote),
                midiNote: targetMIDINote,
                velocity: transformedVelocity(
                    note.velocity,
                    multiplier: 0.55,
                    role: .harmony
                )
            )
        }
    }

    private func buildMelodyNotes(
        from sourceNotes: [MusicNote],
        harmony: GlobalHarmony,
        registerShift: Int,
        vibePosition: CGPoint
    ) -> [MusicNote] {
        let sampledNotes = sampledNotes(
            from: sourceNotes,
            density: effectiveDensity(for: .melody, sourceCount: sourceNotes.count, vibePosition: vibePosition)
        )

        return sampledNotes.map { note in
            let shiftedTarget = min(108, max(48, note.midiNote + registerShift))
            let scaleMIDINote = nearestScaleMIDINote(
                to: shiftedTarget,
                rootPitchClass: harmony.rootPitchClass,
                scale: harmony.scale,
                range: 48...108
            )
            let targetMIDINote = min(108, max(48, scaleMIDINote))

            return MusicNote(
                step: note.step,
                row: row(for: targetMIDINote),
                midiNote: targetMIDINote,
                velocity: transformedVelocity(
                    note.velocity,
                    multiplier: 0.75,
                    role: .melody
                )
            )
        }
    }

    private func transformedVelocity(
        _ sourceVelocity: Float,
        multiplier: Float,
        role: JamRole
    ) -> Float {
        switch role {
        case .bass:
            return min(1.0, max(0.0, sourceVelocity * multiplier))
        case .harmony:
            return min(1.0, max(0.0, sourceVelocity * multiplier))
        case .melody:
            return min(1.0, max(0.0, sourceVelocity * multiplier))
        }
    }

    private func effectiveDensity(for role: JamRole, sourceCount: Int, vibePosition: CGPoint) -> Double {
        guard sourceCount > 0 else { return 0 }

        let globalDensity = interpolatedPreset(for: vibePosition).density
        let roleMultiplier: Double
        switch role {
        case .bass:
            roleMultiplier = 0.60
        case .harmony:
            roleMultiplier = 0.80
        case .melody:
            roleMultiplier = 1.00
        }

        let lowerBound = 1.0 / Double(sourceCount)
        return min(1.0, max(lowerBound, globalDensity * roleMultiplier))
    }

    private func sortedNotes(from notes: [MusicNote]) -> [MusicNote] {
        notes.sorted {
            if $0.step != $1.step { return $0.step < $1.step }
            if $0.row != $1.row { return $0.row < $1.row }
            return $0.midiNote < $1.midiNote
        }
    }

    private func representativeNotesByStep(from notes: [MusicNote]) -> [MusicNote] {
        let notesByStep = Dictionary(grouping: notes, by: \.step)

        return notesByStep.keys
            .sorted()
            .compactMap { step in
                notesByStep[step]?
                    .sorted {
                        if $0.row != $1.row { return $0.row < $1.row }
                        return $0.midiNote < $1.midiNote
                    }
                    .first
            }
    }

    private func sampledNotes(from notes: [MusicNote], density: Double) -> [MusicNote] {
        guard !notes.isEmpty else { return [] }

        let targetCount = max(
            1,
            min(
                16,
                Int((Double(notes.count) * density).rounded())
            )
        )

        if targetCount >= notes.count {
            return notes
        }

        let sampled = (0..<targetCount).map { index in
            let sourceIndex = min(
                notes.count - 1,
                Int(
                    floor(
                        Double(index) *
                        Double(notes.count) /
                        Double(targetCount)
                    )
                )
            )

            return notes[sourceIndex]
        }

        return sampled.isEmpty ? [notes[0]] : sampled
    }

    private func averageRegister(for sequence: MusicSequence) -> Double {
        guard !sequence.notes.isEmpty else { return 48 }
        let total = sequence.notes.reduce(0) { $0 + $1.midiNote }
        return Double(total) / Double(sequence.notes.count)
    }

    private func globalHarmony(for sounds: [PhotoSound]) -> GlobalHarmony {
        let allNotes = sounds.flatMap { $0.sequence.notes }
        guard !allNotes.isEmpty else {
            let fallback = sounds.first?.sequence.harmony.rootPitchClass ?? 0
            return GlobalHarmony(rootPitchClass: fallback, scale: .majorPentatonic)
        }

        var histogram = Array(repeating: 0, count: 12)
        for note in allNotes {
            histogram[PitchClass(normalizing: note.midiNote).rawValue] += 1
        }

        var bestCandidate = GlobalHarmony(rootPitchClass: 0, scale: .majorPentatonic)
        var bestCoverage = Int.min

        for scale in [MusicScale.majorPentatonic, .minorPentatonic] {
            for root in 0..<12 {
                let coverage = scale.degrees
                    .map { (root + $0) % 12 }
                    .reduce(0) { $0 + histogram[$1] }

                if coverage > bestCoverage {
                    bestCoverage = coverage
                    bestCandidate = GlobalHarmony(rootPitchClass: root, scale: scale)
                    continue
                }

                guard coverage == bestCoverage else { continue }

                if bestCandidate.scale.rawValue == MusicScale.minorPentatonic.rawValue &&
                    scale.rawValue == MusicScale.majorPentatonic.rawValue {
                    bestCandidate = GlobalHarmony(rootPitchClass: root, scale: scale)
                } else if bestCandidate.scale.rawValue == scale.rawValue && root < bestCandidate.rootPitchClass {
                    bestCandidate = GlobalHarmony(rootPitchClass: root, scale: scale)
                }
            }
        }

        return bestCandidate
    }

    private func nearestScaleMIDINote(
        to midiNote: Int,
        rootPitchClass: Int,
        scale: MusicScale,
        range: ClosedRange<Int>
    ) -> Int {
        range
            .filter { candidate in
                let pitchClass = PitchClass(normalizing: candidate).rawValue
                return scale.degrees.contains((pitchClass - rootPitchClass + 12) % 12)
            }
            .min { lhs, rhs in
                let lhsDistance = abs(lhs - midiNote)
                let rhsDistance = abs(rhs - midiNote)

                if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
                return lhs < rhs
            } ?? min(range.upperBound, max(range.lowerBound, midiNote))
    }

    private func preferredBassPitchClass(
        for originalPitchClass: Int,
        rootPitchClass: Int,
        fifthPitchClass: Int
    ) -> Int {
        let rootDistance = pitchClassDistance(originalPitchClass, rootPitchClass)
        let fifthDistance = pitchClassDistance(originalPitchClass, fifthPitchClass)

        if rootDistance < fifthDistance { return rootPitchClass }
        if fifthDistance < rootDistance { return fifthPitchClass }
        return rootPitchClass
    }

    private func pitchClassDistance(_ lhs: Int, _ rhs: Int) -> Int {
        let direct = abs(lhs - rhs)
        return min(direct, 12 - direct)
    }

    private func bassMIDINote(
        pitchClass: Int,
        previousMIDINote: Int?,
        registerShift: Int
    ) -> Int {
        let range = 48...72
        let preferredCenter = min(range.upperBound, max(range.lowerBound, 52 + registerShift))
        let candidates = range.filter { PitchClass(normalizing: $0).rawValue == pitchClass }

        return candidates.min { lhs, rhs in
            let lhsReference = previousMIDINote ?? preferredCenter
            let rhsReference = previousMIDINote ?? preferredCenter
            let lhsDistance = abs(lhs - lhsReference)
            let rhsDistance = abs(rhs - rhsReference)

            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }

            let lhsCenterDistance = abs(lhs - preferredCenter)
            let rhsCenterDistance = abs(rhs - preferredCenter)
            if lhsCenterDistance != rhsCenterDistance { return lhsCenterDistance < rhsCenterDistance }

            return lhs < rhs
        } ?? preferredCenter
    }

    private func centeredMIDINote(
        from midiNote: Int,
        preferredCenter: Int,
        previousMIDINote: Int?,
        range: ClosedRange<Int>
    ) -> Int {
        let pitchClass = PitchClass(normalizing: midiNote).rawValue
        let clampedCenter = min(range.upperBound, max(range.lowerBound, preferredCenter))
        let candidates = range.filter { PitchClass(normalizing: $0).rawValue == pitchClass }

        return candidates.min { lhs, rhs in
            let reference = previousMIDINote ?? clampedCenter
            let lhsDistance = abs(lhs - reference)
            let rhsDistance = abs(rhs - reference)

            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }

            let lhsCenterDistance = abs(lhs - clampedCenter)
            let rhsCenterDistance = abs(rhs - clampedCenter)
            if lhsCenterDistance != rhsCenterDistance { return lhsCenterDistance < rhsCenterDistance }

            return lhs < rhs
        } ?? min(range.upperBound, max(range.lowerBound, midiNote))
    }

    private func interpolatedPreset(for position: CGPoint) -> VibePreset {
        let x = min(max(position.x, 0), 1)
        let y = min(max(position.y, 0), 1)

        let wAiry = (1 - x) * (1 - y)
        let wBright = x * (1 - y)
        let wDeep = (1 - x) * y
        let wIntense = x * y

        return VibePreset(
            density: airyPreset.density * wAiry
                + brightPreset.density * wBright
                + deepPreset.density * wDeep
                + intensePreset.density * wIntense,
            registerBias: airyPreset.registerBias * wAiry
                + brightPreset.registerBias * wBright
                + deepPreset.registerBias * wDeep
                + intensePreset.registerBias * wIntense,
            gate: airyPreset.gate * wAiry
                + brightPreset.gate * wBright
                + deepPreset.gate * wDeep
                + intensePreset.gate * wIntense
        )
    }

    private func row(for midiNote: Int) -> Int {
        let normalized = Double(108 - min(108, max(48, midiNote))) / 60.0
        return min(7, max(0, Int((normalized * 7).rounded())))
    }
}

enum JamRole: String, Equatable {
    case bass
    case harmony
    case melody

    var displayName: String {
        rawValue.capitalized
    }
}

struct AssignedSound: Identifiable, Equatable {
    let sound: PhotoSound
    let role: JamRole

    var id: UUID { sound.id }
}

struct JamArrangement {
    let sequence: MusicSequence
    let activeStepsBySoundID: [UUID: Set<Int>]
    let percussion: MusicPercussionPattern
}

private enum JamGrooveStyle {
    case airy
    case bright
    case deep
    case intense
}

private struct GlobalHarmony {
    let rootPitchClass: Int
    let scale: MusicScale
}

private struct VibePreset {
    let density: Double
    let registerBias: Double
    let gate: Double
}

private let airyPreset = VibePreset(density: 0.40, registerBias: 7, gate: 0.72)
private let brightPreset = VibePreset(density: 0.72, registerBias: 12, gate: 0.42)
private let deepPreset = VibePreset(density: 0.34, registerBias: -12, gate: 0.78)
private let intensePreset = VibePreset(density: 0.82, registerBias: -5, gate: 0.34)
