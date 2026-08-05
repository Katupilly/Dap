import AVFoundation
import Darwin
import Foundation
import OSLog

#if DEBUG
private let musicPerformanceLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dap",
    category: "Performance"
)
#endif

private let musicPlaybackLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dap",
    category: "MusicPlayback"
)

// MARK: - MusicPlayer

/// Plays one MusicSequence at a time using AVAudioEngine + AVAudioPlayerNode.
/// - Sequence rendering runs off-main before buffer creation and scheduling return to MainActor.
/// - playbackGeneration guards against stale render completions.
@MainActor
final class MusicPlayer {

    private enum LoopPlaybackTarget {
        case playerNode
        case jamPlayerNode
    }

    private enum LoopRenderReadiness {
        case ready
        case waitingForStartup
        case invalid
    }

    private struct LoopRenderRequest {
        let sequence: MusicSequence
        let percussion: MusicPercussionPattern?
        let playbackGeneration: Int
        let requestGeneration: Int
        let target: LoopPlaybackTarget
    }

    // MARK: AVAudio graph (permanent — engine is started lazily and stays running)

    private let engine     = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let completionAccentNode = AVAudioPlayerNode()
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
    private var replacementRenderTask: Task<Void, Never>?
    private var pendingLoopRequest: LoopRenderRequest?
    private var replacementRenderToken = 0
    private var activeReplacementRenderToken: Int?
    private var loopRequestGeneration = 0
    private var playbackGeneration = 0
    private var isLooping = false
    private var completionAccentScheduledGeneration: Int?

    // MARK: Jam transport introspection
    //
    // The Jam transport state is computed from the live AVAudioPlayerNode
    // sample position. These cached values let the UI poll a read-only snapshot
    // without ever re-implementing the musical clock.
    //
    // `jamLoopFrameCount` is the exact PCM frame count of one 16-step Jam loop.
    // `jamFramesPerStep` derives from the BPM at scheduling time.
    // `jamIsTransportReady` is true only between a successful Play and a Stop
    // (or interruption); it gates the snapshot so the UI never invents a step.

    private var jamLoopFrameCount: Int = 0
    private var jamFramesPerStep: Int = 0
    private var jamIsTransportReady: Bool = false

    /// Read-only snapshot of the current Jam transport position.
    /// Derived exclusively from the AVAudioPlayerNode sample clock.
    struct JamTransportSnapshot {
        let currentStep: Int
        let loopProgress: Double
        let loopIteration: Int
    }

    /// Called when playback ends naturally or is interrupted.
    /// NOT called when stop() is invoked directly by the ViewModel.
    var onPlaybackFinished: (() -> Void)?

    /// Called after a loop update has been scheduled for the next loop boundary.
    var onLoopUpdatePrepared: (() -> Void)?

    // MARK: Init / deinit

    init() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        engine.attach(completionAccentNode)
        engine.connect(completionAccentNode, to: engine.mainMixerNode, format: format)

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
    func play(
        sequence: MusicSequence,
        percussion: MusicPercussionPattern? = nil,
        loops: Bool = false,
        completionAccent: Bool = false,
        onFinished: (@MainActor @Sendable () -> Void)? = nil
    ) {
        if loops, isLooping, playerNode.isPlaying {
            scheduleLoopUpdate(sequence: sequence, percussion: percussion)
            return
        }

        stop(origin: "MusicPlayer.play")

        // Activate audio session and start engine if needed.
        guard startEngineIfNeeded() else {
            return  // Audio unavailable — fail silently for this slice.
        }

        let generation = playbackGeneration  // Capture before Task.

        renderTask = Task { [weak self] in
            let samples: RenderedJamAudio
            let accentSamples: RenderedJamAudio?
            do {
                samples = try await Self.renderAudio(
                    sequence,
                    percussion: percussion,
                    sampleRate: 44_100,
                    loops: loops
                )
                if completionAccent && !loops {
                    do {
                        accentSamples = try JamAudioRenderer.renderCompletionAccent(
                            for: sequence,
                            sampleRate: 44_100
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        accentSamples = nil
                        #if DEBUG
                        musicPerformanceLogger.debug(
                            "completion accent render failed; preserving main sequence, error=\(String(describing: error), privacy: .public)"
                        )
                        #endif
                    }
                } else {
                    accentSamples = nil
                }
            } catch is CancellationError {
                return
            } catch {
                return
            }

            guard let self, !Task.isCancelled,
                  self.playbackGeneration == generation else { return }

            // Buffer creation on MainActor.
            guard let buffer = self.makeBuffer(samples: samples) else {
                self.isLooping = false
                return
            }

            if loops {
                self.scheduleLoopBuffer(
                    buffer,
                    on: self.playerNode,
                    options: .loops
                )
                guard !Task.isCancelled,
                      self.playbackGeneration == generation else {
                    self.playerNode.stop()
                    return
                }
                self.playerNode.play()
                self.isLooping = true
            } else {
                let accentBuffer = accentSamples.flatMap { self.makeBuffer(samples: $0) }
                let startHostTime: UInt64?
                if accentBuffer != nil {
                    startHostTime = mach_absolute_time()
                        &+ AVAudioTime.hostTime(forSeconds: 0.05)
                } else {
                    startHostTime = nil
                }

                let scheduleTime = startHostTime.map { AVAudioTime(hostTime: $0) }
                let accentScheduleTime: AVAudioTime?
                if let startHostTime, let accentBuffer {
                    let sequenceDuration = Double(buffer.frameLength) / self.format.sampleRate
                    let accentHostTime = startHostTime
                        &+ AVAudioTime.hostTime(forSeconds: sequenceDuration)
                    accentScheduleTime = AVAudioTime(hostTime: accentHostTime)
                    self.completionAccentScheduledGeneration = generation
                    self.completionAccentNode.scheduleBuffer(
                        accentBuffer,
                        at: accentScheduleTime,
                        options: [],
                        completionCallbackType: .dataPlayedBack
                    ) { [weak self] _ in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  self.playbackGeneration == generation else { return }
                            self.completionAccentScheduledGeneration = nil
                        }
                    }
                } else {
                    accentScheduleTime = nil
                }

                // Schedule with .dataPlayedBack so the callback fires after the audio is heard.
                self.playerNode.scheduleBuffer(
                    buffer,
                    at: scheduleTime,
                    options: [],
                    completionCallbackType: .dataPlayedBack
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.playbackGeneration == generation else { return }
                        self.onPlaybackFinished?()
                        onFinished?()
                    }
                }
                self.playerNode.play()
                if accentScheduleTime != nil {
                    self.completionAccentNode.play()
                }
                self.isLooping = false

                #if DEBUG
                musicPerformanceLogger.debug(
                    "sequence scheduled: bpm=\(sequence.harmony.bpm, privacy: .public), steps=\(MusicSequence.steps, privacy: .public), nominalDuration=\(sequence.nominalDuration, privacy: .public), renderedDuration=\(Double(buffer.frameLength) / self.format.sampleRate, privacy: .public), completionAccent=\(accentBuffer != nil, privacy: .public)"
                )
                #endif
            }

            self.renderTask = nil

            if loops, self.playbackGeneration == generation {
                self.processPendingLoopRequestIfNeeded()
            }
        }
    }

    // MARK: - Jam playback (dedicated player + effect chain)

    /// Starts a new Jam playback on the dedicated Jam player + effect chain.
    /// Loop updates are scheduled at the next loop boundary using the same
    /// generation token strategy as the regular play path.
    func playJam(
        sequence: MusicSequence,
        percussion: MusicPercussionPattern? = nil,
        onStarted: (@MainActor @Sendable () -> Void)? = nil,
        onFailed: (@MainActor @Sendable () -> Void)? = nil
    ) {
        stop(origin: "MusicPlayer.playJam")

        guard startEngineIfNeeded() else {
            onFailed?()
            return
        }

        let generation = playbackGeneration
        let settings = currentJamSettings
        let bpm = Double(sequence.harmony.bpm)
        currentJamBPM = bpm
        applyJamSettings(settings, bpm: bpm)

        // Compute transport metrics from the canonical 16-step Jam loop
        // contract (BPM and step count are stable for the current product).
        let framesPerStep = Int((60.0 / bpm / 4.0 * 44_100.0).rounded())
        let loopFrameCount = framesPerStep * MusicSequence.steps
        self.jamFramesPerStep = framesPerStep
        self.jamLoopFrameCount = loopFrameCount

        let percussionEventCount = (percussion?.kickHits.count ?? 0)
            + (percussion?.snareHits.count ?? 0)
            + (percussion?.openHatHits.count ?? 0)
            + (percussion?.closedHatHits.count ?? 0)
            + (percussion?.rimHits.count ?? 0)
        musicPlaybackLogger.notice(
            "jam requested: notes=\(sequence.notes.count, privacy: .public), percussionEvents=\(percussionEventCount, privacy: .public), bpm=\(sequence.harmony.bpm, privacy: .public), generation=\(generation, privacy: .public)"
        )

        renderTask = Task { [weak self] in
            let samples: RenderedJamAudio
            musicPlaybackLogger.debug(
                "jam render started: generation=\(generation, privacy: .public)"
            )
            do {
                samples = try await Self.renderAudio(
                    sequence,
                    percussion: percussion,
                    sampleRate: 44_100,
                    loops: true
                )
            } catch is CancellationError {
                musicPlaybackLogger.notice(
                    "jam render cancelled: generation=\(generation, privacy: .public), taskCancelled=\(Task.isCancelled, privacy: .public)"
                )
                return
            } catch {
                guard let self else { return }
                guard self.playbackGeneration == generation else {
                    musicPlaybackLogger.notice(
                        "jam render abandoned: generation mismatch expected=\(generation, privacy: .public), actual=\(self.playbackGeneration, privacy: .public)"
                    )
                    return
                }
                musicPlaybackLogger.error(
                    "jam render failed: generation=\(generation, privacy: .public), error=\(String(describing: error), privacy: .public)"
                )
                onFailed?()
                return
            }

            guard let self else { return }
            guard !Task.isCancelled else {
                musicPlaybackLogger.notice(
                    "jam render abandoned: task cancelled after render, generation=\(generation, privacy: .public)"
                )
                return
            }
            guard self.playbackGeneration == generation else {
                musicPlaybackLogger.notice(
                    "jam render abandoned: generation mismatch expected=\(generation, privacy: .public), actual=\(self.playbackGeneration, privacy: .public)"
                )
                return
            }

            guard let buffer = self.makeBuffer(samples: samples) else {
                musicPlaybackLogger.error(
                    "jam buffer creation failed: generation=\(generation, privacy: .public), renderedFrames=\(samples.left.count, privacy: .public)"
                )
                onFailed?()
                return
            }

            let peak = samples.left.reduce(0.0) { max($0, abs(Double($1))) }
            musicPlaybackLogger.debug(
                "jam render finished: generation=\(generation, privacy: .public), frames=\(buffer.frameLength, privacy: .public), peak=\(peak, privacy: .public)"
            )

            musicPlaybackLogger.debug(
                "jam buffer will schedule: generation=\(generation, privacy: .public)"
            )
            self.scheduleLoopBuffer(
                buffer,
                on: self.jamPlayerNode,
                options: .loops
            )
            musicPlaybackLogger.debug(
                "jam buffer scheduled synchronously: generation=\(generation, privacy: .public)"
            )
            guard !Task.isCancelled,
                  self.playbackGeneration == generation else {
                self.jamPlayerNode.stop()
                musicPlaybackLogger.notice(
                    "jam start abandoned after schedule: generation=\(generation, privacy: .public), taskCancelled=\(Task.isCancelled, privacy: .public), currentGeneration=\(self.playbackGeneration, privacy: .public)"
                )
                return
            }
            musicPlaybackLogger.debug(
                "jam player play called: generation=\(generation, privacy: .public)"
            )
            self.jamPlayerNode.play()
            self.isLooping = true
            self.jamIsTransportReady = self.jamPlayerNode.isPlaying
            self.renderTask = nil
            musicPlaybackLogger.debug(
                "jam player started: generation=\(generation, privacy: .public), nodePlaying=\(self.jamPlayerNode.isPlaying, privacy: .public), engineRunning=\(self.engine.isRunning, privacy: .public)"
            )
            if self.jamIsTransportReady {
                musicPlaybackLogger.debug(
                    "jam onStarted callback: generation=\(generation, privacy: .public)"
                )
                onStarted?()
            } else {
                musicPlaybackLogger.error(
                    "jam failed after play: generation=\(generation, privacy: .public), nodePlaying=false"
                )
                onFailed?()
            }
            self.processPendingLoopRequestIfNeeded()
        }
    }

    /// Stops Jam playback, cancels the LFO task, and restores the LFO gain to 1.
    func stopJam(origin: String = "MusicPlayer.stopJam") {
        let previousGeneration = playbackGeneration
        musicPlaybackLogger.notice(
            "stopJam origin=\(origin, privacy: .public), generation=\(previousGeneration, privacy: .public)"
        )
        jamLFOTask?.cancel()
        jamLFOTask = nil
        cancelAllRenderWork(origin: origin)
        playbackGeneration &+= 1
        musicPlaybackLogger.notice(
            "stopJam generation advanced: generation=\(self.playbackGeneration, privacy: .public)"
        )
        isLooping = false
        if jamPlayerNode.isPlaying { jamPlayerNode.stop() }
        jamLFOMixer.outputVolume = 1.0
        jamIsTransportReady = false
        jamLoopFrameCount = 0
        jamFramesPerStep = 0
    }

    /// Schedules a Jam loop update at the next loop boundary using
    /// `.interruptsAtLoop`. Reapplies effect settings on the new BPM.
    func updateJamLoop(sequence: MusicSequence, percussion: MusicPercussionPattern?) {
        enqueueLoopReplacement(
            sequence: sequence,
            percussion: percussion,
            target: .jamPlayerNode
        )
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
    func stop(origin: String = "MusicPlayer.stop") {
        let previousGeneration = playbackGeneration
        musicPlaybackLogger.notice(
            "stop origin=\(origin, privacy: .public), generation=\(previousGeneration, privacy: .public)"
        )
        cancelAllRenderWork(origin: origin)
        playbackGeneration &+= 1
        musicPlaybackLogger.notice(
            "stop generation advanced: generation=\(self.playbackGeneration, privacy: .public)"
        )
        isLooping = false
        if playerNode.isPlaying { playerNode.stop() }
        completionAccentNode.stop()
        completionAccentScheduledGeneration = nil
        // Also stop the Jam path and its LFO so a generic stop() clears both.
        jamLFOTask?.cancel()
        jamLFOTask = nil
        if jamPlayerNode.isPlaying { jamPlayerNode.stop() }
        jamLFOMixer.outputVolume = 1.0
        jamIsTransportReady = false
        jamLoopFrameCount = 0
        jamFramesPerStep = 0
    }

    // MARK: - Jam transport snapshot

    /// Returns the current Jam transport position derived from the live
    /// AVAudioPlayerNode sample clock. Returns `nil` if no valid Jam
    /// playback is active or the player has no rendered time yet.
    ///
    /// - Does not mutate state.
    /// - Does not start the engine.
    /// - Does not schedule buffers.
    /// - Is safe to call from a polling task on the main actor.
    func currentJamTransportSnapshot() -> JamTransportSnapshot? {
        guard jamIsTransportReady,
              isLooping,
              jamPlayerNode.isPlaying,
              jamLoopFrameCount > 0,
              jamFramesPerStep > 0 else {
            return nil
        }

        guard let nodeTime = jamPlayerNode.lastRenderTime,
              let playerTime = jamPlayerNode.playerTime(forNodeTime: nodeTime) else {
            return nil
        }

        // `playerTime.sampleTime` is an AVAudioFramePosition (Int64). It is
        // continuous across the `.interruptsAtLoop` swap because the same
        // engine clock keeps counting while buffers are exchanged.
        let rawSampleTime = playerTime.sampleTime
        guard rawSampleTime >= 0 else { return nil }

        let loopFrameCount = Int64(jamLoopFrameCount)
        let framesPerStep = Int64(jamFramesPerStep)
        guard loopFrameCount > 0, framesPerStep > 0 else { return nil }

        let positionInLoop = rawSampleTime % loopFrameCount
        let step = Int(positionInLoop / framesPerStep)
        let clampedStep = min(max(step, 0), MusicSequence.steps - 1)
        let progress = Double(positionInLoop) / Double(loopFrameCount)
        let iteration = Int(rawSampleTime / loopFrameCount)

        return JamTransportSnapshot(
            currentStep: clampedStep,
            loopProgress: progress,
            loopIteration: iteration
        )
    }

    // MARK: - Private helpers

    private func startEngineIfNeeded() -> Bool {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            if !engine.isRunning { try engine.start() }
            return true
        } catch {
            #if DEBUG
            musicPerformanceLogger.error(
                "audio engine start failed: error=\(String(describing: error), privacy: .public)"
            )
            #endif
            return false
        }
    }

    private func scheduleLoopUpdate(sequence: MusicSequence, percussion: MusicPercussionPattern?) {
        enqueueLoopReplacement(
            sequence: sequence,
            percussion: percussion,
            target: .playerNode
        )
    }

    private func makeBuffer(samples: RenderedJamAudio) -> AVAudioPCMBuffer? {
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

    private func scheduleLoopBuffer(
        _ buffer: AVAudioPCMBuffer,
        on node: AVAudioPlayerNode,
        options: AVAudioPlayerNodeBufferOptions
    ) {
        node.scheduleBuffer(buffer, at: nil, options: options, completionHandler: nil)
    }

    // MARK: - Interruption handling

    @objc nonisolated private func handleAudioInterruption(_ notification: Notification) {
        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: typeValue) == .began else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.stop(origin: "MusicPlayer.handleAudioInterruption")
            self.onPlaybackFinished?()  // Treat interruption as natural end.
        }
    }

    // MARK: - Sequence rendering

    nonisolated private static func renderAudio(
        _ sequence: MusicSequence,
        percussion: MusicPercussionPattern?,
        sampleRate: Int,
        loops: Bool
    ) async throws -> RenderedJamAudio {
        #if DEBUG
        let clock = ContinuousClock()
        let renderStart = clock.now
        defer {
            musicPerformanceLogger.debug(
                "audio render: \(String(describing: renderStart.duration(to: clock.now)), privacy: .public)"
            )
        }
        #endif
        try Task.checkCancellation()
        return try JamAudioRenderer.render(
            sequence,
            percussion: percussion,
            sampleRate: sampleRate,
            loops: loops
        )
    }

    private func enqueueLoopReplacement(
        sequence: MusicSequence,
        percussion: MusicPercussionPattern?,
        target: LoopPlaybackTarget
    ) {
        pendingLoopTask?.cancel()
        loopRequestGeneration &+= 1

        let request = LoopRenderRequest(
            sequence: sequence,
            percussion: percussion,
            playbackGeneration: playbackGeneration,
            requestGeneration: loopRequestGeneration,
            target: target
        )
        pendingLoopRequest = request
        replacementRenderTask?.cancel()

        pendingLoopTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(135))

            guard let self, !Task.isCancelled else { return }
            self.pendingLoopTask = nil
            self.processPendingLoopRequestIfNeeded()
        }
    }

    private func processPendingLoopRequestIfNeeded() {
        guard pendingLoopTask == nil,
              replacementRenderTask == nil,
              let request = pendingLoopRequest else { return }

        switch loopRenderReadiness(for: request.target) {
        case .ready:
            break
        case .waitingForStartup:
            return
        case .invalid:
            if pendingLoopRequest?.requestGeneration == request.requestGeneration {
                pendingLoopRequest = nil
            }
            return
        }

        guard playbackGeneration == request.playbackGeneration,
              startEngineIfNeeded() else {
            if pendingLoopRequest?.requestGeneration == request.requestGeneration {
                pendingLoopRequest = nil
            }
            return
        }

        replacementRenderToken &+= 1
        let token = replacementRenderToken
        activeReplacementRenderToken = token

        replacementRenderTask = Task { [weak self] in
            do {
                let samples = try await Self.renderAudio(
                    request.sequence,
                    percussion: request.percussion,
                    sampleRate: 44_100,
                    loops: true
                )
                guard let self else { return }
                self.finishLoopReplacement(
                    samples: samples,
                    request: request,
                    token: token
                )
            } catch is CancellationError {
                guard let self else { return }
                self.finishLoopReplacementCancellation(token: token)
            } catch {
                guard let self else { return }
                self.finishLoopReplacementCancellation(token: token)
            }
        }
    }

    private func finishLoopReplacement(
        samples: RenderedJamAudio,
        request: LoopRenderRequest,
        token: Int
    ) {
        guard activeReplacementRenderToken == token else { return }

        replacementRenderTask = nil
        activeReplacementRenderToken = nil

        guard pendingLoopRequest?.requestGeneration == request.requestGeneration else {
            processPendingLoopRequestIfNeeded()
            return
        }

        guard playbackGeneration == request.playbackGeneration else {
            pendingLoopRequest = nil
            processPendingLoopRequestIfNeeded()
            return
        }

        switch loopRenderReadiness(for: request.target) {
        case .ready:
            break
        case .waitingForStartup:
            processPendingLoopRequestIfNeeded()
            return
        case .invalid:
            pendingLoopRequest = nil
            return
        }

        guard let buffer = makeBuffer(samples: samples) else {
            pendingLoopRequest = nil
            return
        }

        switch request.target {
        case .playerNode:
            playerNode.scheduleBuffer(
                buffer,
                at: nil,
                options: [.loops, .interruptsAtLoop],
                completionHandler: nil
            )
        case .jamPlayerNode:
            let bpm = Double(request.sequence.harmony.bpm)
            currentJamBPM = bpm
            applyJamSettings(currentJamSettings, bpm: bpm)

            let framesPerStep = Int((60.0 / bpm / 4.0 * 44_100.0).rounded())
            let loopFrameCount = framesPerStep * MusicSequence.steps
            jamFramesPerStep = framesPerStep
            jamLoopFrameCount = loopFrameCount

            jamPlayerNode.scheduleBuffer(
                buffer,
                at: nil,
                options: [.loops, .interruptsAtLoop],
                completionHandler: nil
            )
        }

        pendingLoopRequest = nil
        onLoopUpdatePrepared?()
        processPendingLoopRequestIfNeeded()
    }

    private func finishLoopReplacementCancellation(token: Int) {
        guard activeReplacementRenderToken == token else { return }
        replacementRenderTask = nil
        activeReplacementRenderToken = nil
        processPendingLoopRequestIfNeeded()
    }

    private func loopRenderReadiness(for target: LoopPlaybackTarget) -> LoopRenderReadiness {
        switch target {
        case .playerNode:
            if isLooping, playerNode.isPlaying {
                return .ready
            }
        case .jamPlayerNode:
            if isLooping, jamPlayerNode.isPlaying {
                return .ready
            }
        }

        if renderTask != nil {
            return .waitingForStartup
        }

        return .invalid
    }

    private func cancelAllRenderWork(origin: String) {
        let hadRenderWork = pendingLoopTask != nil
            || replacementRenderTask != nil
            || renderTask != nil
        if hadRenderWork {
            musicPlaybackLogger.notice(
                "cancelAllRenderWork origin=\(origin, privacy: .public), generation=\(self.playbackGeneration, privacy: .public)"
            )
        }
        pendingLoopTask?.cancel()
        pendingLoopTask = nil
        pendingLoopRequest = nil
        replacementRenderTask?.cancel()
        replacementRenderTask = nil
        activeReplacementRenderToken = nil
        renderTask?.cancel()
        renderTask = nil
    }
}
