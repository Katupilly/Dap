import AVFoundation
import Foundation

struct JamStoryAudioRenderer {
    static let sampleRate = 44_100

    func render(
        snapshot: JamStoryExportSnapshot,
        loopCount: Int,
        to destinationURL: URL
    ) async throws -> CMTime {
        let renderTask = Task.detached(priority: .userInitiated) {
            try Self.renderSynchronously(
                snapshot: snapshot,
                loopCount: loopCount,
                destinationURL: destinationURL
            )
        }

        return try await withTaskCancellationHandler {
            try await renderTask.value
        } onCancel: {
            renderTask.cancel()
        }
    }

    private nonisolated static func renderSynchronously(
        snapshot: JamStoryExportSnapshot,
        loopCount: Int,
        destinationURL: URL
    ) throws -> CMTime {
        try Task.checkCancellation()
        guard loopCount > 0 else {
            throw JamStoryVideoExportError.invalidSnapshot
        }

        let samples: RenderedJamAudio
        do {
            samples = try JamAudioRenderer.render(
                snapshot.arrangement.sequence,
                percussion: snapshot.arrangement.percussion,
                sampleRate: sampleRate,
                loops: true
            )
        } catch is CancellationError {
            throw JamStoryVideoExportError.cancelled
        } catch {
            throw JamStoryVideoExportError.audioRenderingFailed
        }

        guard samples.left.count == samples.right.count,
              !samples.left.isEmpty,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(sampleRate),
                channels: 2,
                interleaved: false
              ) else {
            throw JamStoryVideoExportError.audioRenderingFailed
        }

        let frameCount = AVAudioFrameCount(samples.left.count)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ), let channels = buffer.floatChannelData else {
            throw JamStoryVideoExportError.audioRenderingFailed
        }

        buffer.frameLength = frameCount
        for frame in 0..<samples.left.count {
            channels[0][frame] = samples.left[frame]
            channels[1][frame] = samples.right[frame]
        }

        do {
            try? FileManager.default.removeItem(at: destinationURL)
            let file = try AVAudioFile(
                forWriting: destinationURL,
                settings: format.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            for _ in 0..<loopCount {
                try Task.checkCancellation()
                try file.write(from: buffer)
            }
        } catch is CancellationError {
            throw JamStoryVideoExportError.cancelled
        } catch {
            throw JamStoryVideoExportError.audioRenderingFailed
        }

        return CMTime(
            value: Int64(samples.left.count * loopCount),
            timescale: CMTimeScale(sampleRate)
        )
    }
}
