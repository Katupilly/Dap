import AVFoundation
import Foundation

struct MelodicSample: Sendable {
    let samples: [Float]
    let sampleRate: Double
    let rootMIDINote: Int

    var frameCount: Int {
        samples.count
    }
}

struct ResolvedMelodicSample: Sendable {
    let sample: MelodicSample
    let targetMIDINote: Int
}

enum MelodicSampleLibrary {
    private static let expectedSampleRate = 44_100.0
    private static let analogFamilyFolderName = "DapAnalogFamily"

    private static let bassSamples = [
        loadSample(at: "Bass/DapBass_C2.wav", rootMIDINote: 36),
        loadSample(at: "Bass/DapBass_C3.wav", rootMIDINote: 48),
        loadSample(at: "Bass/DapBass_C4.wav", rootMIDINote: 60)
    ].compactMap { $0 }

    private static let harmonySamples = [
        loadSample(at: "Harmony/DapHarmony_C3.wav", rootMIDINote: 48),
        loadSample(at: "Harmony/DapHarmony_C4.wav", rootMIDINote: 60),
        loadSample(at: "Harmony/DapHarmony_C5.wav", rootMIDINote: 72),
        loadSample(at: "Harmony/DapHarmony_C6.wav", rootMIDINote: 84)
    ].compactMap { $0 }

    private static let melodySamples = [
        loadSample(at: "Melody/DapMelody_C4.wav", rootMIDINote: 60),
        loadSample(at: "Melody/DapMelody_C5.wav", rootMIDINote: 72),
        loadSample(at: "Melody/DapMelody_C6.wav", rootMIDINote: 84),
        loadSample(at: "Melody/DapMelody_C7.wav", rootMIDINote: 96)
    ].compactMap { $0 }

    static func resolvedSample(for role: MusicVoiceRole, midiNote: Int) -> ResolvedMelodicSample? {
        let targetMIDINote = wrappedMIDINote(for: role, midiNote: midiNote)
        guard let sample = nearestLoadedSample(for: role, targetMIDINote: targetMIDINote) else {
            return nil
        }

        return ResolvedMelodicSample(sample: sample, targetMIDINote: targetMIDINote)
    }

    static func wrappedMIDINote(for role: MusicVoiceRole, midiNote: Int) -> Int {
        let range = playbackRange(for: role)
        var wrappedMIDINote = midiNote

        while wrappedMIDINote < range.lowerBound {
            wrappedMIDINote += 12
        }

        while wrappedMIDINote > range.upperBound {
            wrappedMIDINote -= 12
        }

        return min(range.upperBound, max(range.lowerBound, wrappedMIDINote))
    }

    static func playbackRange(for role: MusicVoiceRole) -> ClosedRange<Int> {
        switch role {
        case .bass:
            36...60
        case .harmony:
            48...84
        case .melody:
            60...96
        }
    }

    private static func nearestLoadedSample(for role: MusicVoiceRole, targetMIDINote: Int) -> MelodicSample? {
        let samples: [MelodicSample]
        switch role {
        case .bass:
            samples = bassSamples
        case .harmony:
            samples = harmonySamples
        case .melody:
            samples = melodySamples
        }

        return samples.min { lhs, rhs in
            let lhsDistance = abs(lhs.rootMIDINote - targetMIDINote)
            let rhsDistance = abs(rhs.rootMIDINote - targetMIDINote)
            if lhsDistance != rhsDistance {
                return lhsDistance < rhsDistance
            }
            return lhs.rootMIDINote < rhs.rootMIDINote
        }
    }

    private static func loadSample(at relativePath: String, rootMIDINote: Int) -> MelodicSample? {
        guard let resourceURL = Bundle.main.resourceURL else {
            return nil
        }

        let fileURL = resourceURL
            .appendingPathComponent(analogFamilyFolderName, isDirectory: true)
            .appendingPathComponent(relativePath)

        guard let audioFile = try? AVAudioFile(
            forReading: fileURL,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        ) else {
            return nil
        }

        let format = audioFile.processingFormat
        guard format.sampleRate == expectedSampleRate, format.channelCount == 1 else {
            return nil
        }

        let frameCapacity = AVAudioFrameCount(audioFile.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            return nil
        }

        do {
            try audioFile.read(into: buffer)
        } catch {
            return nil
        }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, let channelData = buffer.floatChannelData else {
            return nil
        }

        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        return MelodicSample(samples: samples, sampleRate: format.sampleRate, rootMIDINote: rootMIDINote)
    }
}
