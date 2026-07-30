import AVFoundation
import Foundation

struct JamStoryVideoComposer {
    func compose(
        videoURL: URL,
        audioURL: URL,
        duration: CMTime,
        destinationURL: URL
    ) async throws {
        try Task.checkCancellation()

        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            throw JamStoryVideoExportError.compositionFailed
        }

        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ), let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw JamStoryVideoExportError.compositionFailed
        }

        let timeRange = CMTimeRange(start: .zero, duration: duration)
        do {
            try compositionVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: .zero)
            try compositionAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)
        } catch {
            throw JamStoryVideoExportError.compositionFailed
        }

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw JamStoryVideoExportError.compositionFailed
        }

        try? FileManager.default.removeItem(at: destinationURL)
        exportSession.shouldOptimizeForNetworkUse = true

        do {
            try await exportSession.export(to: destinationURL, as: .mp4)
        } catch is CancellationError {
            throw JamStoryVideoExportError.cancelled
        } catch {
            throw JamStoryVideoExportError.compositionFailed
        }
    }
}
