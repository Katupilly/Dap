import AVFoundation
import Foundation

// MARK: - MusicPlayer

/// Plays one MusicSequence at a time using AVAudioEngine + AVAudioPlayerNode.
/// - Sequence rendering runs off-main in Task.detached.
/// - Buffer creation and scheduling happen on MainActor after the await.
/// - playbackGeneration guards against stale render completions.
@MainActor
final class MusicPlayer {

    private struct RenderedAudio {
        var left: [Float]
        var right: [Float]
    }

    private struct OpenHatVoice {
        var audio: RenderedAudio
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

    // MARK: AVAudio graph (permanent — engine is started lazily and stays running)

    private let engine     = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let format     = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!

    // MARK: Jam effect chain (dedicated to transient Jam playback)

    private let jamPlayerNode      = AVAudioPlayerNode()
    private let jamReverbUnit      = AVAudioUnitReverb()
    private let jamDelayUnit       = AVAudioUnitDelay()
    private let jamLFOMixer        = AVAudioMixerNode()
    private var currentJamSettings = JamEffectSettings.default
    private var currentJamBPM:     Double = 96.0
    private var jamLFOPhase:       Double = 0
    private var jamLFOTask:        Task<Void, Never>?

    // MARK: Playback state

    private var renderTask:        Task<Void, Never>?
    private var pendingLoopTask:   Task<Void, Never>?
    private var playbackGeneration = 0
    private var isLooping = false

    /// Called when playback ends naturally or is interrupted.
    /// NOT called when stop() is invoked directly by the ViewModel.
    var onPlaybackFinished: (() -> Void)?

    /// Called after a loop update has been scheduled for the next loop boundary.
    var onLoopUpdatePrepared: (() -> Void)?

    // MARK: Init / deinit

    init() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)

        // Jam effect chain: player -> LFO mixer -> delay -> reverb -> main mixer
        engine.attach(jamPlayerNode)
        engine.attach(jamLFOMixer)
        engine.attach(jamDelayUnit)
        engine.attach(jamReverbUnit)

        jamReverbUnit.loadFactoryPreset(.mediumHall)
        jamReverbUnit.wetDryMix = 0
        jamDelayUnit.feedback   = 35
        jamDelayUnit.lowPassCutoff = 12_000
        jamDelayUnit.wetDryMix  = 0
        jamDelayUnit.delayTime  = 0.30
        jamLFOMixer.outputVolume = 1.0

        engine.connect(jamPlayerNode, to: jamLFOMixer, format: format)
        engine.connect(jamLFOMixer,  to: jamDelayUnit, format: format)
        engine.connect(jamDelayUnit, to: jamReverbUnit, format: format)
        engine.connect(jamReverbUnit, to: engine.mainMixerNode, format: format)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }

    deinit {
        jamLFOTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Public API

    /// Stops current playback (if any) and starts a new render+play cycle.
    func play(sequence: MusicSequence, percussion: MusicPercussionPattern? = nil, loops: Bool = false) {
        if loops, isLooping, playerNode.isPlaying {
            scheduleLoopUpdate(sequence: sequence, percussion: percussion)
            return
        }

        stop()

        // Activate audio session and start engine if needed.
        guard startEngineIfNeeded() else {
            return  // Audio unavailable — fail silently for this slice.
        }

        let generation = playbackGeneration  // Capture before Task.

        // Task inherits @MainActor from creation context:
        // body runs on MainActor, hops off-main for the detached render, comes back.
        renderTask = Task { [weak self] in
            // Render samples on a detached task (off MainActor, off main thread).
            let samples = await Task.detached(priority: .userInitiated) {
                MusicPlayer.renderSequence(sequence, percussion: percussion, sampleRate: 44_100, loops: loops)
            }.value

            guard let self, !Task.isCancelled,
                  self.playbackGeneration == generation else { return }

            // Buffer creation on MainActor.
            guard let buffer = self.makeBuffer(samples: samples) else {
                self.isLooping = false
                return
            }

            if loops {
                self.playerNode.scheduleBuffer(
                    buffer,
                    at: nil,
                    options: .loops,
                    completionHandler: nil
                )
                self.playerNode.play()
                self.isLooping = true
            } else {
                // Schedule with .dataPlayedBack so the callback fires after the audio is heard.
                self.playerNode.scheduleBuffer(
                    buffer,
                    completionCallbackType: .dataPlayedBack
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.playbackGeneration == generation else { return }
                        self.onPlaybackFinished?()
                    }
                }
                self.playerNode.play()
                self.isLooping = false
            }
        }
    }

    // MARK: - Jam playback (dedicated player + effect chain)

    /// Starts a new Jam playback on the dedicated Jam player + effect chain.
    /// Loop updates are scheduled at the next loop boundary using the same
    /// generation token strategy as the regular play path.
    func playJam(sequence: MusicSequence, percussion: MusicPercussionPattern? = nil) {
        stopJam()

        guard startEngineIfNeeded() else { return }

        let generation = playbackGeneration
        let settings = currentJamSettings
        let bpm = Double(sequence.harmony.bpm)
        currentJamBPM = bpm
        applyJamSettings(settings, bpm: bpm)

        renderTask = Task { [weak self] in
            let samples = await Task.detached(priority: .userInitiated) {
                MusicPlayer.renderSequence(sequence, percussion: percussion, sampleRate: 44_100, loops: true)
            }.value

            guard let self, !Task.isCancelled,
                  self.playbackGeneration == generation else { return }

            guard let buffer = self.makeBuffer(samples: samples) else { return }

            self.jamPlayerNode.scheduleBuffer(
                buffer,
                at: nil,
                options: .loops,
                completionHandler: nil
            )
            self.jamPlayerNode.play()
            self.isLooping = true
        }
    }

    /// Stops Jam playback, cancels the LFO task, and restores the LFO gain to 1.
    func stopJam() {
        jamLFOTask?.cancel()
        jamLFOTask = nil
        renderTask?.cancel()
        renderTask = nil
        playbackGeneration &+= 1
        isLooping = false
        if jamPlayerNode.isPlaying { jamPlayerNode.stop() }
        jamLFOMixer.outputVolume = 1.0
    }

    /// Schedules a Jam loop update at the next loop boundary using
    /// `.interruptsAtLoop`. Reapplies effect settings on the new BPM.
    func updateJamLoop(sequence: MusicSequence, percussion: MusicPercussionPattern?) {
        pendingLoopTask?.cancel()
        renderTask?.cancel()
        renderTask = nil
        playbackGeneration &+= 1
        let generation = playbackGeneration

        pendingLoopTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(135))

            guard let self,
                  !Task.isCancelled,
                  self.playbackGeneration == generation,
                  self.isLooping,
                  self.jamPlayerNode.isPlaying else { return }

            guard self.startEngineIfNeeded() else { return }

            let samples = await Task.detached(priority: .userInitiated) {
                MusicPlayer.renderSequence(sequence, percussion: percussion, sampleRate: 44_100, loops: true)
            }.value

            guard !Task.isCancelled,
                  self.playbackGeneration == generation,
                  self.isLooping,
                  self.jamPlayerNode.isPlaying else { return }

            guard let buffer = self.makeBuffer(samples: samples) else { return }

            // Update BPM from the incoming arrangement and reapply settings
            // (Delay time and LFO rate depend on the BPM of the new loop).
            let bpm = Double(sequence.harmony.bpm)
            self.currentJamBPM = bpm
            self.applyJamSettings(self.currentJamSettings, bpm: bpm)

            self.jamPlayerNode.scheduleBuffer(
                buffer,
                at: nil,
                options: [.loops, .interruptsAtLoop],
                completionHandler: nil
            )
            self.onLoopUpdatePrepared?()
            self.pendingLoopTask = nil
        }
    }

    /// Applies the current Jam effect settings, updates Delay time + LFO rate
    /// for the supplied BPM, and starts/cancels the LFO task as needed.
    /// Safe to call from playback context — no node attach/detach.
    func setJamEffects(_ settings: JamEffectSettings, bpm: Double) {
        currentJamSettings = settings
        currentJamBPM = bpm
        applyJamSettings(settings, bpm: bpm)
    }

    private func applyJamSettings(_ settings: JamEffectSettings, bpm: Double) {
        // Reverb bypass via wetDryMix = 0 when disabled.
        let reverbMix = settings.reverbEnabled
            ? min(max(settings.reverbMix, 0), 1) * 100
            : 0
        jamReverbUnit.wetDryMix = reverbMix

        // Delay: time depends on the BPM of the playing loop.
        let quarter = 60.0 / max(bpm, 1)
        let dottedEighth = quarter * 0.75
        let clamped = min(max(dottedEighth, 0.05), 2.0)
        jamDelayUnit.delayTime = clamped

        let delayMix = settings.delayEnabled
            ? min(max(settings.delayMix, 0), 1) * 100
            : 0
        jamDelayUnit.wetDryMix = delayMix

        // LFO: tremolo at half-note rate, amplitude scaled by amount.
        if settings.lfoEnabled {
            startOrUpdateLFO(amount: min(max(settings.lfoAmount, 0), 1), bpm: bpm)
        } else {
            cancelLFO()
        }
    }

    private func startOrUpdateLFO(amount: Float, bpm: Double) {
        // Recreate the task if BPM or amount changed materially to refresh the
        // capture values. Cheap: a 30 Hz Task, no buffer rebuild.
        let beatsPerSecond = bpm / 60.0
        let lfoFrequency = beatsPerSecond / 2.0
        let phaseIncrement = 2.0 * Double.pi * lfoFrequency / 30.0
        let amountClamped = min(max(amount, 0), 1)
        let minimumGain = 1.0 - Double(amountClamped) * 0.85

        // Cancel any existing task and start a fresh one.
        jamLFOTask?.cancel()
        jamLFOPhase = 0
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self else { return }
                self.jamLFOPhase += phaseIncrement
                if self.jamLFOPhase > 2.0 * Double.pi {
                    self.jamLFOPhase -= 2.0 * Double.pi
                }
                let normalizedSine = (sin(self.jamLFOPhase) + 1.0) / 2.0
                let gain = minimumGain + normalizedSine * (1.0 - minimumGain)
                self.jamLFOMixer.outputVolume = Float(min(max(gain, 0), 1))
            }
        }
        jamLFOTask = task
    }

    private func cancelLFO() {
        jamLFOTask?.cancel()
        jamLFOTask = nil
        jamLFOMixer.outputVolume = 1.0
    }

    /// Cancels the render task, invalidates the generation token, and stops the player node.
    func stop() {
        pendingLoopTask?.cancel()
        pendingLoopTask = nil
        renderTask?.cancel()
        renderTask = nil
        playbackGeneration &+= 1
        isLooping = false
        if playerNode.isPlaying { playerNode.stop() }
        // Also stop the Jam path and its LFO so a generic stop() clears both.
        jamLFOTask?.cancel()
        jamLFOTask = nil
        if jamPlayerNode.isPlaying { jamPlayerNode.stop() }
        jamLFOMixer.outputVolume = 1.0
    }

    // MARK: - Private helpers

    private func startEngineIfNeeded() -> Bool {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            if !engine.isRunning { try engine.start() }
            return true
        } catch {
            return false
        }
    }

    private func scheduleLoopUpdate(sequence: MusicSequence, percussion: MusicPercussionPattern?) {
        pendingLoopTask?.cancel()
        renderTask?.cancel()
        renderTask = nil
        playbackGeneration &+= 1
        let generation = playbackGeneration

        pendingLoopTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(135))

            guard let self,
                  !Task.isCancelled,
                  self.playbackGeneration == generation,
                  self.isLooping,
                  self.playerNode.isPlaying else { return }

            guard self.startEngineIfNeeded() else { return }

            let samples = await Task.detached(priority: .userInitiated) {
                MusicPlayer.renderSequence(sequence, percussion: percussion, sampleRate: 44_100, loops: true)
            }.value

            guard !Task.isCancelled,
                  self.playbackGeneration == generation,
                  self.isLooping,
                  self.playerNode.isPlaying else { return }

            guard let buffer = self.makeBuffer(samples: samples) else { return }

            guard self.playbackGeneration == generation,
                  self.isLooping,
                  self.playerNode.isPlaying else { return }

            self.playerNode.scheduleBuffer(
                buffer,
                at: nil,
                options: [.loops, .interruptsAtLoop],
                completionHandler: nil
            )
            self.onLoopUpdatePrepared?()
            self.pendingLoopTask = nil
        }
    }

    private func makeBuffer(samples: RenderedAudio) -> AVAudioPCMBuffer? {
        guard samples.left.count == samples.right.count else { return nil }

        let frameCount = AVAudioFrameCount(samples.left.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channelData = buffer.floatChannelData else { return nil }
        buffer.frameLength = frameCount
        for i in 0..<samples.left.count {
            channelData[0][i] = samples.left[i]
            channelData[1][i] = samples.right[i]
        }
        return buffer
    }

    // MARK: - Interruption handling

    @objc nonisolated private func handleAudioInterruption(_ notification: Notification) {
        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: typeValue) == .began else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.stop()
            self.onPlaybackFinished?()  // Treat interruption as natural end.
        }
    }

    // MARK: - Sequence rendering (called from Task.detached, nonisolated context)

    nonisolated private static func renderSequence(
        _ sequence: MusicSequence,
        percussion: MusicPercussionPattern?,
        sampleRate: Int,
        loops: Bool
    ) -> RenderedAudio {
        let bpm            = Double(sequence.harmony.bpm)
        let samplesPerStep = Int((60.0 / bpm / 4.0 * Double(sampleRate)).rounded())
        let gateSamples    = max(1, Int(Double(samplesPerStep) * sequence.soundProfile.gate))
        let wave           = waveformTable(sequence.soundProfile.waveform, size: 512)
        let envelope       = envelopeTable(length: gateSamples)
        let tonalFrameCount = samplesPerStep * MusicSequence.steps
        let sortedNotes = sequence.notes.sorted(by: byNoteOrder)
        let maximumMelodicFrameCount = maximumSampleBasedFrameCount(
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
        let frameCount     = loops ? tonalFrameCount : max(maximumMelodicFrameCount, maximumPercussionFrameCount)
        var output         = RenderedAudio(
            left: [Float](repeating: 0, count: frameCount),
            right: [Float](repeating: 0, count: frameCount)
        )
        var bassOutput = emptyRenderedAudio(frameCount: frameCount)
        var harmonyOutput = emptyRenderedAudio(frameCount: frameCount)
        let bassNotes = sortedNotes.filter { $0.voiceRole == .bass }
        let didRenderFutureBass = renderFutureBassLine(
            bassNotes,
            into: &bassOutput,
            samplesPerStep: samplesPerStep,
            gateSamples: gateSamples,
            sampleRate: sampleRate,
            loops: loops,
            tonalFrameCount: tonalFrameCount
        )
        let byStep         = Dictionary(grouping: sortedNotes, by: \.step)

        for step in 0..<MusicSequence.steps {
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
            applyKickDucking(
                to: &bassOutput,
                kickFrames: kickFrames,
                minimumGain: KickDucking.bassMinimumGain,
                releaseSamples: millisecondsToSamples(KickDucking.bassReleaseMilliseconds, sampleRate: sampleRate)
            )
            applyKickDucking(
                to: &harmonyOutput,
                kickFrames: kickFrames,
                minimumGain: KickDucking.harmonyMinimumGain,
                releaseSamples: millisecondsToSamples(KickDucking.harmonyReleaseMilliseconds, sampleRate: sampleRate)
            )
        }

        mix(layer: bassOutput, into: &output)
        mix(layer: harmonyOutput, into: &output)

        if let percussion {
            let drumKit = DrumSampleLibrary.kit(for: percussion.kit)
            renderPercussion(
                percussion,
                into: &output,
                samplesPerStep: samplesPerStep,
                sampleRate: sampleRate,
                loops: loops,
                drumKit: drumKit
            )
        }

        if !loops {
            trimTrailingSilence(in: &output, minimumFrameCount: tonalFrameCount)
        }

        clamp(&output.left)
        clamp(&output.right)
        return output
    }

    nonisolated private static func renderPercussion(
        _ pattern: MusicPercussionPattern,
        into output: inout RenderedAudio,
        samplesPerStep: Int,
        sampleRate: Int,
        loops: Bool,
        drumKit: DrumSampleKit
    ) {
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

        if let openHatSample = drumKit.openHat, !pattern.openHatHits.isEmpty {
            let openHatLayer = renderOpenHatLayer(
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
    ) -> Int {
        var maximumFrameCount = tonalFrameCount

        for note in notes {
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
        into output: inout RenderedAudio,
        samplesPerStep: Int,
        gateSamples: Int,
        sampleRate: Int,
        loops: Bool,
        tonalFrameCount: Int
    ) -> Bool {
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
        into output: inout RenderedAudio,
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

    nonisolated private static func emptyRenderedAudio(frameCount: Int) -> RenderedAudio {
        RenderedAudio(
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
        to samples: inout RenderedAudio,
        kickFrames: [Int],
        minimumGain: Float,
        releaseSamples: Int
    ) {
        guard samples.left.count == samples.right.count, !samples.left.isEmpty else { return }

        var gainEnvelope = Array(repeating: Float(1), count: samples.left.count)

        for kickFrame in kickFrames {
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
        into output: inout RenderedAudio,
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
    ) -> RenderedAudio {
        var voices: [OpenHatVoice] = []

        for hit in hits where (0..<MusicSequence.steps).contains(hit.step) {
            var voice = OpenHatVoice(
                audio: RenderedAudio(
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

        var layer = RenderedAudio(
            left: [Float](repeating: 0, count: frameCount),
            right: [Float](repeating: 0, count: frameCount)
        )

        for voice in voices {
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

    nonisolated private static func mix(layer: RenderedAudio, into output: inout RenderedAudio) {
        guard layer.left.count == output.left.count, layer.right.count == output.right.count else { return }
        for index in output.left.indices {
            output.left[index] += layer.left[index]
            output.right[index] += layer.right[index]
        }
    }

    nonisolated private static func trimTrailingSilence(
        in output: inout RenderedAudio,
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
        into output: inout RenderedAudio,
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
        into output: inout RenderedAudio,
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
        into output: inout RenderedAudio,
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
        into output: inout RenderedAudio,
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
        into output: inout RenderedAudio,
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
        let attack  = max(1, Int(Double(length) * 0.08))
        let decay   = max(1, Int(Double(length) * 0.16))
        let release = max(1, Int(Double(length) * 0.22))
        return (0..<length).map { i in
            if i < attack            { return Float(i) / Float(attack) }
            if i < attack + decay    { return 1 - Float(i - attack) / Float(decay) * 0.35 }
            if i >= length - release { return 0.65 * (1 - Float(i - (length - release)) / Float(release)) }
            return 0.65
        }
    }
}
