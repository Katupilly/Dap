import AVFoundation
import Foundation

// MARK: - MusicPlayer

/// Plays one MusicSequence at a time using AVAudioEngine + AVAudioPlayerNode.
/// - Sequence rendering runs off-main in Task.detached.
/// - Buffer creation and scheduling happen on MainActor after the await.
/// - playbackGeneration guards against stale render completions.
@MainActor
final class MusicPlayer {

    // MARK: AVAudio graph (permanent — engine is started lazily and stays running)

    private let engine     = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let format     = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!

    // MARK: Playback state

    private var renderTask:        Task<Void, Never>?
    private var playbackGeneration = 0

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
    func play(sequence: MusicSequence, loops: Bool = false) {
        stop()

        // Activate audio session and start engine if needed.
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            if !engine.isRunning { try engine.start() }
        } catch {
            return  // Audio unavailable — fail silently for this slice.
        }

        let generation = playbackGeneration  // Capture before Task.

        // Task inherits @MainActor from creation context:
        // body runs on MainActor, hops off-main for the detached render, comes back.
        renderTask = Task { [weak self] in
            // Render samples on a detached task (off MainActor, off main thread).
            let samples = await Task.detached(priority: .userInitiated) {
                MusicPlayer.renderSequence(sequence, sampleRate: 44_100)
            }.value

            guard let self, !Task.isCancelled,
                  self.playbackGeneration == generation else { return }

            // Buffer creation on MainActor.
            guard let buffer = self.makeBuffer(samples: samples) else { return }

            if loops {
                self.playerNode.scheduleBuffer(
                    buffer,
                    at: nil,
                    options: .loops,
                    completionHandler: nil
                )
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
            }

            self.playerNode.play()
        }
    }

    /// Cancels the render task, invalidates the generation token, and stops the player node.
    func stop() {
        renderTask?.cancel()
        renderTask = nil
        playbackGeneration &+= 1
        if playerNode.isPlaying { playerNode.stop() }
    }

    // MARK: - Private helpers

    private func makeBuffer(samples: [Float]) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channelData = buffer.floatChannelData else { return nil }
        buffer.frameLength = frameCount
        for i in 0..<samples.count {
            channelData[0][i] = samples[i]  // Left
            channelData[1][i] = samples[i]  // Right (mono source)
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

    nonisolated private static func renderSequence(_ sequence: MusicSequence, sampleRate: Int) -> [Float] {
        let bpm           = Double(sequence.harmony.bpm)
        let samplesPerStep = Int((60.0 / bpm / 4.0 * Double(sampleRate)).rounded())
        let gateSamples   = max(1, Int(Double(samplesPerStep) * sequence.soundProfile.gate))
        let wave          = waveformTable(sequence.soundProfile.waveform, size: 512)
        let envelope      = envelopeTable(length: gateSamples)
        var output        = [Float](repeating: 0, count: samplesPerStep * MusicSequence.steps)
        let byStep        = Dictionary(grouping: sequence.notes, by: \.step)

        for step in 0..<MusicSequence.steps {
            for note in byStep[step] ?? [] {
                let freq  = 440.0 * pow(2, Double(note.midiNote - 69) / 12)
                let phInc = freq * Double(wave.count) / Double(sampleRate)
                for s in 0..<gateSamples {
                    let ph = Int(Double(s) * phInc) % wave.count
                    output[step * samplesPerStep + s] += wave[ph] * envelope[s] * note.velocity * 0.16
                }
            }
        }
        return output.map { max(-0.92, min(0.92, $0)) }
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
