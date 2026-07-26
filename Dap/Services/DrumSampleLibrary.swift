import AVFoundation
import Foundation

enum DrumSampleID: Sendable {
    case kick
    case snare
    case closedHat
    case openHat
    case rimMain
    case rimSoft
    case rimHard

    var relativePath: String {
        switch self {
        case .kick:
            "Kicks/Kick_Club.wav"
        case .snare:
            "Snares/Snare_909.wav"
        case .closedHat:
            "Hats/Closed/Hat_Closed_03.wav"
        case .openHat:
            "Hats/Open/Hat_Open_707.wav"
        case .rimMain:
            "Rimshots/Rim_Main.wav"
        case .rimSoft:
            "Rimshots/Rim_Soft.wav"
        case .rimHard:
            "Rimshots/Rim_Hard.wav"
        }
    }
}

struct DrumSample: Sendable {
    let leftChannel: [Float]
    let rightChannel: [Float]?

    var frameCount: Int {
        leftChannel.count
    }

    var channelCount: Int {
        rightChannel == nil ? 1 : 2
    }
}

struct DrumSampleKit: Sendable {
    let kick: DrumSample?
    let snare: DrumSample?
    let closedHat: DrumSample?
    let openHat: DrumSample?
    let rimMain: DrumSample?
    let rimSoft: DrumSample?
    let rimHard: DrumSample?
}

enum DrumSampleLibrary {
    private static let expectedSampleRate = 44_100.0
    private static let drumsFolderName = "Drums"
    private static let cachedDefaultKit = DrumSampleKit(
        kick: loadSample(.kick),
        snare: loadSample(.snare),
        closedHat: loadSample(.closedHat),
        openHat: loadSample(.openHat),
        rimMain: loadSample(.rimMain),
        rimSoft: loadSample(.rimSoft),
        rimHard: loadSample(.rimHard)
    )

    static func defaultKit() -> DrumSampleKit {
        cachedDefaultKit
    }

    private static func loadSample(_ id: DrumSampleID) -> DrumSample? {
        guard let resourceURL = Bundle.main.resourceURL else {
            return nil
        }

        let fileURL = resourceURL
            .appendingPathComponent(drumsFolderName, isDirectory: true)
            .appendingPathComponent(id.relativePath)

        guard let audioFile = try? AVAudioFile(
            forReading: fileURL,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        ) else {
            return nil
        }

        let format = audioFile.processingFormat
        guard format.sampleRate == expectedSampleRate else {
            return nil
        }

        guard (1...2).contains(Int(format.channelCount)) else {
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

        let leftChannel = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))

        if format.channelCount == 1 {
            return DrumSample(leftChannel: leftChannel, rightChannel: nil)
        }

        let rightChannel = Array(UnsafeBufferPointer(start: channelData[1], count: frameCount))
        return DrumSample(leftChannel: leftChannel, rightChannel: rightChannel)
    }
}
