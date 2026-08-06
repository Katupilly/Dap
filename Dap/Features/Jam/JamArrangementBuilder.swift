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

            let lhsSignature = visualSignature(for: lhs)
            let rhsSignature = visualSignature(for: rhs)
            if lhsSignature != rhsSignature { return lhsSignature < rhsSignature }

            return false
        }

        switch orderedSounds.count {
        case 3...5:
            let harmonyIndex = (orderedSounds.count - 1) / 2
            return [
                AssignedSound(sound: orderedSounds[0], role: .bass),
                AssignedSound(sound: orderedSounds[harmonyIndex], role: .harmony),
                AssignedSound(sound: orderedSounds[orderedSounds.count - 1], role: .melody),
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
        drumKit: MusicDrumKit,
        bassVariation: JamBassVariation = .initial,
        harmonyVariation: JamHarmonyVariation = .initial,
        melodyVariation: JamMelodyVariation = .initial,
        buildMode: MelodyVariationBuildMode = .standard
    ) -> JamArrangement? {
        let assignedSounds = assignRoles(to: sounds)
        return build(
            assignedSounds: assignedSounds,
            vibePosition: vibePosition,
            drumKit: drumKit,
            bassVariation: bassVariation,
            harmonyVariation: harmonyVariation,
            melodyVariation: melodyVariation,
            buildMode: buildMode
        )
    }

    func build(
        assignedSounds: [AssignedSound],
        vibePosition: CGPoint,
        drumKit: MusicDrumKit,
        bassVariation: JamBassVariation = .initial,
        harmonyVariation: JamHarmonyVariation = .initial,
        melodyVariation: JamMelodyVariation = .initial,
        buildMode: MelodyVariationBuildMode = .standard
    ) -> JamArrangement? {
        guard let melodySound = assignedSounds.first(where: { $0.role == .melody }) else {
            return nil
        }

        let preset = interpolatedPreset(for: vibePosition)
        let registerShift = Int(preset.registerBias.rounded())
        let harmony = globalHarmony(for: assignedSounds.map { $0.sound })
        let melodyProfile = melodySound.sound.sequence.soundProfile
        let region = JamGrooveLibrary.region(for: vibePosition)
        let selectedVisualSignatures = assignedSounds.map { visualSignature(for: $0.sound) }
        let percussion = grooveLibrary.pattern(
            for: vibePosition,
            visualSignatures: selectedVisualSignatures,
            drumKit: drumKit
        )

        var activeStepsBySoundID: [UUID: Set<Int>] = [:]

        var notes: [MusicNote] = []

        for assignedSound in assignedSounds {
            let sourceNotes = sortedNotes(from: assignedSound.sound.sequence.notes)
            guard !sourceNotes.isEmpty else { continue }

            let builtNotes: [MusicNote]
            switch assignedSound.role {
            case .bass:
                builtNotes = buildBassNotes(
                    from: sourceNotes,
                    visualSignature: visualSignature(for: assignedSound.sound),
                    harmony: harmony,
                    registerShift: registerShift,
                    vibePosition: vibePosition,
                    region: region,
                    variation: bassVariation
                )
            case .harmony:
                builtNotes = buildHarmonyNotes(
                    from: sourceNotes,
                    visualSignature: visualSignature(for: assignedSound.sound),
                    harmony: harmony,
                    registerShift: registerShift,
                    vibePosition: vibePosition,
                    region: region,
                    variation: harmonyVariation
                )
            case .melody:
                builtNotes = buildMelodyNotes(
                    from: sourceNotes,
                    harmony: harmony,
                    registerShift: registerShift,
                    melodyVariation: melodyVariation,
                    buildMode: buildMode,
                    density: effectiveDensity(
                        for: .melody,
                        sourceCount: sourceNotes.count,
                        vibePosition: vibePosition
                    ),
                    region: region,
                    selectedVisualSignatures: selectedVisualSignatures
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
        visualSignature: UInt64,
        harmony: GlobalHarmony,
        registerShift: Int,
        vibePosition: CGPoint,
        region: JamRegion,
        variation: JamBassVariation
    ) -> [MusicNote] {
        guard let intent = variation.intent, variation != .initial else {
            return buildLegacyBassNotes(
                from: sourceNotes,
                harmony: harmony,
                registerShift: registerShift,
                vibePosition: vibePosition
            )
        }

        let stepNotes = representativeNotesByStep(from: sourceNotes)
        guard !stepNotes.isEmpty else { return [] }

        let seed = stableRoleVariationSeed(
            visualSignature: visualSignature,
            roleLabel: "bass",
            intentLabel: intent.rawValue,
            generation: variation.generation,
            harmony: harmony,
            region: region,
            sourceNotes: sourceNotes
        )
        let patternSteps = bassPatternSteps(for: intent, seed: seed)
        let totalCount = patternSteps.count
        var previousMIDINote: Int?

        return patternSteps.enumerated().map { index, step in
            let note = nearestNote(to: step, from: stepNotes)
            let sourcePitchClass = PitchClass(normalizing: note.midiNote).rawValue
            let chosenPitchClass = variedBassPitchClass(
                for: intent,
                sourcePitchClass: sourcePitchClass,
                harmony: harmony,
                step: step,
                noteIndex: index,
                seed: seed
            )
            let targetMIDINote = variedBassMIDINote(
                for: intent,
                pitchClass: chosenPitchClass,
                previousMIDINote: previousMIDINote,
                registerShift: registerShift,
                step: step
            )
            previousMIDINote = targetMIDINote

            return MusicNote(
                step: step,
                row: row(for: targetMIDINote),
                midiNote: targetMIDINote,
                velocity: transformedVelocity(
                    note.velocity,
                    multiplier: bassVelocityMultiplier(
                        for: intent,
                        step: step,
                        noteIndex: index,
                        totalCount: totalCount
                    ),
                    role: .bass
                ),
                voiceRole: .bass,
                timingOffsetSteps: bassTimingOffsetSteps(
                    for: intent,
                    step: step,
                    noteIndex: index,
                    totalCount: totalCount
                )
            )
        }
    }

    private func buildLegacyBassNotes(
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
        visualSignature: UInt64,
        harmony: GlobalHarmony,
        registerShift: Int,
        vibePosition: CGPoint,
        region: JamRegion,
        variation: JamHarmonyVariation
    ) -> [MusicNote] {
        guard let intent = variation.intent, variation != .initial else {
            return buildLegacyHarmonyNotes(
                from: sourceNotes,
                harmony: harmony,
                registerShift: registerShift,
                vibePosition: vibePosition
            )
        }

        let sourceEvents = harmonySourceEvents(from: sourceNotes)
        guard !sourceEvents.isEmpty else { return [] }

        let seed = stableRoleVariationSeed(
            visualSignature: visualSignature,
            roleLabel: "harmony",
            intentLabel: intent.rawValue,
            generation: variation.generation,
            harmony: harmony,
            region: region,
            sourceNotes: sourceNotes
        )
        let patternSteps = harmonyPatternSteps(for: intent, seed: seed)

        return patternSteps.flatMap { step in
            let sourceEvent = nearestHarmonyEvent(to: step, from: sourceEvents)
            let voicedNotes = transformedHarmonyVoicing(
                from: sourceEvent.notes,
                harmony: harmony,
                registerShift: registerShift,
                intent: intent
            )

            guard !voicedNotes.isEmpty else { return [MusicNote]() }

            return voicedNotes.map { midiNote in
                MusicNote(
                    step: step,
                    row: row(for: midiNote),
                    midiNote: midiNote,
                    velocity: transformedVelocity(
                        sourceEvent.velocity,
                        multiplier: harmonyVelocityMultiplier(for: intent, eventSize: voicedNotes.count),
                        role: .harmony
                    ),
                    voiceRole: .harmony
                )
            }
        }
    }

    private func buildLegacyHarmonyNotes(
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
        melodyVariation: JamMelodyVariation,
        buildMode: MelodyVariationBuildMode,
        density: Double,
        region: JamRegion,
        selectedVisualSignatures: [UInt64]
    ) -> [MusicNote] {
        let sourceByStep = representativeNotesByStep(from: sourceNotes)
        guard !sourceByStep.isEmpty else { return [] }

        let seed = stableMelodySeed(
            selectedVisualSignatures: selectedVisualSignatures,
            harmony: harmony,
            region: region,
            sourceNotes: sourceByStep,
            melodyVariation: melodyVariation
        )
        let variationFamily = MelodyVariationFamily(generation: melodyVariation.generation)
        let retention = buildMode == .fallback
            ? max(0.55, density)
            : max(0.82, density)
        let selectedSource = sampledNotes(
            from: sourceByStep,
            density: retention
        )
        let scalePitchClasses = harmony.scale.degrees.map { (harmony.rootPitchClass + $0) % 12 }
        var previousMIDINote: Int?

        return selectedSource.enumerated().map { index, source in
            let snapped = nearestScaleMIDINote(
                to: source.midiNote + registerShift,
                rootPitchClass: harmony.rootPitchClass,
                scale: harmony.scale,
                range: 60...96
            )
            let targetMIDINote = variedPhotoMelodyMIDINote(
                snapped,
                index: index,
                eventCount: selectedSource.count,
                family: variationFamily,
                buildMode: buildMode,
                seed: seed,
                scalePitchClasses: scalePitchClasses,
                previousMIDINote: previousMIDINote
            )
            previousMIDINote = targetMIDINote
            let beatAccent: Float = source.step.isMultiple(of: 4) ? 1.06 : 1.0
            let regionalIntensity: Float = region == .intense ? 1.04 : 1.0
            let velocity = min(
                0.96,
                max(0.28, source.velocity * 0.82 * beatAccent * regionalIntensity)
            )
            return MusicNote(
                step: source.step,
                row: row(for: targetMIDINote),
                midiNote: targetMIDINote,
                velocity: velocity,
                voiceRole: .melody,
                timingOffsetSteps: nil
            )
        }
    }

    private func variedPhotoMelodyMIDINote(
        _ snappedMIDINote: Int,
        index: Int,
        eventCount: Int,
        family: MelodyVariationFamily,
        buildMode: MelodyVariationBuildMode,
        seed: UInt64,
        scalePitchClasses: [Int],
        previousMIDINote: Int?
    ) -> Int {
        guard family != .rhythm || buildMode == .fallback || eventCount > 0 else {
            return snappedMIDINote
        }

        let mutationSeed = mixedSeed(seed, salt: UInt64(index) &+ 0xCAFE)
        let direction = ((mutationSeed >> 5) & 1) == 0 ? 1 : -1
        let shouldMutate: Bool
        switch family {
        case .rhythm:
            shouldMutate = index.isMultiple(of: 3)
        case .contour:
            shouldMutate = index > 0
        case .register:
            shouldMutate = index.isMultiple(of: 2)
        case .full:
            shouldMutate = index.isMultiple(of: 2) || buildMode == .fallback
        }

        var result = snappedMIDINote
        if shouldMutate {
            switch family {
            case .register:
                result = octaveShiftedMIDINote(
                    from: result,
                    preferredDirection: direction,
                    range: 60...96
                ) ?? result
            default:
                result = moveScaleSteps(
                    from: result,
                    steps: direction * (buildMode == .fallback ? 2 : 1),
                    scalePitchClasses: scalePitchClasses,
                    range: 60...96
                )
            }
        }

        if let previousMIDINote,
           abs(result - previousMIDINote) > 12 {
            return softenedPhotoMelodyLeap(
                from: previousMIDINote,
                to: result,
                scalePitchClasses: scalePitchClasses
            )
        }
        return result
    }

    private func softenedPhotoMelodyLeap(
        from previousMIDINote: Int,
        to midiNote: Int,
        scalePitchClasses: [Int]
    ) -> Int {
        let direction = midiNote >= previousMIDINote ? 1 : -1
        return moveScaleSteps(
            from: previousMIDINote,
            steps: direction,
            scalePitchClasses: scalePitchClasses,
            range: 60...96
        )
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

    private func bassTimingOffsetSteps(
        for intent: BassPatternIntent,
        step: Int,
        noteIndex: Int,
        totalCount: Int
    ) -> Float? {
        let offset: Float
        switch intent {
        case .steady:
            offset = 0
        case .syncopated:
            offset = bassTimingOffsetSteps(for: step, noteIndex: noteIndex, totalCount: totalCount)
        case .driving:
            offset = step % 4 == 2 ? 0.03 : 0
        }

        return offset == 0 ? nil : offset
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

    private func bassVelocityMultiplier(
        for intent: BassPatternIntent,
        step: Int,
        noteIndex: Int,
        totalCount: Int
    ) -> Float {
        switch intent {
        case .steady:
            return step.isMultiple(of: 4) ? 0.82 : 0.68
        case .syncopated:
            return bassVelocityMultiplier(for: step, noteIndex: noteIndex)
        case .driving:
            return step.isMultiple(of: 4) ? 0.86 : (noteIndex == totalCount - 1 ? 0.72 : 0.78)
        }
    }

    private func bassPatternSteps(for intent: BassPatternIntent, seed: UInt64) -> [Int] {
        let templates: [[Int]]
        switch intent {
        case .steady:
            templates = [
                [0, 4, 8, 12],
                [0, 4, 10, 12],
                [0, 5, 8, 13]
            ]
        case .syncopated:
            templates = [
                [2, 6, 10, 14],
                [0, 3, 7, 10, 14],
                [1, 6, 9, 13]
            ]
        case .driving:
            templates = [
                [0, 2, 4, 6, 8, 10, 12, 14],
                [0, 2, 3, 6, 8, 10, 11, 14],
                [0, 2, 5, 6, 8, 10, 13, 14]
            ]
        }

        return templates[deterministicIndex(seed: seed, upperBound: templates.count)]
    }

    private func variedBassPitchClass(
        for intent: BassPatternIntent,
        sourcePitchClass: Int,
        harmony: GlobalHarmony,
        step: Int,
        noteIndex: Int,
        seed: UInt64
    ) -> Int {
        let rootPitchClass = harmony.rootPitchClass
        let fifthPitchClass = (harmony.rootPitchClass + 7) % 12

        switch intent {
        case .steady:
            if step.isMultiple(of: 8) { return rootPitchClass }
            let useFifth = ((seed >> (noteIndex % 8)) & 1) == 1
            return useFifth ? fifthPitchClass : rootPitchClass
        case .syncopated:
            if noteIndex.isMultiple(of: 2) {
                return preferredBassPitchClass(
                    for: sourcePitchClass,
                    rootPitchClass: rootPitchClass,
                    fifthPitchClass: fifthPitchClass
                )
            }
            return fifthPitchClass
        case .driving:
            return step.isMultiple(of: 4) ? rootPitchClass : fifthPitchClass
        }
    }

    private func variedBassMIDINote(
        for intent: BassPatternIntent,
        pitchClass: Int,
        previousMIDINote: Int?,
        registerShift: Int,
        step: Int
    ) -> Int {
        let baseMIDINote = bassMIDINote(
            pitchClass: pitchClass,
            previousMIDINote: previousMIDINote,
            registerShift: registerShift
        )

        switch intent {
        case .steady, .syncopated:
            return baseMIDINote
        case .driving:
            let lowered = baseMIDINote - 12
            if step.isMultiple(of: 4), lowered >= 48 {
                return lowered
            }
            return baseMIDINote
        }
    }

    private func nearestNote(to targetStep: Int, from notes: [MusicNote]) -> MusicNote {
        notes.min { lhs, rhs in
            let lhsDistance = circularStepDistance(lhs.step, targetStep)
            let rhsDistance = circularStepDistance(rhs.step, targetStep)
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            if lhs.step != rhs.step { return lhs.step < rhs.step }
            return lhs.midiNote < rhs.midiNote
        } ?? notes[0]
    }

    private func harmonyPatternSteps(for intent: HarmonyPatternIntent, seed: UInt64) -> [Int] {
        let templates: [[Int]]
        switch intent {
        case .sustained:
            templates = [
                [0, 8],
                [0, 6, 12],
                [2, 8, 14]
            ]
        case .rhythmic:
            templates = [
                [0, 4, 6, 8, 12, 14],
                [2, 4, 8, 10, 12, 15],
                [0, 3, 7, 8, 11, 15]
            ]
        case .open:
            templates = [
                [0, 8, 12],
                [0, 4, 8, 12],
                [2, 8, 14]
            ]
        }

        return templates[deterministicIndex(seed: seed, upperBound: templates.count)]
    }

    private func transformedHarmonyVoicing(
        from sourceNotes: [MusicNote],
        harmony: GlobalHarmony,
        registerShift: Int,
        intent: HarmonyPatternIntent
    ) -> [Int] {
        let preferredCenter = 66 + registerShift
        let transformed = sourceNotes.map { note in
            nearestScaleMIDINote(
                to: note.midiNote + registerShift,
                rootPitchClass: harmony.rootPitchClass,
                scale: harmony.scale,
                range: 54...90
            )
        }

        var voicing = sanitizeHarmonyVoicing(
            transformed,
            preferredCenter: preferredCenter,
            limit: sourceNotes.count > 1 ? 4 : 1
        )

        if intent == .open {
            voicing = openedHarmonyVoicing(voicing)
        }

        return voicing.isEmpty ? [min(90, max(54, preferredCenter))] : voicing
    }

    private func sanitizeHarmonyVoicing(
        _ notes: [Int],
        preferredCenter: Int,
        limit: Int
    ) -> [Int] {
        var sanitized: [Int] = []
        for note in notes.sorted() {
            let clamped = min(90, max(54, note))
            guard sanitized.last != clamped else { continue }
            sanitized.append(clamped)
            if sanitized.count == limit { break }
        }

        guard !sanitized.isEmpty else {
            return [min(90, max(54, preferredCenter))]
        }

        return sanitized
    }

    private func openedHarmonyVoicing(_ notes: [Int]) -> [Int] {
        guard notes.count >= 2 else { return notes }
        var opened = notes.sorted()
        let highestIndex = opened.count - 1
        let lifted = opened[highestIndex] + 12
        if lifted <= 90, !opened.contains(lifted) {
            opened[highestIndex] = lifted
        }
        return opened.sorted()
    }

    private func harmonyVelocityMultiplier(for intent: HarmonyPatternIntent, eventSize: Int) -> Float {
        let sizeTrim: Float = eventSize >= 3 ? 0.92 : 1.0
        switch intent {
        case .sustained:
            return 0.50 * sizeTrim
        case .rhythmic:
            return 0.60 * sizeTrim
        case .open:
            return 0.54 * sizeTrim
        }
    }

    private func nearestHarmonyEvent(to targetStep: Int, from events: [HarmonySourceEvent]) -> HarmonySourceEvent {
        events.min { lhs, rhs in
            let lhsDistance = circularStepDistance(lhs.step, targetStep)
            let rhsDistance = circularStepDistance(rhs.step, targetStep)
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            return lhs.step < rhs.step
        } ?? events[0]
    }

    private func harmonySourceEvents(from notes: [MusicNote]) -> [HarmonySourceEvent] {
        let sorted = sortedNotes(from: notes)
        let notesByStep = Dictionary(grouping: sorted, by: \.step)

        return notesByStep.keys
            .sorted()
            .compactMap { step in
                guard let stepNotes = notesByStep[step], !stepNotes.isEmpty else {
                    return nil
                }
                let orderedNotes = stepNotes.sorted { lhs, rhs in
                    if lhs.midiNote != rhs.midiNote { return lhs.midiNote < rhs.midiNote }
                    return lhs.row < rhs.row
                }
                let dedupedNotes = orderedNotes.reduce(into: [MusicNote]()) { result, note in
                    if result.last?.midiNote != note.midiNote {
                        result.append(note)
                    }
                }
                return HarmonySourceEvent(
                    step: step,
                    notes: Array(dedupedNotes.prefix(4)),
                    velocity: dedupedNotes.map(\.velocity).max() ?? 0.55
                )
            }
    }

    private func circularStepDistance(_ lhs: Int, _ rhs: Int) -> Int {
        let direct = abs(lhs - rhs)
        return min(direct, MusicSequence.steps - direct)
    }

    private func stableRoleVariationSeed(
        visualSignature: UInt64,
        roleLabel: String,
        intentLabel: String,
        generation: UInt64,
        harmony: GlobalHarmony,
        region: JamRegion,
        sourceNotes: [MusicNote]
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

        var signature = visualSignature
        for _ in 0..<8 {
            feed(byte: UInt8(truncatingIfNeeded: signature))
            signature >>= 8
        }
        feed(string: roleLabel)
        feed(string: intentLabel)
        feed(int: harmony.rootPitchClass)
        feed(string: harmony.scale.rawValue)
        feed(string: region.seedLabel)

        for note in sortedNotes(from: sourceNotes) {
            feed(int: note.step)
            feed(int: note.midiNote)
        }

        return hash ^ mixedVariationGeneration(generation)
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
            let sourceHarmony = sounds.first?.sequence.harmony
            return GlobalHarmony(
                rootPitchClass: sourceHarmony?.rootPitchClass ?? 0,
                scale: sourceHarmony?.scale ?? .majorPentatonic
            )
        }

        if sounds.count == 1, let sourceHarmony = sounds.first?.sequence.harmony {
            // A one-photo Jam is the direct audition of that Photo. Do not
            // replace its root or scale with a global re-composition.
            return GlobalHarmony(
                rootPitchClass: sourceHarmony.rootPitchClass,
                scale: sourceHarmony.scale
            )
        }

        var histogram = Array(repeating: 0, count: 12)
        for note in allNotes {
            histogram[PitchClass(normalizing: note.midiNote).rawValue] += 1
        }

        var bestCandidate = GlobalHarmony(rootPitchClass: 0, scale: .majorPentatonic)
        var bestCoverage = Int.min
        var bestScaleMatches = Int.min

        for scale in MusicScale.allCases {
            for root in 0..<12 {
                let coverage = scale.degrees
                    .map { (root + $0) % 12 }
                    .reduce(0) { $0 + histogram[$1] }
                let scaleMatches = sounds.reduce(into: 0) { count, sound in
                    if sound.sequence.harmony.scale == scale {
                        count += 1
                    }
                }

                if coverage > bestCoverage {
                    bestCoverage = coverage
                    bestScaleMatches = scaleMatches
                    bestCandidate = GlobalHarmony(rootPitchClass: root, scale: scale)
                    continue
                }

                guard coverage == bestCoverage else { continue }

                if scaleMatches > bestScaleMatches {
                    bestScaleMatches = scaleMatches
                    bestCandidate = GlobalHarmony(rootPitchClass: root, scale: scale)
                } else if scaleMatches == bestScaleMatches,
                          scale.rawValue == bestCandidate.scale.rawValue,
                          root < bestCandidate.rootPitchClass {
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
        selectedVisualSignatures: [UInt64],
        harmony: GlobalHarmony,
        region: JamRegion,
        sourceNotes: [MusicNote],
        melodyVariation: JamMelodyVariation
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

        for signature in selectedVisualSignatures.sorted() {
            var value = signature
            for _ in 0..<8 {
                feed(byte: UInt8(truncatingIfNeeded: value))
                value >>= 8
            }
        }

        feed(int: harmony.rootPitchClass)
        feed(string: harmony.scale.rawValue)
        feed(string: region.seedLabel)

        for note in sourceNotes {
            feed(int: note.step)
            feed(int: note.midiNote)
        }

        let mixedGeneration = mixedVariationGeneration(melodyVariation.generation)
        return hash ^ mixedGeneration
    }

    private func mixedVariationGeneration(_ generation: UInt64) -> UInt64 {
        var value = generation &+ 0x9E37_79B9_7F4A_7C15
        value ^= value >> 30
        value &*= 0xBF58_476D_1CE4_E5B9
        value ^= value >> 27
        value &*= 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return value
    }

    private func mixedSeed(_ seed: UInt64, salt: UInt64) -> UInt64 {
        var value = seed &+ salt &+ 0x9E37_79B9_7F4A_7C15
        value ^= value >> 30
        value &*= 0xBF58_476D_1CE4_E5B9
        value ^= value >> 27
        value &*= 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return value
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

    private func melodyContour(
        for region: JamRegion,
        seed: UInt64,
        variationFamily: MelodyVariationFamily
    ) -> MelodyContour {
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

        let contourSeed = variationFamily.emphasizesContour ? mixedSeed(seed, salt: 0xC0B7_0A11_5EED_0001) : seed
        return contours[deterministicIndex(seed: contourSeed, upperBound: contours.count)]
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

    /// Aggregates source-note attack positions into a 0..7 weight map.
    /// Both halves of the 16-step grid fold onto the same 8 positions,
    /// so a photo whose activity sits in steps 8..15 still influences selection.
    private func photoRhythmSignature(
        from sourceNotes: [MelodySourceNote]
    ) -> [Int: Double] {
        var weights: [Int: Double] = [:]
        for note in sourceNotes where (0..<16).contains(note.step) {
            weights[note.step % 8, default: 0] += 1
        }
        return weights
    }

    /// Selects one of the region's hard-coded rhythm templates by scoring how
    /// well it covers the photo's rhythmic activity. Falls back to the
    /// legacy seed-based index when no signature is available.
    private func photoConditionedMelodyTemplate(
        for region: JamRegion,
        seed: UInt64,
        variationFamily: MelodyVariationFamily,
        transformedSourceNotes: [MelodySourceNote]
    ) -> [Int] {
        let templates = melodyTemplates(for: region)
        let rhythmSeed = variationFamily.emphasizesRhythm ? mixedSeed(seed, salt: 0x71A2_1A11_7A11_7A11) : seed
        let legacyIndex = deterministicIndex(seed: rhythmSeed >> 1, upperBound: templates.count)

        let signature = photoRhythmSignature(from: transformedSourceNotes)
        let totalWeight = signature.values.reduce(0, +)
        guard totalWeight > 0 else {
            return templates[legacyIndex]
        }

        let scored = templates.enumerated().map { (index, template) -> (index: Int, score: Double) in
            (index, templateScore(template: template, signature: signature, totalWeight: totalWeight))
        }
        let bestScore = scored.map(\.score).max() ?? 0
        let tied = scored.filter { $0.score == bestScore }
        if tied.count == 1 {
            return templates[tied[0].index]
        }
        if let legacyAmongTied = tied.first(where: { $0.index == legacyIndex }) {
            return templates[legacyAmongTied.index]
        }
        let tieIndex = deterministicIndex(
            seed: rhythmSeed >> 3,
            upperBound: tied.count
        )
        return templates[tied[tieIndex].index]
    }

    private func templateScore(
        template: [Int],
        signature: [Int: Double],
        totalWeight: Double
    ) -> Double {
        var coveredWeight: Double = 0
        var exactMatches = 0
        var proximityMatches = 0
        for step in template {
            if let weight = signature[step] {
                coveredWeight += weight
                exactMatches += 1
            } else if hasAdjacentPhotoStep(step, in: signature) {
                proximityMatches += 1
            }
        }
        let coverage = coveredWeight / totalWeight
        let precision = Double(exactMatches) / Double(template.count)
        let proximity = Double(proximityMatches) / Double(template.count)
        return coverage * 0.60 + precision * 0.30 + proximity * 0.10
    }

    /// True when at least one of the steps at circular distance 1 from
    /// `step` (in an 8-step loop) has a non-zero photo weight.
    private func hasAdjacentPhotoStep(
        _ step: Int,
        in signature: [Int: Double]
    ) -> Bool {
        for offset in [-1, 1] {
            var neighbor = step + offset
            if neighbor < 0 { neighbor = 7 }
            if neighbor > 7 { neighbor = 0 }
            if signature[neighbor] != nil { return true }
        }
        return false
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
        region: JamRegion,
        variationFamily: MelodyVariationFamily,
        seed: UInt64
    ) -> Int {
        let registerOffset: Int
        if variationFamily.emphasizesRegister {
            switch deterministicIndex(seed: mixedSeed(seed, salt: 0x3344) >> 4, upperBound: 3) {
            case 0: registerOffset = -5
            case 1: registerOffset = 0
            default: registerOffset = 5
            }
        } else {
            registerOffset = 0
        }
        let preferredCenter = min(96, max(60, regionMelodyCenter(for: region) + registerShift / 2 + registerOffset))
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
        variationFamily: MelodyVariationFamily,
        buildMode: MelodyVariationBuildMode,
        preserveLeadingAnchor: Bool,
        kickSteps: Set<Int>
    ) -> [Int] {
        guard template.count >= 2 else { return template }
        let activeRhythmFamily = variationFamily.emphasizesRhythm || buildMode == .fallback
        guard activeRhythmFamily else { return template }

        var varied = template.sorted()
        let desiredMutationCount = min(
            max(2, buildMode == .fallback ? max(2, varied.count / 2) : max(2, Int(ceil(Double(varied.count) * 0.35)))),
            max(2, min(4, varied.count))
        )
        let mutableIndices = varied.indices.filter { index in
            !(preserveLeadingAnchor && index == 0)
        }
        guard !mutableIndices.isEmpty else { return varied }

        for mutation in 0..<desiredMutationCount {
            let indexSeed = mixedSeed(seed, salt: UInt64(mutation) &+ 0x5100)
            let selectedIndex = mutableIndices[deterministicIndex(seed: indexSeed, upperBound: mutableIndices.count)]
            let stepSeed = mixedSeed(seed, salt: UInt64(mutation) &+ 0x9100)
            let candidateMoves = movementChoices(for: region, seed: stepSeed, aggressive: buildMode == .fallback)

            for move in candidateMoves {
                let shiftedStep = varied[selectedIndex] + move
                guard (0..<8).contains(shiftedStep), !varied.contains(shiftedStep) else { continue }
                varied[selectedIndex] = shiftedStep
                break
            }
        }

        if buildMode == .fallback || variationFamily == .full {
            varied = varied.sorted()
            if varied.count >= 4 {
                let removalCandidates = varied.indices.filter { index in
                    !(preserveLeadingAnchor && index == 0)
                }
                if !removalCandidates.isEmpty {
                    let removalIndex = removalCandidates[
                        deterministicIndex(
                            seed: mixedSeed(seed, salt: 0xABCD),
                            upperBound: removalCandidates.count
                        )
                    ]
                    let removed = varied.remove(at: removalIndex)
                    let insertionCandidates = Array(0..<8).filter { !varied.contains($0) }
                    let orderedInsertions = insertionCandidates.sorted { lhs, rhs in
                        abs(lhs - removed) < abs(rhs - removed)
                    }
                    if let insertion = orderedInsertions.first(where: { candidate in
                        abs(candidate - removed) >= 1 && abs(candidate - removed) <= 3
                    }) {
                        varied.append(insertion)
                    } else {
                        varied.append(removed)
                    }
                }
            }
        }

        return Array(Set(varied)).sorted()
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
        variationFamily: MelodyVariationFamily,
        seed: UInt64,
        buildMode: MelodyVariationBuildMode
    ) -> [Int] {
        guard offsets.count >= 2 else {
            return offsets
        }

        guard variationFamily.emphasizesContour || variationKind == .pitchChange || buildMode == .fallback else {
            return offsets
        }

        var varied = offsets
        let candidateIndices = varied.indices.filter { $0 != 0 }
        let mutationCount = min(candidateIndices.count, max(2, min(4, buildMode == .fallback ? varied.count : Int(ceil(Double(varied.count) * 0.40)))))

        for mutation in 0..<mutationCount {
            let indexSeed = mixedSeed(seed, salt: UInt64(mutation) &+ 0x4400)
            let targetIndex = candidateIndices[deterministicIndex(seed: indexSeed, upperBound: candidateIndices.count)]
            let directionSeed = mixedSeed(seed, salt: UInt64(mutation) &+ 0x5500)
            let direction = ((directionSeed >> 5) & 1) == 0 ? 1 : -1
            let magnitude = ((directionSeed >> 9) & 1) == 0 ? 1 : 2
            varied[targetIndex] += direction * magnitude
        }
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
        registerPlan: MelodyRegisterPlan,
        velocitySeed: UInt64,
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

            if let preferredDirection = registerPlan.preferredDirectionByIndex[index],
               let shifted = octaveShiftedMIDINote(
                from: resolvedMIDINote,
                preferredDirection: preferredDirection,
                range: 60...96
               ) {
                resolvedMIDINote = resolveMelodyConflict(
                    shifted,
                    step: step,
                    harmony: harmony,
                    accompanimentNotes: accompanimentNotes,
                    preferredAnchorMIDINote: anchorMIDINote
                )
            }

            let velocity = melodyVelocity(
                baseVelocity: transformedSourceNotes[min(index, transformedSourceNotes.count - 1)].velocity,
                attackRole: attackRole,
                region: region,
                variationKind: variationKind,
                seed: velocitySeed,
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
        seed: UInt64,
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
        let accentSeed = mixedSeed(seed, salt: UInt64(attackIndex) &+ 0x7000)
        if (accentSeed & 1) == 0 {
            velocity *= 0.96
        } else {
            velocity *= 1.04
        }

        return min(0.94, max(0.48, velocity))
    }

    private func movementChoices(for region: JamRegion, seed: UInt64, aggressive: Bool) -> [Int] {
        let base = aggressive ? [-2, 2, -1, 1] : [-1, 1, -2, 2]
        let rotate = deterministicIndex(seed: seed, upperBound: base.count)
        return Array(base[rotate...]) + Array(base[..<rotate])
    }

    private func melodyRegisterPlan(
        eventCount: Int,
        seed: UInt64,
        variationFamily: MelodyVariationFamily,
        buildMode: MelodyVariationBuildMode
    ) -> MelodyRegisterPlan {
        let activeRegisterFamily = variationFamily.emphasizesRegister || buildMode == .fallback
        guard activeRegisterFamily, eventCount >= 1 else {
            return MelodyRegisterPlan(preferredDirectionByIndex: [:])
        }

        let candidateIndices = Array(0..<eventCount)
        let mutationCount = min(candidateIndices.count, max(2, min(4, buildMode == .fallback ? max(2, eventCount / 2) : Int(ceil(Double(eventCount) * 0.40)))))
        var result: [Int: Int] = [:]

        for mutation in 0..<mutationCount {
            let indexSeed = mixedSeed(seed, salt: UInt64(mutation) &+ 0x8800)
            let index = candidateIndices[deterministicIndex(seed: indexSeed, upperBound: candidateIndices.count)]
            let directionSeed = mixedSeed(seed, salt: UInt64(mutation) &+ 0x9900)
            result[index] = ((directionSeed >> 7) & 1) == 0 ? 1 : -1
        }

        return MelodyRegisterPlan(preferredDirectionByIndex: result)
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

    private func visualSignature(for sound: PhotoSound) -> UInt64 {
        if let visualSignature = sound.visualSignature {
            return visualSignature
        }

        // Legacy v2 Photos have no persisted image signature. Their sequence
        // is still stable, so derive a content key without reviving UUID-based
        // musical variation.
        var hash: UInt64 = 0xcbf29ce484222325

        func feed(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }

        func feed(_ value: Int) {
            var bits = UInt64(bitPattern: Int64(value))
            for _ in 0..<8 {
                feed(UInt8(truncatingIfNeeded: bits))
                bits >>= 8
            }
        }

        feed(sound.sequence.harmony.rootPitchClass)
        for byte in sound.sequence.harmony.scale.rawValue.utf8 { feed(byte) }
        for note in sortedNotes(from: sound.sequence.notes) {
            feed(note.step)
            feed(note.row)
            feed(note.midiNote)
            feed(Int(note.velocity.bitPattern))
        }
        return hash
    }
}

struct JamArrangement: Sendable {
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

private struct HarmonySourceEvent {
    let step: Int
    let notes: [MusicNote]
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

enum MelodyVariationFamily {
    case rhythm
    case contour
    case register
    case full

    init(generation: UInt64) {
        switch generation % 4 {
        case 0: self = .rhythm
        case 1: self = .contour
        case 2: self = .register
        default: self = .full
        }
    }

    var emphasizesRhythm: Bool {
        self == .rhythm || self == .full
    }

    var emphasizesContour: Bool {
        self == .contour || self == .full
    }

    var emphasizesRegister: Bool {
        self == .register || self == .full
    }

    var logLabel: String {
        switch self {
        case .rhythm: "rhythm"
        case .contour: "contour"
        case .register: "register"
        case .full: "full"
        }
    }
}

enum MelodyVariationBuildMode {
    case standard
    case fallback
}

private struct MelodyRegisterPlan {
    let preferredDirectionByIndex: [Int: Int]
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
