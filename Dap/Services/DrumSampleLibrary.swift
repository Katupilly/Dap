import AVFoundation
import Foundation

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
    let kickTrim: Float
    let snareTrim: Float
    let closedHatTrim: Float
    let openHatTrim: Float
}

enum DrumSampleLibrary {
    private static let expectedSampleRate = 44_100.0
    private static let drumsFolderName = "Drums"
    private enum SamplePath {
        static let kickSubD = "Kicks/Kick_Sub_D.wav"
        static let kickClub = "Kicks/Kick_Club.wav"
        static let kickPunchGSharp = "Kicks/Kick_Punch_GSharp.wav"
        static let snareDry = "Snares/Snare_Dry.wav"
        static let snare909 = "Snares/Snare_909.wav"
        static let snareBreak = "Snares/Snare_Break.wav"
        static let hatClosed01 = "Hats/Closed/Hat_Closed_01.wav"
        static let hatClosed02 = "Hats/Closed/Hat_Closed_02.wav"
        static let hatClosed03 = "Hats/Closed/Hat_Closed_03.wav"
        static let hatClosedMetallic = "Hats/Closed/Hat_Closed_Metallic.wav"
        static let hatOpen707 = "Hats/Open/Hat_Open_707.wav"
        static let hatOpenLong = "Hats/Open/Hat_Open_Long.wav"
        static let rimSoft = "Rimshots/Rim_Soft.wav"
        static let rimMain = "Rimshots/Rim_Main.wav"
        static let rimHard = "Rimshots/Rim_Hard.wav"
    }

    private static let kickSubD = loadSample(at: SamplePath.kickSubD)
    private static let kickClub = loadSample(at: SamplePath.kickClub)
    private static let kickPunchGSharp = loadSample(at: SamplePath.kickPunchGSharp)
    private static let snareDry = loadSample(at: SamplePath.snareDry)
    private static let snare909 = loadSample(at: SamplePath.snare909)
    private static let snareBreak = loadSample(at: SamplePath.snareBreak)
    private static let hatClosed01 = loadSample(at: SamplePath.hatClosed01)
    private static let hatClosed02 = loadSample(at: SamplePath.hatClosed02)
    private static let hatClosed03 = loadSample(at: SamplePath.hatClosed03)
    private static let hatClosedMetallic = loadSample(at: SamplePath.hatClosedMetallic)
    private static let hatOpen707 = loadSample(at: SamplePath.hatOpen707)
    private static let hatOpenLong = loadSample(at: SamplePath.hatOpenLong)
    private static let rimSoft = loadSample(at: SamplePath.rimSoft)
    private static let rimMain = loadSample(at: SamplePath.rimMain)
    private static let rimHard = loadSample(at: SamplePath.rimHard)

    private static let softKit = DrumSampleKit(
        kick: kickSubD,
        snare: snareDry,
        closedHat: hatClosed01,
        openHat: hatOpen707,
        rimMain: rimMain,
        rimSoft: rimSoft,
        rimHard: rimHard,
        kickTrim: 1.10,
        snareTrim: 0.69,
        closedHatTrim: 0.68,
        openHatTrim: 1.00
    )

    private static let clubKit = DrumSampleKit(
        kick: kickClub,
        snare: snare909,
        closedHat: hatClosed03,
        openHat: hatOpen707,
        rimMain: rimMain,
        rimSoft: rimSoft,
        rimHard: rimHard,
        kickTrim: 1.00,
        snareTrim: 1.00,
        closedHatTrim: 1.00,
        openHatTrim: 1.00
    )

    private static let breakbeatKit = DrumSampleKit(
        kick: kickSubD,
        snare: snareBreak,
        closedHat: hatClosed02,
        openHat: hatOpenLong,
        rimMain: rimMain,
        rimSoft: rimSoft,
        rimHard: rimHard,
        kickTrim: 1.10,
        snareTrim: 1.35,
        closedHatTrim: 0.68,
        openHatTrim: 1.06
    )

    private static let metalKit = DrumSampleKit(
        kick: kickPunchGSharp,
        snare: snareBreak,
        closedHat: hatClosedMetallic,
        openHat: hatOpenLong,
        rimMain: rimMain,
        rimSoft: rimSoft,
        rimHard: rimHard,
        kickTrim: 1.12,
        snareTrim: 1.35,
        closedHatTrim: 0.68,
        openHatTrim: 1.06
    )

    static func kit(for id: MusicDrumKit) -> DrumSampleKit {
        switch id {
        case .soft:
            softKit
        case .club:
            clubKit
        case .breakbeat:
            breakbeatKit
        case .metal:
            metalKit
        }
    }

    private static func loadSample(at relativePath: String) -> DrumSample? {
        guard let resourceURL = Bundle.main.resourceURL else {
            return nil
        }

        let fileURL = resourceURL
            .appendingPathComponent(drumsFolderName, isDirectory: true)
            .appendingPathComponent(relativePath)

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
