import AVFoundation
import AudioToolbox
import CoreGraphics
import CoreVideo
import Foundation
import VideoToolbox

struct JamStoryVideoRenderResult: Sendable {
    let fileURL: URL
    let previewImageData: Data
    let duration: CMTime
    let pixelSize: CGSize
    let framesPerSecond: Int
}

enum JamStoryVideoExportError: Error, LocalizedError {
    case invalidSnapshot
    case writerCreationFailed
    case pixelBufferCreationFailed
    case frameRenderingFailed
    case audioRenderingFailed
    case compositionFailed
    case cancelled
    case finalFileMissing
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .invalidSnapshot:
            "The Jam does not contain enough information to export a video."
        case .writerCreationFailed:
            "Could not create the story video writer."
        case .pixelBufferCreationFailed:
            "Could not create a story video frame."
        case .frameRenderingFailed:
            "Could not render a story video frame."
        case .audioRenderingFailed:
            "Could not render the Jam audio."
        case .compositionFailed:
            "Could not combine the story video and Jam audio."
        case .cancelled:
            "Video export was cancelled."
        case .finalFileMissing:
            "The exported video file is missing."
        case .invalidOutput:
            "The exported video has an invalid format."
        }
    }
}

struct JamStoryVideoRenderer {
    static let outputPixelSize = JamStoryExportLayout.canvasSize
    static let framesPerSecond = 30
    static let defaultLoopCount = 4

    private let imageRenderer = JamStoryRenderer()
    private let audioRenderer = JamStoryAudioRenderer()
    private let composer = JamStoryVideoComposer()

    @MainActor
    func render(
        snapshot: JamStoryExportSnapshot,
        configuration: JamStoryExportConfiguration = JamStoryExportConfiguration(),
        progressHandler: (@MainActor @Sendable (JamStoryExportProgress) -> Void)? = nil
    ) async throws -> JamStoryVideoRenderResult {
        guard snapshot.bpm > 0,
              snapshot.arrangement.sequence.harmony.bpm == snapshot.bpm,
              !snapshot.arrangement.sequence.notes.isEmpty,
              configuration.videoLoopCount > 0 else {
            throw JamStoryVideoExportError.invalidSnapshot
        }

        let startedAt = Date()
        let estimatedFrames = Self.estimatedFrameCount(
            bpm: snapshot.bpm,
            loopCount: configuration.videoLoopCount
        )
        progressHandler?(
            Self.progress(
                stage: .preparing,
                completedFrames: 0,
                totalFrames: estimatedFrames,
                fractionCompleted: 0.02,
                startedAt: startedAt
            )
        )

        let baseImageResult = try await imageRenderer.render(
            snapshot: snapshot,
            template: configuration.template
        )
        let coverImageData = await JamCoverRenderer.shared.data(
            for: snapshot.coverDescriptor,
            size: CGSize(width: 720, height: 720),
            scale: 1
        )
        let photoImageDataByID = Dictionary(
            uniqueKeysWithValues: snapshot.photos.compactMap { photo in
                photo.imageData.map { (photo.id, $0) }
            }
        )

        let exportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dap-jam-story-\(UUID().uuidString)", isDirectory: true)
        let silentVideoURL = exportDirectory.appendingPathComponent("video.mp4")
        let audioURL = exportDirectory.appendingPathComponent("audio.caf")
        let finalURL = exportDirectory.appendingPathComponent("jam-story.mp4")
        var shouldKeepFinal = false

        do {
            try FileManager.default.createDirectory(
                at: exportDirectory,
                withIntermediateDirectories: true
            )
            defer {
                try? FileManager.default.removeItem(at: silentVideoURL)
                try? FileManager.default.removeItem(at: audioURL)
                if !shouldKeepFinal {
                    try? FileManager.default.removeItem(at: exportDirectory)
                }
            }

            let audioDuration = try await audioRenderer.render(
                snapshot: snapshot,
                loopCount: configuration.videoLoopCount,
                to: audioURL
            )
            try Task.checkCancellation()
            progressHandler?(
                Self.progress(
                    stage: .preparing,
                    completedFrames: 0,
                    totalFrames: estimatedFrames,
                    fractionCompleted: 0.08,
                    startedAt: startedAt
                )
            )

            let videoDuration = try await renderSilentVideo(
                snapshot: snapshot,
                coverImageData: coverImageData,
                photoImageDataByID: photoImageDataByID,
                template: configuration.template,
                duration: audioDuration,
                to: silentVideoURL,
                startedAt: startedAt,
                progressHandler: progressHandler
            )
            try Task.checkCancellation()
            progressHandler?(
                Self.progress(
                    stage: .composing,
                    completedFrames: estimatedFrames,
                    totalFrames: estimatedFrames,
                    fractionCompleted: 0.90,
                    startedAt: startedAt
                )
            )

            try await composer.compose(
                videoURL: silentVideoURL,
                audioURL: audioURL,
                duration: min(audioDuration, videoDuration),
                destinationURL: finalURL
            )
            try Task.checkCancellation()
            progressHandler?(
                Self.progress(
                    stage: .validating,
                    completedFrames: estimatedFrames,
                    totalFrames: estimatedFrames,
                    fractionCompleted: 0.97,
                    startedAt: startedAt
                )
            )
            try await validateOutput(at: finalURL, expectedDuration: min(audioDuration, videoDuration))

            guard FileManager.default.fileExists(atPath: finalURL.path) else {
                throw JamStoryVideoExportError.finalFileMissing
            }

            progressHandler?(
                Self.progress(
                    stage: .complete,
                    completedFrames: estimatedFrames,
                    totalFrames: estimatedFrames,
                    fractionCompleted: 1,
                    startedAt: startedAt
                )
            )
            shouldKeepFinal = true
            return JamStoryVideoRenderResult(
                fileURL: finalURL,
                previewImageData: baseImageResult.pngData,
                duration: min(audioDuration, videoDuration),
                pixelSize: Self.outputPixelSize,
                framesPerSecond: Self.framesPerSecond
            )
        } catch is CancellationError {
            throw JamStoryVideoExportError.cancelled
        } catch let error as JamStoryVideoExportError {
            throw error
        } catch {
            throw JamStoryVideoExportError.compositionFailed
        }
    }

    static func removeExport(at fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func renderSilentVideo(
        snapshot: JamStoryExportSnapshot,
        coverImageData: Data,
        photoImageDataByID: [UUID: Data],
        template: StoryShareTemplate,
        duration: CMTime,
        to destinationURL: URL,
        startedAt: Date,
        progressHandler: (@MainActor @Sendable (JamStoryExportProgress) -> Void)?
    ) async throws -> CMTime {
        try await Self.writeSilentVideo(
            snapshot: snapshot,
            coverImageData: coverImageData,
            photoImageDataByID: photoImageDataByID,
            template: template,
            duration: duration,
            destinationURL: destinationURL,
            startedAt: startedAt,
            progressHandler: progressHandler
        )
    }

    @MainActor
    private static func writeSilentVideo(
        snapshot: JamStoryExportSnapshot,
        coverImageData: Data,
        photoImageDataByID: [UUID: Data],
        template: StoryShareTemplate,
        duration: CMTime,
        destinationURL: URL,
        startedAt: Date,
        progressHandler: (@MainActor @Sendable (JamStoryExportProgress) -> Void)?
    ) async throws -> CMTime {
        try Task.checkCancellation()
        try? FileManager.default.removeItem(at: destinationURL)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: destinationURL, fileType: .mp4)
        } catch {
            throw JamStoryVideoExportError.writerCreationFailed
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(outputPixelSize.width),
            AVVideoHeightKey: Int(outputPixelSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false

        guard writer.canAdd(input) else {
            throw JamStoryVideoExportError.writerCreationFailed
        }
        writer.add(input)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(outputPixelSize.width),
                kCVPixelBufferHeightKey as String: Int(outputPixelSize.height),
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ]
        )

        guard writer.startWriting() else {
            throw JamStoryVideoExportError.writerCreationFailed
        }
        writer.startSession(atSourceTime: .zero)

        guard let pool = adaptor.pixelBufferPool else {
            writer.cancelWriting()
            throw JamStoryVideoExportError.pixelBufferCreationFailed
        }

        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            writer.cancelWriting()
            throw JamStoryVideoExportError.invalidSnapshot
        }

        let frameCount = Int((durationSeconds * Double(framesPerSecond)).rounded())
        let stepDuration = 60 / Double(snapshot.bpm) / 4
        let videoTemplate = JamStoryVideoTemplate(
            snapshot: snapshot,
            coverImageData: coverImageData,
            photoImageDataByID: photoImageDataByID,
            template: template
        )
        let progressStride = max(1, framesPerSecond / 10)

        do {
            for frameIndex in 0..<frameCount {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    guard writer.status != .failed else {
                        throw JamStoryVideoExportError.frameRenderingFailed
                    }
                    try await Task.sleep(for: .milliseconds(2))
                }

                var pixelBuffer: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(
                    nil,
                    pool,
                    &pixelBuffer
                ) == kCVReturnSuccess, let pixelBuffer else {
                    throw JamStoryVideoExportError.pixelBufferCreationFailed
                }

                let time = Double(frameIndex) / Double(framesPerSecond)
                try autoreleasepool {
                    try videoTemplate.render(
                        into: pixelBuffer,
                        time: time,
                        stepDuration: stepDuration
                    )
                }
                let presentationTime = CMTime(
                    value: Int64(frameIndex),
                    timescale: CMTimeScale(framesPerSecond)
                )
                guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                    throw JamStoryVideoExportError.frameRenderingFailed
                }

                if frameIndex % progressStride == 0 || frameIndex == frameCount - 1 {
                    await progressHandler?(
                        progress(
                            stage: .renderingFrames,
                            completedFrames: frameIndex + 1,
                            totalFrames: frameCount,
                            fractionCompleted: 0.08 + 0.82 * (Double(frameIndex + 1) / Double(frameCount)),
                            startedAt: startedAt
                        )
                    )
                }
            }
        } catch {
            writer.cancelWriting()
            throw error
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw JamStoryVideoExportError.frameRenderingFailed
        }

        return CMTime(
            value: Int64(frameCount),
            timescale: CMTimeScale(framesPerSecond)
        )
    }

    private func validateOutput(at url: URL, expectedDuration: CMTime) async throws {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first,
              let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw JamStoryVideoExportError.invalidOutput
        }

        let size = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let frameRate = try await videoTrack.load(.nominalFrameRate)
        let videoDescriptions = try await videoTrack.load(.formatDescriptions)
        let audioDescriptions = try await audioTrack.load(.formatDescriptions)
        let audioTimeRange = try await audioTrack.load(.timeRange)
        let duration = try await asset.load(.duration)
        let videoCodec = videoDescriptions.first.map(CMFormatDescriptionGetMediaSubType)
        let audioCodec = audioDescriptions.first.map(CMFormatDescriptionGetMediaSubType)
        let durationDelta = abs(CMTimeGetSeconds(duration - expectedDuration))
        let audioDurationDelta = abs(
            CMTimeGetSeconds(audioTimeRange.duration - expectedDuration)
        )

        guard Int(size.width.rounded()) == Int(Self.outputPixelSize.width),
              Int(size.height.rounded()) == Int(Self.outputPixelSize.height),
              preferredTransform == .identity,
              abs(frameRate - Float(Self.framesPerSecond)) < 0.5,
              videoCodec == kCMVideoCodecType_H264,
              audioCodec == kAudioFormatMPEG4AAC,
              durationDelta < 0.05,
              audioDurationDelta < 0.05 else {
            throw JamStoryVideoExportError.invalidOutput
        }
    }

    private static func estimatedFrameCount(bpm: Int, loopCount: Int) -> Int {
        guard bpm > 0, loopCount > 0 else { return 1 }
        let stepDuration = 60 / Double(bpm) / 4
        let duration = stepDuration * Double(MusicSequence.steps * loopCount)
        return max(1, Int((duration * Double(framesPerSecond)).rounded()))
    }

    private static func progress(
        stage: JamStoryExportProgress.Stage,
        completedFrames: Int,
        totalFrames: Int,
        fractionCompleted: Double,
        startedAt: Date
    ) -> JamStoryExportProgress {
        let elapsedSeconds = max(0, Date().timeIntervalSince(startedAt))
        let elapsedMilliseconds = Int64((elapsedSeconds * 1000).rounded())
        let clampedFraction = min(max(fractionCompleted, 0), 1)
        let remainingMilliseconds: Int64?

        if clampedFraction > 0.05 && clampedFraction < 1 {
            let totalMilliseconds = elapsedSeconds / clampedFraction * 1000
            remainingMilliseconds = max(0, Int64((totalMilliseconds - Double(elapsedMilliseconds)).rounded()))
        } else {
            remainingMilliseconds = nil
        }

        return JamStoryExportProgress(
            stage: stage,
            completedFrames: completedFrames,
            totalFrames: totalFrames,
            fractionCompleted: clampedFraction,
            elapsed: .milliseconds(elapsedMilliseconds),
            estimatedRemaining: remainingMilliseconds.map { .milliseconds($0) }
        )
    }
}
