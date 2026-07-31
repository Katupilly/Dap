import AVFoundation
import Observation
import UIKit

enum JamStoryExportPhase: Equatable {
    case customize
    case exporting
    case ready
    case failed
}

enum JamStoryExportResult {
    case image(JamStoryRenderResult)
    case video(JamStoryVideoRenderResult)
}

@MainActor
@Observable
final class JamStoryExportCoordinator {
    let snapshot: JamStoryExportSnapshot
    var configuration = JamStoryExportConfiguration()
    private(set) var phase = JamStoryExportPhase.customize
    private(set) var progress: JamStoryExportProgress?
    private(set) var result: JamStoryExportResult?
    private(set) var errorMessage: String?
    private(set) var player: AVPlayer?
    private(set) var isVideoPlaying = false
    private(set) var shareURL: URL?

    @ObservationIgnored private let imageRenderer = JamStoryRenderer()
    @ObservationIgnored private let videoRenderer = JamStoryVideoRenderer()
    @ObservationIgnored private let instagramExporter = InstagramStoryExporter()
    @ObservationIgnored private var exportTask: Task<Void, Never>?

    init(snapshot: JamStoryExportSnapshot) {
        self.snapshot = snapshot
    }

    var canStartExport: Bool {
        exportTask == nil && configuration.isValid(for: snapshot)
    }

    var isExporting: Bool {
        phase == .exporting
    }

    var isInstagramStoriesAvailable: Bool {
        instagramExporter.isInstagramStoriesAvailable
    }

    func startExport() {
        guard canStartExport else { return }
        cleanupResult()
        errorMessage = nil
        phase = .exporting

        let startedAt = Date()
        let exportConfiguration = configuration
        progress = makeProgress(
            stage: .preparing,
            completedFrames: 0,
            totalFrames: max(1, estimatedVideoFrameCount(for: exportConfiguration)),
            fractionCompleted: 0.02,
            startedAt: startedAt
        )

        exportTask = Task { @MainActor in
            do {
                switch exportConfiguration.format {
                case .image:
                    let renderedImage = try await imageRenderer.render(snapshot: snapshot)
                    try Task.checkCancellation()
                    let preparedURL = try DapExportFileHelper.prepareJamImage(
                        data: renderedImage.pngData,
                        name: snapshot.jamName
                    )
                    progress = makeProgress(
                        stage: .complete,
                        completedFrames: 1,
                        totalFrames: 1,
                        fractionCompleted: 1,
                        startedAt: startedAt
                    )
                    result = .image(renderedImage)
                    shareURL = preparedURL
                case .video:
                    let renderedVideo = try await videoRenderer.render(
                        snapshot: snapshot,
                        configuration: exportConfiguration
                    ) { [weak self] exportProgress in
                        self?.progress = exportProgress
                    }
                    try Task.checkCancellation()
                    let preparedURL = try DapExportFileHelper.prepareJamVideo(
                        from: renderedVideo.fileURL,
                        name: snapshot.jamName
                    )
                    result = .video(renderedVideo)
                    shareURL = preparedURL
                    preparePlayer(for: renderedVideo.fileURL)
                }
                phase = .ready
            } catch is CancellationError {
                cleanupResult()
                phase = .customize
            } catch JamStoryVideoExportError.cancelled {
                cleanupResult()
                phase = .customize
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "Could not prepare this story export."
                phase = .failed
            }
            exportTask = nil
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    func returnToCustomize() {
        cancelExport()
        cleanupResult()
        errorMessage = nil
        progress = nil
        phase = .customize
    }

    func cleanupForDismissal() {
        cancelExport()
        cleanupResult()
        exportTask = nil
    }

    func toggleVideoPlayback() {
        guard let player else { return }
        if isVideoPlaying {
            player.pause()
            isVideoPlaying = false
        } else {
            player.play()
            isVideoPlaying = true
        }
    }

    func shareReadyResultToInstagram() async {
        guard let result else { return }

        do {
            switch result {
            case .image(let imageResult):
                try await instagramExporter.export(backgroundImage: imageResult.image)
            case .video(let videoResult):
                try await instagramExporter.export(backgroundVideoAt: videoResult.fileURL)
            }
        } catch let error as InstagramStoryExportError {
            errorMessage = error.localizedDescription
            phase = .failed
        } catch {
            errorMessage = InstagramStoryExportError.openFailed.localizedDescription
            phase = .failed
        }
    }

    private func preparePlayer(for fileURL: URL) {
        releasePlayer()
        player = AVPlayer(url: fileURL)
    }

    private func cleanupResult() {
        releasePlayer()
        if case .video(let videoResult) = result {
            JamStoryVideoRenderer.removeExport(at: videoResult.fileURL)
        }
        DapExportFileHelper.removeTemporaryExports()
        shareURL = nil
        result = nil
    }

    private func releasePlayer() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        isVideoPlaying = false
    }

    private func estimatedVideoFrameCount(for configuration: JamStoryExportConfiguration) -> Int {
        guard snapshot.bpm > 0 else { return 1 }
        let stepDuration = 60 / Double(snapshot.bpm) / 4
        let duration = stepDuration * Double(MusicSequence.steps * configuration.videoLoopCount)
        return max(1, Int((duration * Double(JamStoryVideoRenderer.framesPerSecond)).rounded()))
    }

    private func makeProgress(
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
