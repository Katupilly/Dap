import AVFoundation
import Observation
import UIKit

enum JamStoryExportPhase: Equatable {
    case selection
    case exporting
    case ready
    case failed
}

enum JamStoryExportResult {
    case video(JamStoryVideoRenderResult)
}

@MainActor
@Observable
final class JamStoryExportCoordinator {
    let snapshot: JamStoryExportSnapshot
    var configuration = JamStoryExportConfiguration()
    private(set) var phase = JamStoryExportPhase.selection
    private(set) var progress: JamStoryExportProgress?
    private(set) var result: JamStoryExportResult?
    private(set) var previews: [StoryShareTemplate: JamStoryRenderResult] = [:]
    private(set) var failedPreviewTemplates: Set<StoryShareTemplate> = []
    private(set) var errorMessage: String?
    private(set) var player: AVPlayer?
    private(set) var isVideoPlaying = false
    private(set) var shareURL: URL?
    private(set) var isSharingToInstagram = false

    @ObservationIgnored private let imageRenderer = JamStoryRenderer()
    @ObservationIgnored private let videoRenderer = JamStoryVideoRenderer()
    @ObservationIgnored private let instagramExporter = InstagramStoryExporter()
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var cleanupRequested = false
    @ObservationIgnored private var renderedVideoTemplate: StoryShareTemplate?

    init(snapshot: JamStoryExportSnapshot) {
        self.snapshot = snapshot
    }

    var isExporting: Bool { phase == .exporting }

    var isInstagramStoriesAvailable: Bool {
        instagramExporter.isInstagramStoriesAvailable
    }

    var selectedPreviewImage: UIImage? {
        previews[configuration.template]?.image
    }

    var isSelectedPreviewReady: Bool {
        previews[configuration.template] != nil
    }

    func preparePreviews() {
        guard previewTask == nil, previews.count < StoryShareTemplate.allCases.count else { return }

        failedPreviewTemplates = []

        previewTask = Task { @MainActor in
            for template in StoryShareTemplate.allCases {
                guard !Task.isCancelled else { return }
                if previews[template] != nil { continue }
                do {
                    previews[template] = try await imageRenderer.render(
                        snapshot: snapshot,
                        template: template
                    )
                } catch {
                    failedPreviewTemplates.insert(template)
                    errorMessage = (error as? LocalizedError)?.errorDescription
                }
            }
            previewTask = nil
        }
    }

    func exportForInstagram(template: StoryShareTemplate) {
        guard !isSharingToInstagram,
              !isExporting,
              isInstagramStoriesAvailable else { return }

        configuration.template = template
        configuration.videoLoopCount = JamStoryVideoRenderer.defaultLoopCount

        if case .video = result,
           renderedVideoTemplate == template,
           let shareURL,
           FileManager.default.fileExists(atPath: shareURL.path) {
            phase = .ready
            Task { await shareReadyResultToInstagram(template: template) }
            return
        }

        cleanupResult()
        errorMessage = nil
        phase = .exporting
        let startedAt = Date()
        let exportConfiguration = configuration
        let estimatedFrames = estimatedVideoFrameCount(for: exportConfiguration)
        progress = makeProgress(
            stage: .preparing,
            completedFrames: 0,
            totalFrames: estimatedFrames,
            fractionCompleted: 0.02,
            startedAt: startedAt
        )

        exportTask = Task { @MainActor in
            defer { exportTask = nil }
            do {
                let renderedVideo = try await videoRenderer.render(
                    snapshot: snapshot,
                    configuration: exportConfiguration,
                    progressHandler: { [weak self] exportProgress in
                        self?.progress = exportProgress
                    }
                )
                try Task.checkCancellation()
                let preparedURL = try DapExportFileHelper.prepareJamVideo(
                    from: renderedVideo.fileURL,
                    name: snapshot.jamName
                )
                result = .video(renderedVideo)
                shareURL = preparedURL
                renderedVideoTemplate = template
                preparePlayer(for: renderedVideo.fileURL)
                phase = .ready
                await shareReadyResultToInstagram(template: template)
            } catch is CancellationError {
                cleanupResult()
                phase = .selection
            } catch JamStoryVideoExportError.cancelled {
                cleanupResult()
                phase = .selection
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "Could not prepare this story export."
                phase = .failed
            }
        }
    }

    func retryInstagram(template: StoryShareTemplate) {
        guard !isSharingToInstagram else { return }
        if case .video = result,
           renderedVideoTemplate == template,
           let shareURL,
           FileManager.default.fileExists(atPath: shareURL.path) {
            configuration.template = template
            phase = .ready
            Task { await shareReadyResultToInstagram(template: template) }
        } else {
            exportForInstagram(template: template)
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    func returnToSelection() {
        cancelExport()
        cleanupResult()
        errorMessage = nil
        progress = nil
        phase = .selection
    }

    func cleanupForDismissal() {
        previewTask?.cancel()
        cancelExport()
        guard !isSharingToInstagram else {
            cleanupRequested = true
            return
        }
        cleanupResult()
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

    func shareReadyResultToInstagram(template: StoryShareTemplate) async {
        guard !isSharingToInstagram,
              template == renderedVideoTemplate,
              case .video = result,
              let shareURL else { return }

        isSharingToInstagram = true
        defer {
            isSharingToInstagram = false
            if cleanupRequested {
                cleanupRequested = false
                cleanupResult()
            }
        }

        do {
            try await instagramExporter.export(backgroundVideoAt: shareURL)
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
        renderedVideoTemplate = nil
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
