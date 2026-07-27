import CoreGraphics
import Foundation

struct JamArrangementBuilder {
    let bpm: Int
    private let grooveLibrary = JamGrooveLibrary()

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
        vibePosition: CGPoint,
        drumKit: MusicDrumKit
    ) -> JamArrangement? {
        let assignedSounds = assignRoles(to: sounds)
        guard let melodySound = assignedSounds.first(where: { $0.role == .melody }) else {
            return nil
        }

        let preset = interpolatedPreset(for: vibePosition)
        let registerShift = Int(preset.registerBias.rounded())
        let harmony = globalHarmony(for: assignedSounds.map { $0.sound })
        let melodyProfile = melodySound.sound.sequence.soundProfile
        let region = JamGrooveLibrary.region(for: vibePosition)
        let percussion = grooveLibrary.pattern(
            for: vibePosition,
            soundIDs: sounds.map(\.id),
            drumKit: drumKit
        )

        var activeStepsBySoundID: [UUID: Set<Int>] = [:]

        var notes: [MusicNote] = []
        let selectedSoundIDs = assignedSounds.map(\.sound.id)

        for assignedSound in assignedSounds {
            let sourceNotes = sortedNotes(from: assignedSound.sound.sequence.notes)
            guard !sourceNotes.isEmpty else { continue }

            let builtNotes: [MusicNote]
            switch assignedSound.role {
            case .bass:
                builtNotes = buildBassNotes(
                    from: sourceNotes,
                    harmony: harmony,
                    registerShift: registerShift,
                    vibePosition: vibePosition
                )
            case .harmony:
                builtNotes = buildHarmonyNotes(
                    from: sourceNotes,
                    harmony: harmony,
                    registerShift: registerShift,
                    vibePosition: vibePosition
                )
            case .melody:
                builtNotes = buildMelodyNotes(
                    from: sourceNotes,
                    harmony: harmony,
                    registerShift: registerShift,
                    density: effectiveDensity(
                        for: .melody,
                        sourceCount: sourceNotes.count,
                        vibePosition: vibePosition
                    ),
                    region: region,
                    percussion: percussion,
                    accompanimentNotes: notes,
                    selectedSoundIDs: selectedSoundIDs
                )
            }

            if !builtNotes.isEmpty {
                activeStepsBySoundID[assignedSound.sound.id] = Set(builtNotes.map(\.step))
                notes.append(contentsOf: builtNotes)
            }
        }

        notes.sort {
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

        return JamArrangement(
            sequence: sequence,
            activeStepsBySoundID: activeStepsBySoundID,
            percussion: percussion
        )
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
        let totalCount = sampledNotes.count

        return sampledNotes.enumerated().map { index, note in
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

            let timingOffset = bassTimingOffsetSteps(
                for: note.step,
                noteIndex: index,
                totalCount: totalCount
            )

            return MusicNote(
                step: note.step,
                row: row(for: targetMIDINote),
                midiNote: targetMIDINote,
                velocity: transformedVelocity(
                    note.velocity,
                    multiplier: bassVelocityMultiplier(
                        for: note.step,
                        noteIndex: index
                    ),
                    role: .bass
                ),
                voiceRole: .bass,
                timingOffsetSteps: timingOffset == 0 ? nil : timingOffset
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
                ),
                voiceRole: .harmony
            )
        }
    }

    private func buildMelodyNotes(
        from sourceNotes: [MusicNote],
        harmony: GlobalHarmony,
        registerShift: Int,
        density: Double,
        region: JamRegion,
        percussion: MusicPercussionPattern,
        accompanimentNotes: [MusicNote],
        selectedSoundIDs: [UUID]
    ) -> [MusicNote] {
        let transformedSourceNotes = melodySourceNotes(
            from: sourceNotes,
            harmony: harmony,
            registerShift: registerShift
        )
        let scalePitchClasses = harmony.scale.degrees.map { (harmony.rootPitchClass + $0) % 12 }
        let seed = stableMelodySeed(
            selectedSoundIDs: selectedSoundIDs,
            harmony: harmony,
            region: region,
            transformedSourceNotes: transformedSourceNotes
        )
        let template = adjustedMelodyTemplate(
            melodyTemplate(for: region, seed: seed),
            region: region,
            density: density
        )

        guard !template.isEmpty else { return [] }

        let anchorPitchClass = melodyAnchorPitchClass(
            harmony: harmony,
            transformedSourceNotes: transformedSourceNotes
        )
        let contour = melodyContour(for: region, seed: seed)
        let anchorMIDINote = melodyAnchorMIDINote(
            anchorPitchClass: anchorPitchClass,
            harmony: harmony,
            transformedSourceNotes: transformedSourceNotes,
            registerShift: registerShift,
            region: region
        )
        let primaryOffsets = melodyContourOffsets(for: contour, count: template.count)
        let secondarySteps = variedMelodyTemplate(
            from: template,
            region: region,
            seed: seed,
            kickSteps: Set(percussion.kickHits.map(\.step))
        )
        let variationKind = melodyVariationKind(for: region, seed: seed)
        let secondaryOffsets = variedMelodyOffsets(
            from: primaryOffsets,
            variationKind: variationKind,
            seed: seed
        )

        let primaryHalf = buildMelodyHalf(
            relativeSteps: template,
            contourOffsets: primaryOffsets,
            halfOffset: 0,
            anchorMIDINote: anchorMIDINote,
            anchorPitchClass: anchorPitchClass,
            harmony: harmony,
            scalePitchClasses: scalePitchClasses,
            transformedSourceNotes: transformedSourceNotes,
            accompanimentNotes: accompanimentNotes,
            region: region,
            variationKind: nil,
            octaveJumpUsed: false
        )

        let secondaryHalf = buildMelodyHalf(
            relativeSteps: secondarySteps,
            contourOffsets: secondaryOffsets,
            halfOffset: 8,
            anchorMIDINote: anchorMIDINote,
            anchorPitchClass: anchorPitchClass,
            harmony: harmony,
            scalePitchClasses: scalePitchClasses,
            transformedSourceNotes: transformedSourceNotes,
            accompanimentNotes: accompanimentNotes + primaryHalf.notes,
            region: region,
            variationKind: variationKind,
            octaveJumpUsed: primaryHalf.usedOctaveJump
        )

        return primaryHalf.notes + secondaryHalf.notes
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

    private func bassTimingOffsetSteps(
        for step: Int,
        noteIndex: Int,
        totalCount: Int
    ) -> Float {
        guard step > 0 else { return 0 }

        let isStructuredPickup = totalCount >= 3 && noteIndex > 0 && noteIndex < totalCount - 1 && step % 8 == 3
        let proposedOffset: Float
        if isStructuredPickup {
            proposedOffset = -0.04
        } else if step % 4 == 2 {
            proposedOffset = 0.06
        } else {
            proposedOffset = 0
        }

        let clampedOffset = min(0.08, max(-0.06, proposedOffset))
        let latestOffset = Float(MusicSequence.steps - 1 - step) + 0.999
        return min(clampedOffset, latestOffset)
    }

    private func bassVelocityMultiplier(for step: Int, noteIndex: Int) -> Float {
        let base: Float = 0.70
        let accent: Float
        if step % 8 == 0 {
            accent = 1.12
        } else if step % 4 == 2 {
            accent = 0.94
        } else if noteIndex.isMultiple(of: 2) {
            accent = 1.04
        } else {
            accent = 0.90
        }

        return base * accent
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

    private func melodySourceNotes(
        from sourceNotes: [MusicNote],
        harmony: GlobalHarmony,
        registerShift: Int
    ) -> [MelodySourceNote] {
        var seen: Set<String> = []
        let transformed = sourceNotes.compactMap { note -> MelodySourceNote? in
            let shiftedTarget = min(96, max(60, note.midiNote + registerShift))
            let snappedMIDINote = nearestScaleMIDINote(
                to: shiftedTarget,
                rootPitchClass: harmony.rootPitchClass,
                scale: harmony.scale,
                range: 60...96
            )
            let key = "\(note.step)-\(snappedMIDINote)"
            guard seen.insert(key).inserted else { return nil }

            return MelodySourceNote(
                step: note.step,
                midiNote: snappedMIDINote,
                velocity: transformedVelocity(
                    note.velocity,
                    multiplier: 0.75,
                    role: .melody
                )
            )
        }

        if transformed.isEmpty {
            return [
                MelodySourceNote(
                    step: 0,
                    midiNote: nearestScaleMIDINote(
                        to: 78 + registerShift,
                        rootPitchClass: harmony.rootPitchClass,
                        scale: harmony.scale,
                        range: 60...96
                    ),
                    velocity: 0.72
                )
            ]
        }

        return transformed
    }

    private func stableMelodySeed(
        selectedSoundIDs: [UUID],
        harmony: GlobalHarmony,
        region: JamRegion,
        transformedSourceNotes: [MelodySourceNote]
    ) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037

        func feed(byte: UInt8) {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }

        func feed(string: String) {
            for byte in string.utf8 {
                feed(byte: byte)
            }
            feed(byte: 0xFF)
        }

        func feed(int: Int) {
            var value = UInt64(bitPattern: Int64(int))
            for _ in 0..<8 {
                feed(byte: UInt8(truncatingIfNeeded: value))
                value >>= 8
            }
        }

        for uuidString in selectedSoundIDs.map(\.uuidString).sorted() {
            feed(string: uuidString)
        }

        feed(int: harmony.rootPitchClass)
        feed(string: harmony.scale.rawValue)
        feed(string: region.seedLabel)

        for note in transformedSourceNotes {
            feed(int: note.step)
            feed(int: note.midiNote)
        }

        return hash
    }

    private func melodyAnchorPitchClass(
        harmony: GlobalHarmony,
        transformedSourceNotes: [MelodySourceNote]
    ) -> Int {
        let sourceCounts = transformedSourceNotes.reduce(into: [Int: Int]()) { counts, note in
            counts[PitchClass(normalizing: note.midiNote).rawValue, default: 0] += 1
        }
        let candidates = stableMelodyPitchClasses(harmony: harmony)

        if let chosen = candidates.max(by: { lhs, rhs in
            let lhsScore = sourceCounts[lhs, default: 0] * 10 - stablePitchPriority(for: lhs, harmony: harmony)
            let rhsScore = sourceCounts[rhs, default: 0] * 10 - stablePitchPriority(for: rhs, harmony: harmony)
            if lhsScore != rhsScore { return lhsScore < rhsScore }
            return lhs > rhs
        }) {
            return chosen
        }

        return transformedSourceNotes.first.map { PitchClass(normalizing: $0.midiNote).rawValue }
            ?? harmony.rootPitchClass
    }

    private func stableMelodyPitchClasses(harmony: GlobalHarmony) -> [Int] {
        let root = harmony.rootPitchClass
        let degrees = harmony.scale.degrees
        var pitchClasses = [root]

        if degrees.contains(4) { pitchClasses.append((root + 4) % 12) }
        if degrees.contains(3) { pitchClasses.append((root + 3) % 12) }
        if degrees.contains(7) { pitchClasses.append((root + 7) % 12) }
        if degrees.contains(10) { pitchClasses.append((root + 10) % 12) }

        var unique: [Int] = []
        for pitchClass in pitchClasses where !unique.contains(pitchClass) {
            unique.append(pitchClass)
        }
        return unique
    }

    private func stablePitchPriority(for pitchClass: Int, harmony: GlobalHarmony) -> Int {
        let root = harmony.rootPitchClass
        let minorThird = (root + 3) % 12
        let majorThird = (root + 4) % 12
        let fifth = (root + 7) % 12
        let seventh = (root + 10) % 12

        if pitchClass == root { return 0 }
        if pitchClass == minorThird || pitchClass == majorThird { return 1 }
        if pitchClass == fifth { return 2 }
        if pitchClass == seventh { return 3 }
        return 4
    }

    private func melodyContour(for region: JamRegion, seed: UInt64) -> MelodyContour {
        let contours: [MelodyContour]
        switch region {
        case .airy:
            contours = [.arch, .valley, .pendulum]
        case .bright:
            contours = [.ascending, .repeatedAnchor, .arch]
        case .deep:
            contours = [.descending, .valley, .pendulum]
        case .intense:
            contours = [.ascending, .repeatedAnchor, .pendulum]
        }

        return contours[deterministicIndex(seed: seed, upperBound: contours.count)]
    }

    private func melodyTemplates(for region: JamRegion) -> [[Int]] {
        switch region {
        case .airy:
            [[1, 4, 7], [0, 3, 6], [2, 5]]
        case .bright:
            [[0, 2, 5, 7], [1, 3, 6], [0, 3, 5, 7]]
        case .deep:
            [[0, 4, 7], [2, 5], [1, 4, 6]]
        case .intense:
            [[0, 2, 3, 6, 7], [1, 2, 4, 6], [0, 3, 4, 5, 7]]
        }
    }

    private func melodyTemplate(for region: JamRegion, seed: UInt64) -> [Int] {
        let templates = melodyTemplates(for: region)
        return templates[deterministicIndex(seed: seed >> 1, upperBound: templates.count)]
    }

    private func adjustedMelodyTemplate(
        _ template: [Int],
        region: JamRegion,
        density: Double
    ) -> [Int] {
        let targetCount: Int
        switch region {
        case .airy:
            targetCount = density > 0.55 ? 3 : 2
        case .bright:
            targetCount = density > 0.68 ? 4 : 3
        case .deep:
            targetCount = density > 0.48 ? 3 : 2
        case .intense:
            targetCount = density > 0.78 ? 5 : 4
        }

        guard template.count > targetCount else { return template }

        var adjusted = template
        while adjusted.count > targetCount {
            let removalIndex = min(max(1, adjusted.count / 2), adjusted.count - 2)
            adjusted.remove(at: removalIndex)
        }
        return adjusted
    }

    private func melodyContourOffsets(for contour: MelodyContour, count: Int) -> [Int] {
        switch (contour, count) {
        case (.ascending, 2): [0, 1]
        case (.ascending, 3): [0, 1, 2]
        case (.ascending, 4): [0, 1, 2, 1]
        case (.ascending, _): [0, 1, 2, 3, 1]

        case (.descending, 2): [1, 0]
        case (.descending, 3): [2, 1, 0]
        case (.descending, 4): [2, 1, 0, 0]
        case (.descending, _): [3, 2, 1, 0, 0]

        case (.arch, 2): [0, 1]
        case (.arch, 3): [0, 2, 0]
        case (.arch, 4): [0, 1, 2, 0]
        case (.arch, _): [0, 1, 3, 1, 0]

        case (.valley, 2): [1, 0]
        case (.valley, 3): [1, -1, 0]
        case (.valley, 4): [1, 0, -1, 0]
        case (.valley, _): [2, 1, 0, 1, 0]

        case (.pendulum, 2): [0, 1]
        case (.pendulum, 3): [0, 1, 0]
        case (.pendulum, 4): [0, 1, 0, -1]
        case (.pendulum, _): [0, 1, 0, -1, 0]

        case (.repeatedAnchor, 2): [0, 0]
        case (.repeatedAnchor, 3): [0, 1, 0]
        case (.repeatedAnchor, 4): [0, 1, 0, 2]
        case (.repeatedAnchor, _): [0, 1, 0, 2, 0]
        }
    }

    private func melodyAnchorMIDINote(
        anchorPitchClass: Int,
        harmony: GlobalHarmony,
        transformedSourceNotes: [MelodySourceNote],
        registerShift: Int,
        region: JamRegion
    ) -> Int {
        let preferredCenter = min(96, max(60, regionMelodyCenter(for: region) + registerShift / 2))
        let sourceCandidates = transformedSourceNotes
            .map(\.midiNote)
            .filter { PitchClass(normalizing: $0).rawValue == anchorPitchClass }

        if let bestSource = sourceCandidates.min(by: {
            abs($0 - preferredCenter) < abs($1 - preferredCenter)
        }) {
            return bestSource
        }

        let fallback = nearestScaleMIDINote(
            to: preferredCenter,
            rootPitchClass: harmony.rootPitchClass,
            scale: harmony.scale,
            range: 60...96
        )
        return centeredMIDINote(
            from: fallback,
            preferredCenter: preferredCenter,
            previousMIDINote: nil,
            range: 60...96
        )
    }

    private func regionMelodyCenter(for region: JamRegion) -> Int {
        switch region {
        case .airy:
            81
        case .bright:
            84
        case .deep:
            74
        case .intense:
            82
        }
    }

    private func variedMelodyTemplate(
        from template: [Int],
        region: JamRegion,
        seed: UInt64,
        kickSteps: Set<Int>
    ) -> [Int] {
        guard template.count >= 3, seed.isMultiple(of: 4) else { return template }

        var varied = template
        let candidateIndices = Array(1..<(template.count - 1))
        guard !candidateIndices.isEmpty else { return template }

        let selectedIndex = candidateIndices[deterministicIndex(seed: seed >> 3, upperBound: candidateIndices.count)]
        let preferredDirection: Int
        switch region {
        case .airy, .deep:
            preferredDirection = template[selectedIndex] < 5 ? 1 : -1
        case .bright, .intense:
            preferredDirection = kickSteps.contains(template[selectedIndex] + 8) ? -1 : 1
        }

        let shiftedStep = template[selectedIndex] + preferredDirection
        guard (0..<8).contains(shiftedStep), !template.contains(shiftedStep) else {
            return template
        }

        varied[selectedIndex] = shiftedStep
        return varied.sorted()
    }

    private func melodyVariationKind(for region: JamRegion, seed: UInt64) -> MelodyVariationKind {
        let kinds: [MelodyVariationKind]
        switch region {
        case .airy, .deep:
            kinds = [.pitchChange, .rhythmShift, .velocityAccent]
        case .bright, .intense:
            kinds = [.pitchChange, .rhythmShift, .octaveShift, .velocityAccent]
        }
        return kinds[deterministicIndex(seed: seed >> 2, upperBound: kinds.count)]
    }

    private func variedMelodyOffsets(
        from offsets: [Int],
        variationKind: MelodyVariationKind,
        seed: UInt64
    ) -> [Int] {
        guard variationKind == .pitchChange, offsets.count >= 3 else {
            return offsets
        }

        var varied = offsets
        let targetIndex = min(max(1, offsets.count / 2), offsets.count - 2)
        let direction = ((seed >> 5) & 1) == 0 ? 1 : -1
        varied[targetIndex] += direction
        return varied
    }

    private func buildMelodyHalf(
        relativeSteps: [Int],
        contourOffsets: [Int],
        halfOffset: Int,
        anchorMIDINote: Int,
        anchorPitchClass: Int,
        harmony: GlobalHarmony,
        scalePitchClasses: [Int],
        transformedSourceNotes: [MelodySourceNote],
        accompanimentNotes: [MusicNote],
        region: JamRegion,
        variationKind: MelodyVariationKind?,
        octaveJumpUsed: Bool
    ) -> MelodyHalfResult {
        let sourceCandidatesByPitchClass = Dictionary(grouping: transformedSourceNotes.map(\.midiNote)) {
            PitchClass(normalizing: $0).rawValue
        }
        var notes: [MusicNote] = []
        var previousMIDINote: Int?
        var usedOctaveJump = octaveJumpUsed

        for index in relativeSteps.indices {
            let relativeStep = relativeSteps[index]
            let step = halfOffset + relativeStep
            let attackRole = melodyAttackRole(for: index, attackCount: relativeSteps.count)
            let targetMIDINote = moveScaleSteps(
                from: anchorMIDINote,
                steps: contourOffsets[min(index, contourOffsets.count - 1)],
                scalePitchClasses: scalePitchClasses,
                range: 60...96
            )
            let desiredPitchClass = PitchClass(normalizing: targetMIDINote).rawValue
            var resolvedMIDINote = melodyMIDINote(
                desiredPitchClass: desiredPitchClass,
                targetMIDINote: targetMIDINote,
                anchorMIDINote: anchorMIDINote,
                anchorPitchClass: anchorPitchClass,
                attackRole: attackRole,
                sourceCandidatesByPitchClass: sourceCandidatesByPitchClass,
                previousMIDINote: previousMIDINote,
                harmony: harmony
            )
            resolvedMIDINote = resolveMelodyConflict(
                resolvedMIDINote,
                step: step,
                harmony: harmony,
                accompanimentNotes: accompanimentNotes,
                preferredAnchorMIDINote: anchorMIDINote
            )

            if variationKind == .octaveShift,
               !usedOctaveJump,
               attackRole == .climax,
               let octaveShifted = octaveShiftedMIDINote(
                from: resolvedMIDINote,
                preferredDirection: region == .intense ? 1 : ((resolvedMIDINote <= 84) ? 1 : -1),
                range: 60...96
               ) {
                resolvedMIDINote = octaveShifted
                usedOctaveJump = true
            }

            if let previousMIDINote,
               abs(resolvedMIDINote - previousMIDINote) > 7,
               let softened = softenedMelodyLeap(
                from: previousMIDINote,
                to: resolvedMIDINote,
                harmony: harmony
               ) {
                resolvedMIDINote = softened
            }

            let velocity = melodyVelocity(
                baseVelocity: transformedSourceNotes[min(index, transformedSourceNotes.count - 1)].velocity,
                attackRole: attackRole,
                region: region,
                variationKind: variationKind,
                attackIndex: index,
                attackCount: relativeSteps.count
            )

            notes.append(
                MusicNote(
                    step: step,
                    row: row(for: resolvedMIDINote),
                    midiNote: resolvedMIDINote,
                    velocity: velocity,
                    voiceRole: .melody,
                    timingOffsetSteps: nil
                )
            )
            previousMIDINote = resolvedMIDINote
        }

        return normalizedMelodyHalf(
            notes,
            contourOffsets: contourOffsets,
            anchorMIDINote: anchorMIDINote,
            harmony: harmony,
            accompanimentNotes: accompanimentNotes,
            region: region,
            usedOctaveJump: usedOctaveJump
        )
    }

    private func melodyMIDINote(
        desiredPitchClass: Int,
        targetMIDINote: Int,
        anchorMIDINote: Int,
        anchorPitchClass: Int,
        attackRole: MelodyAttackRole,
        sourceCandidatesByPitchClass: [Int: [Int]],
        previousMIDINote: Int?,
        harmony: GlobalHarmony
    ) -> Int {
        let stablePitchClasses = stableMelodyPitchClasses(harmony: harmony)
        let effectivePitchClass: Int
        switch attackRole {
        case .anchor, .resolution:
            effectivePitchClass = stablePitchClasses.contains(desiredPitchClass) ? desiredPitchClass : anchorPitchClass
        case .passing, .climax:
            effectivePitchClass = desiredPitchClass
        }

        let sourceCandidates = sourceCandidatesByPitchClass[effectivePitchClass] ?? []
        let scaleCandidates = scaleMIDINotes(for: effectivePitchClass, in: 60...96)
        let allCandidates = Array(Set(sourceCandidates + scaleCandidates)).sorted()

        return allCandidates.min { lhs, rhs in
            let lhsScore = melodyCandidateScore(
                lhs,
                targetMIDINote: targetMIDINote,
                anchorMIDINote: anchorMIDINote,
                sourceCandidates: sourceCandidates,
                previousMIDINote: previousMIDINote,
                attackRole: attackRole,
                harmony: harmony
            )
            let rhsScore = melodyCandidateScore(
                rhs,
                targetMIDINote: targetMIDINote,
                anchorMIDINote: anchorMIDINote,
                sourceCandidates: sourceCandidates,
                previousMIDINote: previousMIDINote,
                attackRole: attackRole,
                harmony: harmony
            )
            if lhsScore != rhsScore { return lhsScore < rhsScore }
            return lhs < rhs
        } ?? anchorMIDINote
    }

    private func melodyCandidateScore(
        _ candidate: Int,
        targetMIDINote: Int,
        anchorMIDINote: Int,
        sourceCandidates: [Int],
        previousMIDINote: Int?,
        attackRole: MelodyAttackRole,
        harmony: GlobalHarmony
    ) -> Int {
        var score = abs(candidate - targetMIDINote) * 4

        if sourceCandidates.contains(candidate) {
            score -= 5
        }

        if let previousMIDINote {
            let leap = abs(candidate - previousMIDINote)
            if leap > 5 {
                score += (leap - 5) * 3
            }
        }

        if attackRole == .anchor || attackRole == .resolution {
            score += abs(candidate - anchorMIDINote)
        }

        if !stableMelodyPitchClasses(harmony: harmony).contains(PitchClass(normalizing: candidate).rawValue),
           attackRole != .passing {
            score += 4
        }

        return score
    }

    private func resolveMelodyConflict(
        _ midiNote: Int,
        step: Int,
        harmony: GlobalHarmony,
        accompanimentNotes: [MusicNote],
        preferredAnchorMIDINote: Int
    ) -> Int {
        let bassNotesAtStep = accompanimentNotes.filter { $0.voiceRole == .bass && $0.step == step }
        let conflicts = bassNotesAtStep.filter {
            PitchClass(normalizing: $0.midiNote).rawValue == PitchClass(normalizing: midiNote).rawValue &&
            abs($0.midiNote - midiNote) < 12
        }

        guard !conflicts.isEmpty else { return midiNote }

        let octaveCandidates = [midiNote + 12, midiNote - 12].filter { (60...96).contains($0) }
        if let octaveCandidate = octaveCandidates.max(by: { lhs, rhs in
            accompanimentDistanceScore(lhs, to: bassNotesAtStep) < accompanimentDistanceScore(rhs, to: bassNotesAtStep)
        }) {
            return octaveCandidate
        }

        let scalePitchClasses = harmony.scale.degrees.map { (harmony.rootPitchClass + $0) % 12 }
        let neighboringCandidates = [-1, 1].map {
            moveScaleSteps(
                from: midiNote,
                steps: $0,
                scalePitchClasses: scalePitchClasses,
                range: 60...96
            )
        }
        if let neighboringCandidate = neighboringCandidates.max(by: { lhs, rhs in
            accompanimentDistanceScore(lhs, to: bassNotesAtStep) < accompanimentDistanceScore(rhs, to: bassNotesAtStep)
        }), accompanimentDistanceScore(neighboringCandidate, to: bassNotesAtStep) > accompanimentDistanceScore(midiNote, to: bassNotesAtStep) {
            return neighboringCandidate
        }

        return centeredMIDINote(
            from: midiNote,
            preferredCenter: preferredAnchorMIDINote,
            previousMIDINote: nil,
            range: 60...96
        )
    }

    private func accompanimentDistanceScore(_ midiNote: Int, to bassNotes: [MusicNote]) -> Int {
        bassNotes.map { abs($0.midiNote - midiNote) }.min() ?? 0
    }

    private func octaveShiftedMIDINote(
        from midiNote: Int,
        preferredDirection: Int,
        range: ClosedRange<Int>
    ) -> Int? {
        let upward = midiNote + 12
        let downward = midiNote - 12

        if preferredDirection >= 0, range.contains(upward) { return upward }
        if preferredDirection < 0, range.contains(downward) { return downward }
        if range.contains(upward) { return upward }
        if range.contains(downward) { return downward }
        return nil
    }

    private func softenedMelodyLeap(
        from previousMIDINote: Int,
        to midiNote: Int,
        harmony: GlobalHarmony
    ) -> Int? {
        let direction = midiNote > previousMIDINote ? 1 : -1
        let scalePitchClasses = harmony.scale.degrees.map { (harmony.rootPitchClass + $0) % 12 }
        let softened = moveScaleSteps(
            from: previousMIDINote,
            steps: direction,
            scalePitchClasses: scalePitchClasses,
            range: 60...96
        )
        return softened == previousMIDINote ? nil : softened
    }

    private func melodyVelocity(
        baseVelocity: Float,
        attackRole: MelodyAttackRole,
        region: JamRegion,
        variationKind: MelodyVariationKind?,
        attackIndex: Int,
        attackCount: Int
    ) -> Float {
        let roleMultiplier: Float
        switch attackRole {
        case .anchor:
            roleMultiplier = 1.08
        case .passing:
            roleMultiplier = 0.82
        case .climax:
            roleMultiplier = region == .intense ? 1.18 : 1.12
        case .resolution:
            roleMultiplier = 0.96
        }

        var velocity = baseVelocity * roleMultiplier
        if variationKind == .velocityAccent, attackIndex == max(0, attackCount - 2) {
            velocity *= 1.08
        }

        return min(0.94, max(0.48, velocity))
    }

    private func normalizedMelodyHalf(
        _ notes: [MusicNote],
        contourOffsets: [Int],
        anchorMIDINote: Int,
        harmony: GlobalHarmony,
        accompanimentNotes: [MusicNote],
        region: JamRegion,
        usedOctaveJump: Bool
    ) -> MelodyHalfResult {
        guard !notes.isEmpty else {
            return MelodyHalfResult(notes: [], usedOctaveJump: usedOctaveJump)
        }

        let uniqueMIDINotes = Set(notes.map(\.midiNote))
        guard uniqueMIDINotes.count == 1, contourOffsets.count > 1 else {
            return MelodyHalfResult(notes: notes, usedOctaveJump: usedOctaveJump)
        }

        let scalePitchClasses = harmony.scale.degrees.map { (harmony.rootPitchClass + $0) % 12 }
        let adjustmentIndex = min(max(1, notes.count / 2), notes.count - 1)
        let adjustedMIDINote = moveScaleSteps(
            from: notes[adjustmentIndex].midiNote,
            steps: region == .deep ? -1 : 1,
            scalePitchClasses: scalePitchClasses,
            range: 60...96
        )
        let resolvedMIDINote = resolveMelodyConflict(
            adjustedMIDINote,
            step: notes[adjustmentIndex].step,
            harmony: harmony,
            accompanimentNotes: accompanimentNotes,
            preferredAnchorMIDINote: anchorMIDINote
        )

        var adjustedNotes = notes
        adjustedNotes[adjustmentIndex] = MusicNote(
            step: notes[adjustmentIndex].step,
            row: row(for: resolvedMIDINote),
            midiNote: resolvedMIDINote,
            velocity: notes[adjustmentIndex].velocity,
            voiceRole: .melody,
            timingOffsetSteps: nil
        )
        return MelodyHalfResult(notes: adjustedNotes, usedOctaveJump: usedOctaveJump)
    }

    private func melodyAttackRole(for index: Int, attackCount: Int) -> MelodyAttackRole {
        if index == 0 { return .anchor }
        if index == attackCount - 1 { return .resolution }
        if index == max(1, attackCount / 2) { return .climax }
        return .passing
    }

    private func moveScaleSteps(
        from midiNote: Int,
        steps: Int,
        scalePitchClasses: [Int],
        range: ClosedRange<Int>
    ) -> Int {
        guard steps != 0 else {
            return min(range.upperBound, max(range.lowerBound, midiNote))
        }

        var currentMIDINote = min(range.upperBound, max(range.lowerBound, midiNote))
        let direction = steps > 0 ? 1 : -1

        for _ in 0..<abs(steps) {
            var candidate = currentMIDINote + direction
            while range.contains(candidate) {
                if scalePitchClasses.contains(PitchClass(normalizing: candidate).rawValue) {
                    currentMIDINote = candidate
                    break
                }
                candidate += direction
            }
        }

        return min(range.upperBound, max(range.lowerBound, currentMIDINote))
    }

    private func scaleMIDINotes(for pitchClass: Int, in range: ClosedRange<Int>) -> [Int] {
        range.filter { PitchClass(normalizing: $0).rawValue == pitchClass }
    }

    private func deterministicIndex(seed: UInt64, upperBound: Int) -> Int {
        guard upperBound > 0 else { return 0 }
        return Int(seed % UInt64(upperBound))
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

private struct GlobalHarmony {
    let rootPitchClass: Int
    let scale: MusicScale
}

private struct VibePreset {
    let density: Double
    let registerBias: Double
    let gate: Double
}

private struct MelodySourceNote {
    let step: Int
    let midiNote: Int
    let velocity: Float
}

private struct MelodyHalfResult {
    let notes: [MusicNote]
    let usedOctaveJump: Bool
}

private enum MelodyContour {
    case ascending
    case descending
    case arch
    case valley
    case pendulum
    case repeatedAnchor
}

private enum MelodyVariationKind {
    case pitchChange
    case rhythmShift
    case octaveShift
    case velocityAccent
}

private enum MelodyAttackRole {
    case anchor
    case passing
    case climax
    case resolution
}

private extension JamRegion {
    var seedLabel: String {
        switch self {
        case .airy:
            "airy"
        case .bright:
            "bright"
        case .deep:
            "deep"
        case .intense:
            "intense"
        }
    }
}

private let airyPreset = VibePreset(density: 0.40, registerBias: 7, gate: 0.72)
private let brightPreset = VibePreset(density: 0.72, registerBias: 12, gate: 0.42)
private let deepPreset = VibePreset(density: 0.34, registerBias: -12, gate: 0.78)
private let intensePreset = VibePreset(density: 0.82, registerBias: -5, gate: 0.34)
