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

    // MARK: Playback state

    private var renderTask:        Task<Void, Never>?
    private var pendingLoopTask:   Task<Void, Never>?
    private var playbackGeneration = 0
    private var isLooping = false

    /// Called when playback ends naturally or is interrupted.
    /// NOT called when stop() is invoked directly by the ViewModel.
    var onPlaybackFinished: (() -> Void)?

    // MARK: Init / deinit

    init() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }

    deinit {
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

    /// Cancels the render task, invalidates the generation token, and stops the player node.
    func stop() {
        pendingLoopTask?.cancel()
        pendingLoopTask = nil
        renderTask?.cancel()
        renderTask = nil
        playbackGeneration &+= 1
        isLooping = false
        if playerNode.isPlaying { playerNode.stop() }
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
        let drumKit        = DrumSampleLibrary.defaultKit()
        let maximumPercussionFrameCount = percussion.map {
            reservedPercussionFrameCount(
                for: $0,
                samplesPerStep: samplesPerStep,
                sampleRate: sampleRate,
                drumKit: drumKit
            )
        } ?? 0
        let frameCount     = loops ? tonalFrameCount : max(tonalFrameCount, maximumPercussionFrameCount)
        var output         = RenderedAudio(
            left: [Float](repeating: 0, count: frameCount),
            right: [Float](repeating: 0, count: frameCount)
        )
        let byStep         = Dictionary(grouping: sequence.notes, by: \.step)

        for step in 0..<MusicSequence.steps {
            for note in byStep[step] ?? [] {
                let freq  = 440.0 * pow(2, Double(note.midiNote - 69) / 12)
                let phInc = freq * Double(wave.count) / Double(sampleRate)
                for s in 0..<gateSamples {
                    let index = step * samplesPerStep + s
                    guard index < tonalFrameCount else { continue }
                    let ph = Int(Double(s) * phInc) % wave.count
                    let sample = wave[ph] * envelope[s] * note.velocity * 0.16
                    output.left[index] += sample
                    output.right[index] += sample
                }
            }
        }

        if let percussion {
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
                    gain: kickGain * hit.velocity,
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
                    gain: snareGain * hit.velocity,
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
                    gain: closedHatGain * hit.velocity,
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
                gain: openHatGain * hit.velocity,
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
