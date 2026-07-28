import Foundation

struct RenderedJamAudio {
    var left: [Float]
    var right: [Float]
}

enum JamAudioRenderer {

    private struct OpenHatVoice {
        var audio: RenderedJamAudio
        let startFrame: Int
        let frameCount: Int
    }

    private enum DrumVoice {
        case kick
        case snare
        case closedHat
    }

    private enum MelodicVoiceFade {
        static let bassMilliseconds = 30.0
        static let harmonyMilliseconds = 80.0
        static let melodyMilliseconds = 45.0
    }

    private struct FutureBassEvent {
        let midiNote: Int
        let velocity: Float
        let startFrame: Int
        let musicalEndFrame: Int
    }

    private struct FutureBassState {
        var sawPhase = 0.0
        var trianglePhase = 0.0
        var subPhase = 0.0
        var lowPassSample: Float = 0
    }

    private enum KickDucking {
        static let bassMinimumGain: Float = 0.72
        static let harmonyMinimumGain: Float = 0.54
        static let bassReleaseMilliseconds = 170.0
        static let harmonyReleaseMilliseconds = 210.0
    }

    nonisolated private static let tonalGain: Float = 0.16
    nonisolated private static let kickGain: Float = 0.70
    nonisolated private static let snareGain: Float = 0.58
    nonisolated private static let closedHatGain: Float = 0.35
    nonisolated private static let openHatGain: Float = 0.30
    nonisolated private static let rimSoftGain: Float = 0.30
    nonisolated private static let rimMainGain: Float = 0.42
    nonisolated private static let rimHardGain: Float = 0.34

    nonisolated static func render(
        _ sequence: MusicSequence,
        percussion: MusicPercussionPattern?,
        sampleRate: Int,
        loops: Bool
    ) throws -> RenderedJamAudio {
        try Task.checkCancellation()

        let bpm = Double(sequence.harmony.bpm)
        let samplesPerStep = Int((60.0 / bpm / 4.0 * Double(sampleRate)).rounded())
        let gateSamples = max(1, Int(Double(samplesPerStep) * sequence.soundProfile.gate))
        let wave = waveformTable(sequence.soundProfile.waveform, size: 512)
        let envelope = envelopeTable(length: gateSamples)
        let tonalFrameCount = samplesPerStep * MusicSequence.steps
        let sortedNotes = sequence.notes.sorted(by: byNoteOrder)
        let maximumMelodicFrameCount = try maximumSampleBasedFrameCount(
            for: sortedNotes,
            samplesPerStep: samplesPerStep,
            gateSamples: gateSamples,
            sampleRate: sampleRate,
            tonalFrameCount: tonalFrameCount
        )
        let maximumPercussionFrameCount = percussion.map {
            let drumKit = DrumSampleLibrary.kit(for: $0.kit)
            return reservedPercussionFrameCount(
                for: $0,
                samplesPerStep: samplesPerStep,
                sampleRate: sampleRate,
                drumKit: drumKit
            )
        } ?? 0
        let frameCount = loops ? tonalFrameCount : max(maximumMelodicFrameCount, maximumPercussionFrameCount)
        var output = RenderedJamAudio(
            left: [Float](repeating: 0, count: frameCount),
            right: [Float](repeating: 0, count: frameCount)
        )
        var bassOutput = emptyRenderedAudio(frameCount: frameCount)
        var harmonyOutput = emptyRenderedAudio(frameCount: frameCount)
        let bassNotes = sortedNotes.filter { $0.voiceRole == .bass }

        try Task.checkCancellation()
        let didRenderFutureBass = try renderFutureBassLine(
            bassNotes,
            into: &bassOutput,
            samplesPerStep: samplesPerStep,
            gateSamples: gateSamples,
            sampleRate: sampleRate,
            loops: loops,
            tonalFrameCount: tonalFrameCount
        )
        let byStep = Dictionary(grouping: sortedNotes, by: \.step)

        for step in 0..<MusicSequence.steps {
            try Task.checkCancellation()

            for note in byStep[step] ?? [] {
                if note.voiceRole == .bass {
                    if !didRenderFutureBass {
                        renderProceduralNote(
                            note,
                            into: &bassOutput,
                            wave: wave,
                            envelope: envelope,
                            samplesPerStep: samplesPerStep,
                            tonalFrameCount: tonalFrameCount,
                            sampleRate: sampleRate
                        )
                    }
                    continue
                }

                let didRenderSample: Bool
                switch note.voiceRole {
                case .bass:
                    didRenderSample = false
                case .harmony:
                    didRenderSample = renderSampleBasedNote(
                        note,
                        role: .harmony,
                        allNotes: sortedNotes,
                        into: &harmonyOutput,
                        samplesPerStep: samplesPerStep,
                        gateSamples: gateSamples,
                        sampleRate: sampleRate,
                        loops: loops
                    )
                case .melody:
                    didRenderSample = renderSampleBasedNote(
                        note,
                        role: .melody,
                        allNotes: sortedNotes,
                        into: &output,
                        samplesPerStep: samplesPerStep,
                        gateSamples: gateSamples,
                        sampleRate: sampleRate,
                        loops: loops
                    )
                case nil:
                    didRenderSample = false
                }

                if !didRenderSample {
                    switch note.voiceRole {
                    case .bass:
                        renderProceduralNote(
                            note,
                            into: &bassOutput,
                            wave: wave,
                            envelope: envelope,
                            samplesPerStep: samplesPerStep,
                            tonalFrameCount: tonalFrameCount,
                            sampleRate: sampleRate
                        )
                    case .harmony:
                        renderProceduralNote(
                            note,
                            into: &harmonyOutput,
                            wave: wave,
                            envelope: envelope,
                            samplesPerStep: samplesPerStep,
                            tonalFrameCount: tonalFrameCount,
                            sampleRate: sampleRate
                        )
                    case .melody, nil:
                        renderProceduralNote(
                            note,
                            into: &output,
                            wave: wave,
                            envelope: envelope,
                            samplesPerStep: samplesPerStep,
                            tonalFrameCount: tonalFrameCount,
                            sampleRate: sampleRate
                        )
                    }
                }
            }
        }

        let kickFrames = resolvedKickFrames(
            from: percussion?.kickHits ?? [],
            samplesPerStep: samplesPerStep,
            frameCount: frameCount
        )

        if !kickFrames.isEmpty {
            try Task.checkCancellation()
            try applyKickDucking(
                to: &bassOutput,
                kickFrames: kickFrames,
                minimumGain: KickDucking.bassMinimumGain,
                releaseSamples: millisecondsToSamples(KickDucking.bassReleaseMilliseconds, sampleRate: sampleRate)
            )
            try applyKickDucking(
                to: &harmonyOutput,
                kickFrames: kickFrames,
                minimumGain: KickDucking.harmonyMinimumGain,
                releaseSamples: millisecondsToSamples(KickDucking.harmonyReleaseMilliseconds, sampleRate: sampleRate)
            )
        }

        mix(layer: bassOutput, into: &output)
        mix(layer: harmonyOutput, into: &output)

        if let percussion {
            try Task.checkCancellation()
            let drumKit = DrumSampleLibrary.kit(for: percussion.kit)
            try renderPercussion(
                percussion,
                into: &output,
                samplesPerStep: samplesPerStep,
                sampleRate: sampleRate,
                loops: loops,
                drumKit: drumKit
            )
        }

        if !loops {
            try Task.checkCancellation()
            trimTrailingSilence(in: &output, minimumFrameCount: tonalFrameCount)
        }

        try Task.checkCancellation()
        clamp(&output.left)
        clamp(&output.right)
        return output
    }

    nonisolated private static func renderPercussion(
        _ pattern: MusicPercussionPattern,
        into output: inout RenderedJamAudio,
        samplesPerStep: Int,
        sampleRate: Int,
        loops: Bool,
        drumKit: DrumSampleKit
    ) throws {
        try Task.checkCancellation()
        for hit in pattern.kickHits.sorted(by: byStep) {
            if let sample = drumKit.kick {
                mix(
                    sample: sample,
                    gain: kickGain * drumKit.kickTrim * hit.velocity,
                    startFrame: hit.step * samplesPerStep,
                    into: &output,
                    loops: loops
                )
            } else {
                renderKick(
                    step: hit.step,
                    velocity: hit.velocity,
                    into: &output,
                    samplesPerStep: samplesPerStep,
                    sampleRate: sampleRate,
                    loops: loops
                )
            }
        }

        try Task.checkCancellation()
        for hit in pattern.snareHits.sorted(by: byStep) {
            if let sample = drumKit.snare {
                mix(
                    sample: sample,
                    gain: snareGain * drumKit.snareTrim * hit.velocity,
                    startFrame: hit.step * samplesPerStep,
                    into: &output,
                    loops: loops
                )
            } else {
                renderSnare(
                    step: hit.step,
                    velocity: hit.velocity,
                    into: &output,
                    samplesPerStep: samplesPerStep,
                    sampleRate: sampleRate,
                    loops: loops
                )
            }
        }

        try Task.checkCancellation()
        if let openHatSample = drumKit.openHat, !pattern.openHatHits.isEmpty {
            let openHatLayer = try renderOpenHatLayer(
                hits: pattern.openHatHits.sorted(by: byStep),
                closedHatHits: pattern.closedHatHits.sorted(by: byStep),
                sample: openHatSample,
                gain: openHatGain * drumKit.openHatTrim,
                samplesPerStep: samplesPerStep,
                sampleRate: sampleRate,
                loops: loops,
                frameCount: output.left.count
            )
            mix(layer: openHatLayer, into: &output)
        }

        try Task.checkCancellation()
        for hit in pattern.closedHatHits.sorted(by: byStep) {
            if let sample = drumKit.closedHat {
                mix(
                    sample: sample,
                    gain: closedHatGain * drumKit.closedHatTrim * hit.velocity,
                    startFrame: hit.step * samplesPerStep,
                    into: &output,
                    loops: loops
                )
            } else {
                renderClosedHat(
                    step: hit.step,
                    velocity: hit.velocity,
                    into: &output,
                    samplesPerStep: samplesPerStep,
                    sampleRate: sampleRate,
                    loops: loops
                )
            }
        }

        try Task.checkCancellation()
        for hit in pattern.rimHits.sorted(by: byRimStep) {
            guard let sample = rimSample(for: hit.style, drumKit: drumKit) else { continue }
            mix(
                sample: sample,
                gain: rimGain(for: hit.style) * hit.velocity,
                startFrame: hit.step * samplesPerStep,
                into: &output,
                loops: loops
            )
        }
    }

    nonisolated private static func maximumSampleBasedFrameCount(
        for notes: [MusicNote],
        samplesPerStep: Int,
        gateSamples: Int,
        sampleRate: Int,
        tonalFrameCount: Int
    ) throws -> Int {
        var maximumFrameCount = tonalFrameCount

        for note in notes {
            try Task.checkCancellation()

            guard let role = note.voiceRole,
                  role != .bass,
                  let resolvedSample = MelodicSampleLibrary.resolvedSample(for: role, midiNote: note.midiNote) else {
                continue
            }

            let ratio = playbackRatio(
                targetMIDINote: resolvedSample.targetMIDINote,
                rootMIDINote: resolvedSample.sample.rootMIDINote,
                sourceSampleRate: resolvedSample.sample.sampleRate,
                outputSampleRate: Double(sampleRate)
            )
            let naturalFrameCount = renderedSampleFrameCount(sample: resolvedSample.sample, ratio: ratio)
            let endFrame = effectiveMelodicEndFrame(
                for: note,
                role: role,
                allNotes: notes,
                samplesPerStep: samplesPerStep,
                gateSamples: gateSamples
            )
            let noteStartFrame = note.step * samplesPerStep
            let musicalFrameCount = max(0, endFrame - noteStartFrame)
            let fadeFrameCount = fadeFrameCount(for: role, sampleRate: sampleRate)
            let truncatedFrameCount = naturalFrameCount > musicalFrameCount
                ? min(naturalFrameCount, musicalFrameCount + fadeFrameCount)
                : naturalFrameCount

            maximumFrameCount = max(maximumFrameCount, noteStartFrame + truncatedFrameCount)
        }

        return maximumFrameCount
    }

    nonisolated private static func renderFutureBassLine(
        _ notes: [MusicNote],
        into output: inout RenderedJamAudio,
        samplesPerStep: Int,
        gateSamples: Int,
        sampleRate: Int,
        loops: Bool,
        tonalFrameCount: Int
    ) throws -> Bool {
        guard !notes.isEmpty else { return false }

        let bassGateSamples = max(gateSamples, Int((Double(samplesPerStep) * 0.96).rounded()))
        let releaseFrameCount = fadeFrameCount(for: .bass, sampleRate: sampleRate)
        let events = notes.compactMap {
            futureBassEvent(
                for: $0,
                samplesPerStep: samplesPerStep,
                gateSamples: bassGateSamples,
                tonalFrameCount: tonalFrameCount
            )
        }
        .sorted { lhs, rhs in
            if lhs.startFrame != rhs.startFrame { return lhs.startFrame < rhs.startFrame }
            return lhs.midiNote < rhs.midiNote
        }

        guard !events.isEmpty else { return false }

        var state = FutureBassState()
        var previousEvent: FutureBassEvent?

        for index in events.indices {
            try Task.checkCancellation()

            let event = events[index]
            let nextStartFrame = index + 1 < events.count ? events[index + 1].startFrame : .max
            let hasIncomingLegato = previousEvent.map { event.startFrame < $0.musicalEndFrame } ?? false
            let hasOutgoingLegato = nextStartFrame < event.musicalEndFrame
            let segmentEndFrame = hasOutgoingLegato
                ? nextStartFrame
                : min(event.musicalEndFrame + releaseFrameCount, nextStartFrame, tonalFrameCount)

            guard segmentEndFrame > event.startFrame else {
                previousEvent = event
                continue
            }

            renderFutureBassEvent(
                event,
                previousMIDINote: hasIncomingLegato ? previousEvent?.midiNote : nil,
                into: &output,
                state: &state,
                sampleRate: sampleRate,
                segmentEndFrame: segmentEndFrame,
                hasIncomingLegato: hasIncomingLegato,
                loops: loops
            )

            previousEvent = event
        }

        return true
    }

    nonisolated private static func futureBassEvent(
        for note: MusicNote,
        samplesPerStep: Int,
        gateSamples: Int,
        tonalFrameCount: Int
    ) -> FutureBassEvent? {
        let startFrame = bassStartFrame(
            step: note.step,
            timingOffsetSteps: note.timingOffsetSteps ?? 0,
            samplesPerStep: samplesPerStep,
            tonalFrameCount: tonalFrameCount
        )
        guard startFrame < tonalFrameCount else { return nil }

        let musicalEndFrame = min(tonalFrameCount, startFrame + gateSamples)
        return FutureBassEvent(
            midiNote: note.midiNote,
            velocity: note.velocity,
            startFrame: startFrame,
            musicalEndFrame: musicalEndFrame
        )
    }

    nonisolated private static func renderFutureBassEvent(
        _ event: FutureBassEvent,
        previousMIDINote: Int?,
        into output: inout RenderedJamAudio,
        state: inout FutureBassState,
        sampleRate: Int,
        segmentEndFrame: Int,
        hasIncomingLegato: Bool,
        loops: Bool
    ) {
        let attackFrames = max(1, Int((0.003 * Double(sampleRate)).rounded()))
        let decayFrames = max(1, Int((0.180 * Double(sampleRate)).rounded()))
        let releaseFrames = max(1, Int((0.080 * Double(sampleRate)).rounded()))
        let filterDecayFrames = max(1, Int((0.220 * Double(sampleRate)).rounded()))
        let glideFrames = max(1, Int((0.085 * Double(sampleRate)).rounded()))
        let sustainLevel: Float = 0.60
        let filterBaseCutoff = 650.0
        let filterAttackCutoff = 1500.0
        let loopFrameCount = output.left.count
        let startMIDINote = previousMIDINote ?? event.midiNote

        for frame in event.startFrame..<segmentEndFrame {
            let localFrame = frame - event.startFrame
            let midiNote: Double
            if hasIncomingLegato, localFrame < glideFrames {
                let progress = smoothstep(Double(localFrame) / Double(glideFrames))
                midiNote = Double(startMIDINote) + Double(event.midiNote - startMIDINote) * progress
            } else {
                midiNote = Double(event.midiNote)
            }

            let frequency = 440.0 * pow(2.0, (midiNote - 69.0) / 12.0)
            let subSample = advanceSinePhase(state: &state.subPhase, frequency: frequency, sampleRate: sampleRate)
            let sawSample = advanceSawPhase(state: &state.sawPhase, frequency: frequency, sampleRate: sampleRate)
            let triangleSample = advanceTrianglePhase(state: &state.trianglePhase, frequency: frequency, sampleRate: sampleRate)

            let rawSample = subSample * 0.50 + sawSample * 0.35 + triangleSample * 0.15
            let envelope = futureBassEnvelope(
                localFrame: localFrame,
                noteEndLocalFrame: max(0, event.musicalEndFrame - event.startFrame),
                segmentLength: segmentEndFrame - event.startFrame,
                attackFrames: attackFrames,
                decayFrames: decayFrames,
                sustainLevel: sustainLevel,
                releaseFrames: releaseFrames,
                hasIncomingLegato: hasIncomingLegato
            )
            let cutoff = futureBassCutoff(
                localFrame: localFrame,
                decayFrames: filterDecayFrames,
                baseCutoff: filterBaseCutoff,
                attackCutoff: filterAttackCutoff,
                hasIncomingLegato: hasIncomingLegato
            )
            let filteredSample = lowPass(
                input: rawSample,
                cutoff: cutoff,
                sampleRate: sampleRate,
                state: &state.lowPassSample
            )
            let saturatedSample = Float(tanh(Double(filteredSample) * 1.45))
            let renderedSample = saturatedSample * envelope * event.velocity * 0.70
            let destinationFrame = loops ? frame % loopFrameCount : frame

            guard destinationFrame < output.left.count else { break }
            output.left[destinationFrame] += renderedSample
            output.right[destinationFrame] += renderedSample
        }
    }

    nonisolated private static func bassStartFrame(
        step: Int,
        timingOffsetSteps: Float,
        samplesPerStep: Int,
        tonalFrameCount: Int
    ) -> Int {
        let clampedOffset = min(0.08, max(-0.06, timingOffsetSteps))
        let boundedOffset = step == 0 ? max(0, clampedOffset) : clampedOffset
        let relativeStep = Double(step) + Double(boundedOffset)
        let startFrame = Int((relativeStep * Double(samplesPerStep)).rounded())
        return min(max(0, startFrame), max(0, tonalFrameCount - 1))
    }

    nonisolated private static func futureBassEnvelope(
        localFrame: Int,
        noteEndLocalFrame: Int,
        segmentLength: Int,
        attackFrames: Int,
        decayFrames: Int,
        sustainLevel: Float,
        releaseFrames: Int,
        hasIncomingLegato: Bool
    ) -> Float {
        let releaseStartFrame = min(segmentLength, noteEndLocalFrame)

        if localFrame >= releaseStartFrame {
            let releaseProgress = Float(localFrame - releaseStartFrame) / Float(max(1, releaseFrames))
            return max(0, sustainLevel * (1 - releaseProgress))
        }

        if hasIncomingLegato {
            return sustainLevel
        }

        if localFrame < attackFrames {
            return Float(localFrame) / Float(max(1, attackFrames))
        }

        let decayProgress = Float(localFrame - attackFrames) / Float(max(1, decayFrames))
        return max(sustainLevel, 1 - (1 - sustainLevel) * min(1, decayProgress))
    }

    nonisolated private static func futureBassCutoff(
        localFrame: Int,
        decayFrames: Int,
        baseCutoff: Double,
        attackCutoff: Double,
        hasIncomingLegato: Bool
    ) -> Double {
        guard !hasIncomingLegato else { return baseCutoff }
        let progress = min(1.0, Double(localFrame) / Double(max(1, decayFrames)))
        return attackCutoff - (attackCutoff - baseCutoff) * progress
    }

    nonisolated private static func lowPass(
        input: Float,
        cutoff: Double,
        sampleRate: Int,
        state: inout Float
    ) -> Float {
        let alpha = Float(exp(-2.0 * Double.pi * cutoff / Double(sampleRate)))
        state = (1 - alpha) * input + alpha * state
        return state
    }

    nonisolated private static func advanceSawPhase(
        state: inout Double,
        frequency: Double,
        sampleRate: Int
    ) -> Float {
        state = (state + frequency / Double(sampleRate)).truncatingRemainder(dividingBy: 1.0)
        return Float(state * 2.0 - 1.0)
    }

    nonisolated private static func advanceTrianglePhase(
        state: inout Double,
        frequency: Double,
        sampleRate: Int
    ) -> Float {
        state = (state + frequency / Double(sampleRate)).truncatingRemainder(dividingBy: 1.0)
        return Float(1.0 - 4.0 * abs(state - 0.5))
    }

    nonisolated private static func advanceSinePhase(
        state: inout Double,
        frequency: Double,
        sampleRate: Int
    ) -> Float {
        state += 2.0 * Double.pi * frequency / Double(sampleRate)
        state.formTruncatingRemainder(dividingBy: 2.0 * Double.pi)
        return Float(sin(state))
    }

    nonisolated private static func smoothstep(_ value: Double) -> Double {
        let clamped = min(1.0, max(0.0, value))
        return clamped * clamped * (3.0 - 2.0 * clamped)
    }

    nonisolated private static func reservedPercussionFrameCount(
        for pattern: MusicPercussionPattern,
        samplesPerStep: Int,
        sampleRate: Int,
        drumKit: DrumSampleKit
    ) -> Int {
        let kickTail = maxTailFrameCount(
            for: pattern.kickHits,
            samplesPerStep: samplesPerStep,
            sampleLength: drumKit.kick?.frameCount ?? fallbackFrameCount(for: .kick, sampleRate: sampleRate)
        )
        let snareTail = maxTailFrameCount(
            for: pattern.snareHits,
            samplesPerStep: samplesPerStep,
            sampleLength: drumKit.snare?.frameCount ?? fallbackFrameCount(for: .snare, sampleRate: sampleRate)
        )
        let closedHatTail = maxTailFrameCount(
            for: pattern.closedHatHits,
            samplesPerStep: samplesPerStep,
            sampleLength: drumKit.closedHat?.frameCount ?? fallbackFrameCount(for: .closedHat, sampleRate: sampleRate)
        )
        let openHatTail = maxTailFrameCount(
            for: pattern.openHatHits,
            samplesPerStep: samplesPerStep,
            sampleLength: drumKit.openHat?.frameCount ?? 0
        )
        let rimTail = maxRimTailFrameCount(
            for: pattern.rimHits,
            samplesPerStep: samplesPerStep,
            drumKit: drumKit
        )
        return max(max(kickTail, snareTail), max(closedHatTail, max(openHatTail, rimTail)))
    }

    nonisolated private static func emptyRenderedAudio(frameCount: Int) -> RenderedJamAudio {
        RenderedJamAudio(
            left: [Float](repeating: 0, count: frameCount),
            right: [Float](repeating: 0, count: frameCount)
        )
    }

    nonisolated private static func resolvedKickFrames(
        from hits: [MusicPercussionHit],
        samplesPerStep: Int,
        frameCount: Int
    ) -> [Int] {
        Array(
            Set(
                hits.compactMap { hit in
                    guard (0..<MusicSequence.steps).contains(hit.step) else { return nil }
                    let frame = hit.step * samplesPerStep
                    return frame < frameCount ? frame : nil
                }
            )
        )
        .sorted()
    }

    nonisolated private static func millisecondsToSamples(_ milliseconds: Double, sampleRate: Int) -> Int {
        max(1, Int((milliseconds / 1_000.0 * Double(sampleRate)).rounded()))
    }

    nonisolated private static func applyKickDucking(
        to samples: inout RenderedJamAudio,
        kickFrames: [Int],
        minimumGain: Float,
        releaseSamples: Int
    ) throws {
        guard samples.left.count == samples.right.count, !samples.left.isEmpty else { return }

        var gainEnvelope = Array(repeating: Float(1), count: samples.left.count)

        for kickFrame in kickFrames {
            try Task.checkCancellation()

            for offset in 0..<releaseSamples {
                let frame = kickFrame + offset

                guard frame < gainEnvelope.count else {
                    break
                }

                let progress = Float(offset) / Float(max(releaseSamples - 1, 1))
                let easedProgress = 1 - pow(1 - progress, 2)
                let gain = minimumGain + (1 - minimumGain) * easedProgress
                gainEnvelope[frame] = min(gainEnvelope[frame], gain)
            }
        }

        for index in gainEnvelope.indices {
            samples.left[index] *= gainEnvelope[index]
            samples.right[index] *= gainEnvelope[index]
        }
    }

    nonisolated private static func maxTailFrameCount(
        for hits: [MusicPercussionHit],
        samplesPerStep: Int,
        sampleLength: Int
    ) -> Int {
        guard sampleLength > 0 else { return 0 }
        return hits.reduce(0) { currentMax, hit in
            guard (0..<MusicSequence.steps).contains(hit.step) else { return currentMax }
            return max(currentMax, hit.step * samplesPerStep + sampleLength)
        }
    }

    nonisolated private static func maxRimTailFrameCount(
        for hits: [MusicRimHit],
        samplesPerStep: Int,
        drumKit: DrumSampleKit
    ) -> Int {
        hits.reduce(0) { currentMax, hit in
            guard (0..<MusicSequence.steps).contains(hit.step),
                  let sample = rimSample(for: hit.style, drumKit: drumKit) else {
                return currentMax
            }
            return max(currentMax, hit.step * samplesPerStep + sample.frameCount)
        }
    }

    nonisolated private static func fallbackFrameCount(for voice: DrumVoice, sampleRate: Int) -> Int {
        switch voice {
        case .kick:
            max(1, Int((0.24 * Double(sampleRate)).rounded()))
        case .snare:
            max(1, Int((0.16 * Double(sampleRate)).rounded()))
        case .closedHat:
            max(1, Int((0.05 * Double(sampleRate)).rounded()))
        }
    }

    nonisolated private static func mix(
        sample: DrumSample,
        gain: Float,
        startFrame: Int,
        into output: inout RenderedJamAudio,
        loops: Bool
    ) {
        guard !output.left.isEmpty else { return }
        let loopFrameCount = output.left.count

        for sampleFrame in 0..<sample.frameCount {
            let destinationFrame: Int
            if loops {
                destinationFrame = (startFrame + sampleFrame) % loopFrameCount
            } else {
                destinationFrame = startFrame + sampleFrame
                guard destinationFrame < loopFrameCount else { break }
            }

            output.left[destinationFrame] += sample.leftChannel[sampleFrame] * gain

            let rightSource = sample.rightChannel?[sampleFrame] ?? sample.leftChannel[sampleFrame]
            output.right[destinationFrame] += rightSource * gain
        }
    }

    nonisolated private static func renderOpenHatLayer(
        hits: [MusicPercussionHit],
        closedHatHits: [MusicPercussionHit],
        sample: DrumSample,
        gain: Float,
        samplesPerStep: Int,
        sampleRate: Int,
        loops: Bool,
        frameCount: Int
    ) throws -> RenderedJamAudio {
        var voices: [OpenHatVoice] = []

        for hit in hits where (0..<MusicSequence.steps).contains(hit.step) {
            try Task.checkCancellation()

            var voice = OpenHatVoice(
                audio: RenderedJamAudio(
                    left: [Float](repeating: 0, count: frameCount),
                    right: [Float](repeating: 0, count: frameCount)
                ),
                startFrame: hit.step * samplesPerStep,
                frameCount: sample.frameCount
            )
            mix(
                sample: sample,
                gain: gain * hit.velocity,
                startFrame: voice.startFrame,
                into: &voice.audio,
                loops: loops
            )
            voices.append(voice)
        }

        let fadeLength = max(1, Int((0.005 * Double(sampleRate)).rounded()))

        for closedHit in closedHatHits where (0..<MusicSequence.steps).contains(closedHit.step) {
            try Task.checkCancellation()

            let closedStartFrame = closedHit.step * samplesPerStep
            for index in voices.indices {
                choke(
                    openHatVoice: &voices[index],
                    at: closedStartFrame,
                    fadeLength: fadeLength,
                    loops: loops,
                    loopFrameCount: frameCount
                )
            }
        }

        var layer = RenderedJamAudio(
            left: [Float](repeating: 0, count: frameCount),
            right: [Float](repeating: 0, count: frameCount)
        )

        for voice in voices {
            try Task.checkCancellation()
            mix(layer: voice.audio, into: &layer)
        }

        return layer
    }

    nonisolated private static func choke(
        openHatVoice: inout OpenHatVoice,
        at closedStartFrame: Int,
        fadeLength: Int,
        loops: Bool,
        loopFrameCount: Int
    ) {
        let interruptionOffset: Int?
        if loops {
            let distance = (closedStartFrame - openHatVoice.startFrame + loopFrameCount) % loopFrameCount
            interruptionOffset = distance < openHatVoice.frameCount ? distance : nil
        } else {
            let distance = closedStartFrame - openHatVoice.startFrame
            interruptionOffset = (distance > 0 && distance < openHatVoice.frameCount) ? distance : nil
        }

        guard let interruptionOffset else { return }

        let fadeEnd = min(openHatVoice.frameCount, interruptionOffset + fadeLength)
        guard fadeEnd > interruptionOffset else { return }

        for sampleFrame in interruptionOffset..<fadeEnd {
            let fadeProgress = Float(sampleFrame - interruptionOffset) / Float(max(1, fadeEnd - interruptionOffset))
            let gain = max(0, 1 - fadeProgress)
            let destinationFrame = loops
                ? (openHatVoice.startFrame + sampleFrame) % loopFrameCount
                : (openHatVoice.startFrame + sampleFrame)
            guard destinationFrame < openHatVoice.audio.left.count else { break }
            openHatVoice.audio.left[destinationFrame] *= gain
            openHatVoice.audio.right[destinationFrame] *= gain
        }

        if fadeEnd < openHatVoice.frameCount {
            for sampleFrame in fadeEnd..<openHatVoice.frameCount {
                let destinationFrame = loops
                    ? (openHatVoice.startFrame + sampleFrame) % loopFrameCount
                    : (openHatVoice.startFrame + sampleFrame)
                guard destinationFrame < openHatVoice.audio.left.count else { break }
                openHatVoice.audio.left[destinationFrame] = 0
                openHatVoice.audio.right[destinationFrame] = 0
            }
        }
    }

    nonisolated private static func mix(layer: RenderedJamAudio, into output: inout RenderedJamAudio) {
        guard layer.left.count == output.left.count, layer.right.count == output.right.count else { return }
        for index in output.left.indices {
            output.left[index] += layer.left[index]
            output.right[index] += layer.right[index]
        }
    }

    nonisolated private static func trimTrailingSilence(
        in output: inout RenderedJamAudio,
        minimumFrameCount: Int
    ) {
        var lastAudibleFrame = minimumFrameCount
        for index in stride(from: output.left.count - 1, through: minimumFrameCount, by: -1) {
            if output.left[index] != 0 || output.right[index] != 0 {
                lastAudibleFrame = index + 1
                break
            }
        }

        guard lastAudibleFrame < output.left.count else { return }
        output.left.removeLast(output.left.count - lastAudibleFrame)
        output.right.removeLast(output.right.count - lastAudibleFrame)
    }

    nonisolated private static func rimSample(for style: MusicRimStyle, drumKit: DrumSampleKit) -> DrumSample? {
        switch style {
        case .soft:
            drumKit.rimSoft
        case .main:
            drumKit.rimMain
        case .hard:
            drumKit.rimHard
        }
    }

    nonisolated private static func rimGain(for style: MusicRimStyle) -> Float {
        switch style {
        case .soft:
            rimSoftGain
        case .main:
            rimMainGain
        case .hard:
            rimHardGain
        }
    }

    nonisolated private static func byStep(_ lhs: MusicPercussionHit, _ rhs: MusicPercussionHit) -> Bool {
        lhs.step < rhs.step
    }

    nonisolated private static func byRimStep(_ lhs: MusicRimHit, _ rhs: MusicRimHit) -> Bool {
        lhs.step < rhs.step
    }

    nonisolated private static func renderKick(
        step: Int,
        velocity: Float,
        into output: inout RenderedJamAudio,
        samplesPerStep: Int,
        sampleRate: Int,
        loops: Bool
    ) {
        guard (0..<MusicSequence.steps).contains(step), !output.left.isEmpty else { return }

        let startSample = step * samplesPerStep
        let durationSamples = fallbackFrameCount(for: .kick, sampleRate: sampleRate)
        var phase = 0.0
        let loopFrameCount = output.left.count

        for localSample in 0..<durationSamples {
            let index: Int
            if loops {
                index = (startSample + localSample) % loopFrameCount
            } else {
                index = startSample + localSample
                guard index < loopFrameCount else { break }
            }

            let progress = Double(localSample) / Double(durationSamples)
            let frequency = 120.0 * pow(48.0 / 120.0, progress)
            phase += 2.0 * Double.pi * frequency / Double(sampleRate)

            let envelope = exp(-8.0 * progress)
            let sample = Float(sin(phase) * envelope * Double(kickGain * velocity) * 0.16)
            output.left[index] += sample
            output.right[index] += sample
        }
    }

    nonisolated private static func renderSnare(
        step: Int,
        velocity: Float,
        into output: inout RenderedJamAudio,
        samplesPerStep: Int,
        sampleRate: Int,
        loops: Bool
    ) {
        guard (0..<MusicSequence.steps).contains(step), !output.left.isEmpty else { return }

        let startSample = step * samplesPerStep
        let durationSamples = fallbackFrameCount(for: .snare, sampleRate: sampleRate)
        let seed: UInt32 = 0x5A17E
        let loopFrameCount = output.left.count

        for localSample in 0..<durationSamples {
            let sourceIndex = startSample + localSample
            let index: Int
            if loops {
                index = sourceIndex % loopFrameCount
            } else {
                index = sourceIndex
                guard index < loopFrameCount else { break }
            }

            let progress = Double(localSample) / Double(durationSamples)
            let envelope = exp(-12.0 * progress)
            let sample = deterministicNoise(sampleIndex: sourceIndex, seed: seed) * Float(envelope * Double(snareGain * velocity) * 0.075)
            output.left[index] += sample
            output.right[index] += sample
        }
    }

    nonisolated private static func renderClosedHat(
        step: Int,
        velocity: Float,
        into output: inout RenderedJamAudio,
        samplesPerStep: Int,
        sampleRate: Int,
        loops: Bool
    ) {
        guard (0..<MusicSequence.steps).contains(step), !output.left.isEmpty else { return }

        let startSample = step * samplesPerStep
        let durationSamples = fallbackFrameCount(for: .closedHat, sampleRate: sampleRate)
        let seed: UInt32 = 0xC105ED
        let loopFrameCount = output.left.count

        for localSample in 0..<durationSamples {
            let sourceIndex = startSample + localSample
            let index: Int
            if loops {
                index = sourceIndex % loopFrameCount
            } else {
                index = sourceIndex
                guard index < loopFrameCount else { break }
            }

            let currentNoise = deterministicNoise(sampleIndex: sourceIndex, seed: seed)
            let previousNoise: Float
            if localSample == 0 {
                previousNoise = 0
            } else {
                previousNoise = deterministicNoise(sampleIndex: sourceIndex - 1, seed: seed)
            }

            let progress = Double(localSample) / Double(durationSamples)
            let envelope = exp(-35.0 * progress)
            let sample = (currentNoise - previousNoise) * Float(envelope * Double(closedHatGain * velocity) * 0.028)
            output.left[index] += sample
            output.right[index] += sample
        }
    }

    nonisolated private static func renderProceduralNote(
        _ note: MusicNote,
        into output: inout RenderedJamAudio,
        wave: [Float],
        envelope: [Float],
        samplesPerStep: Int,
        tonalFrameCount: Int,
        sampleRate: Int
    ) {
        let frequency = 440.0 * pow(2, Double(note.midiNote - 69) / 12)
        let phaseIncrement = frequency * Double(wave.count) / Double(sampleRate)

        for sampleOffset in 0..<envelope.count {
            let frameIndex = note.step * samplesPerStep + sampleOffset
            guard frameIndex < tonalFrameCount else { continue }

            let phaseIndex = Int(Double(sampleOffset) * phaseIncrement) % wave.count
            let sample = wave[phaseIndex] * envelope[sampleOffset] * note.velocity * tonalGain
            output.left[frameIndex] += sample
            output.right[frameIndex] += sample
        }
    }

    nonisolated private static func renderSampleBasedNote(
        _ note: MusicNote,
        role: MusicVoiceRole,
        allNotes: [MusicNote],
        into output: inout RenderedJamAudio,
        samplesPerStep: Int,
        gateSamples: Int,
        sampleRate: Int,
        loops: Bool
    ) -> Bool {
        guard role != .bass else { return false }
        guard let resolvedSample = MelodicSampleLibrary.resolvedSample(for: role, midiNote: note.midiNote) else {
            return false
        }

        let sample = resolvedSample.sample
        let ratio = playbackRatio(
            targetMIDINote: resolvedSample.targetMIDINote,
            rootMIDINote: sample.rootMIDINote,
            sourceSampleRate: sample.sampleRate,
            outputSampleRate: Double(sampleRate)
        )
        guard ratio > 0 else { return false }

        let roleGain = melodicRoleGain(for: role)
        let startFrame = note.step * samplesPerStep
        let endFrame = effectiveMelodicEndFrame(
            for: note,
            role: role,
            allNotes: allNotes,
            samplesPerStep: samplesPerStep,
            gateSamples: gateSamples
        )
        let fadeFrameCount = fadeFrameCount(for: role, sampleRate: sampleRate)
        let fadeStartOffset = max(0, endFrame - startFrame)
        let loopFrameCount = output.left.count

        var localFrame = 0
        while true {
            let sourcePosition = Double(localFrame) * ratio
            let sampleIndex = Int(sourcePosition)
            guard sampleIndex < sample.frameCount else { break }

            let destinationFrame: Int
            if loops {
                destinationFrame = (startFrame + localFrame) % loopFrameCount
            } else {
                destinationFrame = startFrame + localFrame
                guard destinationFrame < loopFrameCount else { break }
            }

            if localFrame >= fadeStartOffset + fadeFrameCount {
                break
            }

            let sampleValue = interpolatedSampleValue(in: sample.samples, at: sourcePosition)
            var gain = roleGain * note.velocity

            if localFrame >= fadeStartOffset {
                let fadeProgress = Float(localFrame - fadeStartOffset) / Float(max(1, fadeFrameCount))
                gain *= max(0, 1 - fadeProgress)
            }

            let renderedSample = sampleValue * gain
            output.left[destinationFrame] += renderedSample
            output.right[destinationFrame] += renderedSample
            localFrame += 1
        }

        return true
    }

    nonisolated private static func playbackRatio(
        targetMIDINote: Int,
        rootMIDINote: Int,
        sourceSampleRate: Double,
        outputSampleRate: Double
    ) -> Double {
        let pitchRatio = pow(2.0, Double(targetMIDINote - rootMIDINote) / 12.0)
        return pitchRatio * (sourceSampleRate / outputSampleRate)
    }

    nonisolated private static func renderedSampleFrameCount(sample: MelodicSample, ratio: Double) -> Int {
        guard ratio > 0, sample.frameCount > 1 else { return sample.frameCount }
        return max(1, Int(ceil(Double(sample.frameCount - 1) / ratio)))
    }

    nonisolated private static func effectiveMelodicEndFrame(
        for note: MusicNote,
        role: MusicVoiceRole,
        allNotes: [MusicNote],
        samplesPerStep: Int,
        gateSamples: Int
    ) -> Int {
        let noteStartFrame = note.step * samplesPerStep

        if role == .harmony {
            let harmonyMinimumGate = Int(Double(samplesPerStep) * 0.75)
            let harmonyTargetGate = max(gateSamples, harmonyMinimumGate)
            let nextHarmonyStartFrame = allNotes
                .first(where: { candidate in
                    candidate.voiceRole == .harmony && candidate.step > note.step
                })
                .map({ $0.step * samplesPerStep })

            let noteEndFrame = noteStartFrame + harmonyTargetGate
            return nextHarmonyStartFrame.map { min(noteEndFrame, $0) } ?? noteEndFrame
        }

        let noteEndFrame = noteStartFrame + gateSamples

        guard role == .bass,
              let nextBassStartFrame = allNotes
                .first(where: { candidate in
                    candidate.voiceRole == .bass &&
                    (candidate.step > note.step ||
                     (candidate.step == note.step && candidate.midiNote != note.midiNote))
                })
                .map({ $0.step * samplesPerStep }) else {
            return noteEndFrame
        }

        return min(noteEndFrame, nextBassStartFrame)
    }

    nonisolated private static func fadeFrameCount(for role: MusicVoiceRole, sampleRate: Int) -> Int {
        let milliseconds: Double
        switch role {
        case .bass:
            milliseconds = MelodicVoiceFade.bassMilliseconds
        case .harmony:
            milliseconds = MelodicVoiceFade.harmonyMilliseconds
        case .melody:
            milliseconds = MelodicVoiceFade.melodyMilliseconds
        }

        return max(1, Int((milliseconds / 1_000.0 * Double(sampleRate)).rounded()))
    }

    nonisolated private static func melodicRoleGain(for role: MusicVoiceRole) -> Float {
        switch role {
        case .bass:
            0.70
        case .harmony:
            0.44
        case .melody:
            0.50
        }
    }

    nonisolated private static func interpolatedSampleValue(in samples: [Float], at position: Double) -> Float {
        let lowerIndex = Int(position)
        guard lowerIndex < samples.count else { return 0 }
        let upperIndex = min(samples.count - 1, lowerIndex + 1)
        let fraction = Float(position - Double(lowerIndex))
        return samples[lowerIndex] * (1 - fraction) + samples[upperIndex] * fraction
    }

    nonisolated private static func clamp(_ samples: inout [Float]) {
        for index in samples.indices {
            samples[index] = max(-0.92, min(0.92, samples[index]))
        }
    }

    nonisolated private static func deterministicNoise(sampleIndex: Int, seed: UInt32) -> Float {
        var value = UInt32(truncatingIfNeeded: sampleIndex) &+ seed
        value ^= value >> 16
        value = value &* 0x7FEB352D
        value ^= value >> 15
        value = value &* 0x846CA68B
        value ^= value >> 16

        let normalized = Double(value) / Double(UInt32.max)
        return Float(normalized * 2.0 - 1.0)
    }

    nonisolated private static func waveformTable(_ waveform: MusicWaveform, size: Int) -> [Float] {
        switch waveform {
        case .square:   (0..<size).map { $0 < size / 2 ? 1 : -1 }
        case .triangle: (0..<size).map { Float(1 - 4 * abs(Double($0) / Double(size) - 0.5)) }
        }
    }

    nonisolated private static func byNoteOrder(_ lhs: MusicNote, _ rhs: MusicNote) -> Bool {
        if lhs.step != rhs.step { return lhs.step < rhs.step }
        if lhs.row != rhs.row { return lhs.row < rhs.row }
        return lhs.midiNote < rhs.midiNote
    }

    nonisolated private static func envelopeTable(length: Int) -> [Float] {
        let attack = max(1, Int(Double(length) * 0.08))
        let decay = max(1, Int(Double(length) * 0.16))
        let release = max(1, Int(Double(length) * 0.22))
        return (0..<length).map { i in
            if i < attack { return Float(i) / Float(attack) }
            if i < attack + decay { return 1 - Float(i - attack) / Float(decay) * 0.35 }
            if i >= length - release { return 0.65 * (1 - Float(i - (length - release)) / Float(release)) }
            return 0.65
        }
    }
}
