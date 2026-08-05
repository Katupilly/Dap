import AVKit
import SwiftUI
import UIKit

struct JamStoryExportSheet: View {
    let snapshot: JamStoryExportSnapshot
    @Binding var isPresented: Bool

    @State private var coordinator: JamStoryExportCoordinator
    @State private var isShowingShareSheet = false
    @State private var photoSaveToastEvent: PhotoSaveToastEvent?

    init(snapshot: JamStoryExportSnapshot, isPresented: Binding<Bool>) {
        self.snapshot = snapshot
        self._isPresented = isPresented
        _coordinator = State(initialValue: JamStoryExportCoordinator(snapshot: snapshot))
    }

    var body: some View {
        ZStack(alignment: .top) {
            StoryExportChromeBackground()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 62)

            StoryShareHeader(title: title) {
                handleClose()
            }
        }
        .interactiveDismissDisabled(coordinator.isExporting || coordinator.isSharingToInstagram)
        .task { coordinator.preparePreviews() }
        .onDisappear { coordinator.cleanupForDismissal() }
        .sheet(isPresented: $isShowingShareSheet) {
            if let image = coordinator.selectedPreviewImage {
                NativeImageShareViewController(
                    image: image,
                    onSaveResult: { result in
                        photoSaveToastEvent = PhotoSaveToastEvent.make(for: result)
                    },
                    onDismiss: { isShowingShareSheet = false }
                )
            }
        }
        .photoSaveToast($photoSaveToastEvent)
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.phase {
        case .selection:
            StoryShareSurface(
                previews: previews,
                selection: coordinator.configuration.template,
                isInstagramAvailable: coordinator.isInstagramStoriesAvailable,
                isStoriesLoading: false,
                isShareLoading: false,
                isStoriesEnabled: coordinator.isSelectedPreviewReady,
                isShareEnabled: coordinator.isSelectedPreviewReady,
                onSelect: { coordinator.configuration.template = $0 },
                onStories: {
                    coordinator.exportForInstagram(template: coordinator.configuration.template)
                },
                onShare: { isShowingShareSheet = true }
            )

        case .exporting:
            JamStoryExportProgressView(
                preview: coordinator.previews[coordinator.configuration.template]?.image,
                progress: coordinator.progress
            )

        case .ready:
            JamStoryExportReadyView(
                coordinator: coordinator,
                onShare: { isShowingShareSheet = true }
            )

        case .failed:
            JamStoryExportFailedView(
                message: coordinator.errorMessage ?? "Could not prepare this story export.",
                onTryAgain: {
                    coordinator.retryInstagram(template: coordinator.configuration.template)
                },
                onBack: coordinator.returnToSelection
            )
        }
    }

    private var previews: [StorySharePreview] {
        StoryShareTemplate.allCases.map { template in
            StorySharePreview(
                template: template,
                image: coordinator.previews[template]?.image,
                isLoading: coordinator.previews[template] == nil
                    && !coordinator.failedPreviewTemplates.contains(template)
            )
        }
    }

    private var title: String {
        switch coordinator.phase {
        case .selection: "Share"
        case .exporting: "Exporting"
        case .ready: "Ready"
        case .failed: "Couldn't Export"
        }
    }

    private func handleClose() {
        if coordinator.isSharingToInstagram {
            return
        }
        if coordinator.isExporting {
            coordinator.cancelExport()
            return
        }
        coordinator.cleanupForDismissal()
        isPresented = false
    }
}

private struct JamStoryExportProgressView: View {
    let preview: UIImage?
    let progress: JamStoryExportProgress?

    var body: some View {
        VStack(spacing: 20) {
            Group {
                if let preview {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFit()
                } else {
                    RoundedRectangle(cornerRadius: 19.4, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground))
                        .overlay { ProgressView() }
                }
            }
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 19.4, style: .continuous))
            .frame(maxHeight: 360)

            VStack(spacing: 6) {
                Text("\(percentComplete)%")
                    .font(.custom("ZTTalk-Bold", size: 34, relativeTo: .largeTitle))
                    .monospacedDigit()

                Text(remainingText)
                    .font(.custom("ZTTalk-Medium", size: 15, relativeTo: .subheadline))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Text("Do not close or leave the app")
                .font(.custom("ZTTalk-Bold", size: 15, relativeTo: .subheadline))
                .foregroundStyle(.secondary)

            ProgressView(value: progress?.fractionCompleted ?? 0)
                .progressViewStyle(.linear)
                .tint(.primary)
                .accessibilityLabel(progress?.stage.displayName ?? "Preparing")
                .accessibilityValue("\(percentComplete)%")
        }
        .padding(.horizontal, 26)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var percentComplete: Int {
        Int(((progress?.fractionCompleted ?? 0) * 100).rounded())
    }

    private var remainingText: String {
        guard let remaining = progress?.estimatedRemaining else { return "Estimating remaining" }
        let components = remaining.components
        let seconds = max(
            0,
            Int(ceil(Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000))
        )
        return String(format: "%02d:%02d remaining", seconds / 60, seconds % 60)
    }
}

private struct JamStoryExportReadyView: View {
    let coordinator: JamStoryExportCoordinator
    let onShare: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            preview

            StoryShareActions(
                isInstagramAvailable: coordinator.isInstagramStoriesAvailable,
                isStoriesLoading: coordinator.isSharingToInstagram,
                isShareLoading: false,
                isStoriesEnabled: true,
                isShareEnabled: coordinator.selectedPreviewImage != nil,
                onStories: {
                    Task {
                        await coordinator.shareReadyResultToInstagram(
                            template: coordinator.configuration.template
                        )
                    }
                },
                onShare: onShare
            )
        }
        .padding(.horizontal, 20)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var preview: some View {
        if let player = coordinator.player {
            ZStack(alignment: .bottom) {
                VideoPlayer(player: player)
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)

                Button(action: coordinator.toggleVideoPlayback) {
                    Image(systemName: coordinator.isVideoPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(.black.opacity(0.58), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 16)
                .accessibilityLabel(coordinator.isVideoPlaying ? "Pause preview" : "Play preview")
            }
            .clipShape(RoundedRectangle(cornerRadius: 19.4, style: .continuous))
        } else if let image = coordinator.selectedPreviewImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 19.4, style: .continuous))
        } else {
            ProgressView()
                .frame(maxHeight: .infinity)
        }
    }
}

private struct JamStoryExportFailedView: View {
    let message: String
    let onTryAgain: () -> Void
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)

            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(message)
                .font(.custom("ZTTalk-Bold", size: 17, relativeTo: .headline))
                .multilineTextAlignment(.center)

            Button(action: onTryAgain) {
                Text("Try Again")
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(StoryPrimaryButtonStyle())

            Button(action: onBack) {
                Text("Back")
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(StorySecondaryButtonStyle())

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
    }
}
