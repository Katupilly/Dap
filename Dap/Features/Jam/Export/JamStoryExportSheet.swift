import AVKit
import SwiftUI
import UIKit

private let jamStoryExportHeaderHeight: CGFloat = 62

struct JamStoryExportSheet: View {
    let snapshot: JamStoryExportSnapshot
    @Binding var isPresented: Bool

    @State private var coordinator: JamStoryExportCoordinator

    init(snapshot: JamStoryExportSnapshot, isPresented: Binding<Bool>) {
        self.snapshot = snapshot
        self._isPresented = isPresented
        _coordinator = State(initialValue: JamStoryExportCoordinator(snapshot: snapshot))
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                StoryExportChromeBackground()

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                StoryExportTopBlurFade(height: 112)

                JamStoryExportHeader(
                    title: title,
                    showsConfirmButton: coordinator.phase == .customize,
                    confirmEnabled: coordinator.canStartExport,
                    closeEnabled: !coordinator.isSharingToInstagram,
                    onClose: handleClose,
                    onConfirm: coordinator.startExport
                )
            }
        }
        .interactiveDismissDisabled(coordinator.isExporting || coordinator.isSharingToInstagram)
        .onDisappear {
            coordinator.cleanupForDismissal()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.phase {
        case .customize:
            JamStoryExportCustomizeView(
                snapshot: snapshot,
                coordinator: coordinator
            )
        case .exporting:
            JamStoryExportProgressView(
                snapshot: snapshot,
                configuration: coordinator.configuration,
                progress: coordinator.progress
            )
        case .ready:
            if let result = coordinator.result {
                JamStoryExportReadyView(
                    snapshot: snapshot,
                    result: result,
                    coordinator: coordinator
                )
            }
        case .failed:
            JamStoryExportFailedView(
                message: coordinator.errorMessage ?? "Could not prepare this story export.",
                onTryAgain: coordinator.startExport,
                onCustomize: coordinator.returnToCustomize
            )
        }
    }

    private var title: String {
        switch coordinator.phase {
        case .customize: "Create Story"
        case .exporting: "Exporting"
        case .ready: "Ready"
        case .failed: "Couldn't Export"
        }
    }

    private func handleClose() {
        if coordinator.isSharingToInstagram {
            return
        } else if coordinator.isExporting {
            coordinator.cancelExport()
        } else {
            coordinator.cleanupForDismissal()
            isPresented = false
        }
    }
}

private struct JamStoryExportHeader: View {
    let title: String
    let showsConfirmButton: Bool
    let confirmEnabled: Bool
    let closeEnabled: Bool
    let onClose: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        ZStack {
            Text(title)
                .font(.custom("ZTTalk-Bold", size: 18, relativeTo: .headline))
                .lineLimit(1)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(StoryHeaderGlassButtonStyle())
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(!closeEnabled)
            .accessibilityLabel("Close")

            if showsConfirmButton {
                Button(action: onConfirm) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(StoryHeaderGlassButtonStyle())
                .frame(maxWidth: .infinity, alignment: .trailing)
                .disabled(!confirmEnabled)
                .accessibilityLabel("Start export")
                .accessibilityHint("Creates the selected story export.")
            } else {
                Color.clear
                    .frame(width: 44, height: 44)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(height: jamStoryExportHeaderHeight, alignment: .top)
    }
}

private struct JamStoryExportCustomizeView: View {
    let snapshot: JamStoryExportSnapshot
    @Bindable var coordinator: JamStoryExportCoordinator

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                JamStoryExportLightPreview(
                    snapshot: snapshot,
                    configuration: coordinator.configuration
                )

                templateCarousel

                Picker("Format", selection: $coordinator.configuration.format) {
                    ForEach(JamStoryExportFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Export format")

                if coordinator.configuration.format == .video {
                    Picker("Duration", selection: $coordinator.configuration.videoLoopCount) {
                        ForEach(JamStoryExportConfiguration.videoLoopOptions, id: \.self) { loopCount in
                            Text("\(loopCount) loops").tag(loopCount)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Video duration")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, jamStoryExportHeaderHeight)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
    }

    private var templateCarousel: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(JamStoryTemplate.allCases) { template in
                    Button {
                        coordinator.configuration.template = template
                    } label: {
                        JamStoryTemplateThumbnail(
                            title: template.displayName,
                            isSelected: coordinator.configuration.template == template
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(template.displayName)
                    .accessibilityAddTraits(
                        coordinator.configuration.template == template ? .isSelected : []
                    )
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, -20)
    }
}

private struct JamStoryExportProgressView: View {
    let snapshot: JamStoryExportSnapshot
    let configuration: JamStoryExportConfiguration
    let progress: JamStoryExportProgress?

    var body: some View {
        VStack(spacing: 20) {
            JamStoryExportLightPreview(
                snapshot: snapshot,
                configuration: configuration
            )
            .frame(maxHeight: 330)

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
        .padding(.top, jamStoryExportHeaderHeight)
        .padding(.bottom, 28)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var percentComplete: Int {
        Int(((progress?.fractionCompleted ?? 0) * 100).rounded())
    }

    private var remainingText: String {
        guard let remaining = progress?.estimatedRemaining else {
            return "Estimating remaining"
        }
        return "\(format(duration: remaining)) remaining"
    }

    private func format(duration: Duration) -> String {
        let components = duration.components
        let seconds = max(
            0,
            Int(ceil(
                Double(components.seconds)
                    + Double(components.attoseconds) / 1_000_000_000_000_000_000
            ))
        )
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct JamStoryExportReadyView: View {
    let snapshot: JamStoryExportSnapshot
    let result: JamStoryExportResult
    let coordinator: JamStoryExportCoordinator

    var body: some View {
        VStack(spacing: 18) {
            preview

            StoryShareActions(
                isInstagramAvailable: coordinator.isInstagramStoriesAvailable,
                onInstagram: {
                    Task { await coordinator.shareReadyResultToInstagram() }
                }
            ) {
                if let shareURL = coordinator.shareURL {
                    shareLink(shareURL: shareURL)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, jamStoryExportHeaderHeight)
        .padding(.bottom, 28)
    }

    @ViewBuilder
    private var preview: some View {
        switch result {
        case .image(let imageResult):
            Image(uiImage: imageResult.image)
                .resizable()
                .scaledToFit()
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(.white.opacity(0.16), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.18), radius: 22, y: 12)
        case .video:
            ZStack(alignment: .bottom) {
                JamStoryVideoPreview(player: coordinator.player)

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
        }
    }

    @ViewBuilder
    private func shareLink(shareURL: URL) -> some View {
        switch result {
        case .image(let imageResult):
            ShareLink(
                item: shareURL,
                preview: SharePreview(
                    shareURL.lastPathComponent,
                    image: Image(uiImage: imageResult.image)
                )
            ) {
                shareLabel
            }
        case .video(let videoResult):
            if let previewImage = UIImage(data: videoResult.previewImageData) {
                ShareLink(
                    item: shareURL,
                    preview: SharePreview(
                        shareURL.lastPathComponent,
                        image: Image(uiImage: previewImage)
                    )
                ) {
                    shareLabel
                }
            } else {
                ShareLink(
                    item: shareURL,
                    preview: SharePreview(shareURL.lastPathComponent)
                ) {
                    shareLabel
                }
            }
        }
    }

    private var shareLabel: some View {
        Label("Share...", systemImage: "square.and.arrow.up")
            .frame(maxWidth: .infinity, minHeight: 52)
    }
}

private struct JamStoryVideoPreview: View {
    let player: AVPlayer?

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
            } else {
                Color.black
                ProgressView()
                    .tint(.white)
            }
        }
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        }
    }
}

private struct JamStoryExportFailedView: View {
    let message: String
    let onTryAgain: () -> Void
    let onCustomize: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)

            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(message)
                .font(.custom("ZTTalk-Bold", size: 17, relativeTo: .headline))
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)

            VStack(spacing: 10) {
                Button(action: onTryAgain) {
                    Text("Try Again")
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(StoryPrimaryButtonStyle())

                Button(action: onCustomize) {
                    Text("Back to Customize")
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(StorySecondaryButtonStyle())
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.top, jamStoryExportHeaderHeight)
        .padding(.bottom, 28)
    }
}

private struct JamStoryExportLightPreview: View {
    let snapshot: JamStoryExportSnapshot
    let configuration: JamStoryExportConfiguration

    var body: some View {
        ZStack {
            previewBackground

            VStack(alignment: .leading, spacing: 16) {
                Text("DAP JAM")
                    .font(.custom("ZTTalk-Bold", size: 10, relativeTo: .caption))
                    .tracking(1.4)
                    .foregroundStyle(.white.opacity(0.58))

                Text(snapshot.jamName)
                    .font(.custom("ZTTalk-Bold", size: 28, relativeTo: .title))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)

                JamCoverArtwork(
                    descriptor: snapshot.coverDescriptor,
                    targetSize: CGSize(width: 420, height: 420),
                    cornerRadius: 14
                )
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.white.opacity(0.16), lineWidth: 1)
                }

                roleStrip

                sequencerPreview

                Spacer(minLength: 0)

                HStack {
                    Text(configuration.format.displayName.uppercased())
                    Spacer(minLength: 0)
                    Text("Made with Dap")
                }
                .font(.custom("ZTTalk-Bold", size: 10, relativeTo: .caption))
                .foregroundStyle(.white.opacity(0.56))
            }
            .padding(24)
        }
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.14), radius: 18, y: 10)
    }

    private var previewBackground: some View {
        let color = snapshot.roleColors.values.first ?? JamStoryExportSnapshot.fallbackAccent
        return LinearGradient(
            colors: [
                Color(jamRGB: color).opacity(0.88),
                .black.opacity(0.92)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var roleStrip: some View {
        HStack(spacing: 8) {
            ForEach(snapshot.photos) { photo in
                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(jamRGB: photo.accentColor).opacity(0.54))
                        .aspectRatio(5.0 / 6.0, contentMode: .fit)

                    Text(photo.role?.displayName.uppercased() ?? "PHOTO")
                        .font(.custom("ZTTalk-Bold", size: 8, relativeTo: .caption2))
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(1)
                }
            }
        }
    }

    private var sequencerPreview: some View {
        VStack(spacing: 5) {
            ForEach(JamRole.allCases, id: \.self) { role in
                let activeSteps = snapshot.sequencerSnapshot.steps(for: role)
                let color = Color(jamRGB: snapshot.roleColors[role] ?? JamStoryExportSnapshot.fallbackAccent)

                HStack(spacing: 3) {
                    ForEach(0..<MusicSequence.steps, id: \.self) { step in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(activeSteps.contains(step) ? color.opacity(0.9) : .white.opacity(0.14))
                            .frame(height: 7)
                    }
                }
            }
        }
        .padding(12)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct JamStoryTemplateThumbnail: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.secondary.opacity(0.16))
                .frame(width: 62, height: 94)
                .overlay {
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(.primary.opacity(0.38))
                            .frame(width: 34, height: 34)
                        HStack(spacing: 2) {
                            ForEach(0..<5, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 1, style: .continuous)
                                    .fill(.primary.opacity(0.28))
                                    .frame(width: 5, height: 18)
                            }
                        }
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSelected ? Color.primary : Color.clear, lineWidth: 2)
                }

            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .frame(width: 82)
    }
}
