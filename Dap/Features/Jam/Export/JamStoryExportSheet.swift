import AVFoundation
import AVKit
import CoreTransferable
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct JamStoryExportSheet: View {
    let snapshot: JamStoryExportSnapshot
    @Binding var isPresented: Bool

    @State private var selectedFormat = JamStoryExportFormat.image
    @State private var renderState = RenderState.idle
    @State private var renderTask: Task<Void, Never>?
    @State private var player: AVPlayer?
    @State private var instagramError: InstagramStoryExportError?

    private let imageRenderer = JamStoryRenderer()
    private let videoRenderer = JamStoryVideoRenderer()
    private let instagramExporter = InstagramStoryExporter()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Picker("Format", selection: $selectedFormat) {
                        ForEach(JamStoryExportFormat.allCases) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(renderState.isPreparing)

                    preview
                    actions
                }
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .navigationTitle("Export Story")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
            }
        }
        .task {
            prepareSelectedFormat()
        }
        .onChange(of: selectedFormat) {
            resetAndPrepareSelectedFormat()
        }
        .onDisappear {
            cancelAndCleanup()
        }
        .alert("Instagram Stories", isPresented: instagramErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(instagramError?.localizedDescription ?? "Could not share to Instagram Stories.")
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch renderState {
        case .idle:
            statusPreview(
                symbol: selectedFormat == .image ? "photo" : "video",
                message: "Ready to prepare \(selectedFormat.displayName.lowercased())."
            )
        case .preparing:
            previewFrame {
                VStack(spacing: 14) {
                    ProgressView()
                        .tint(.white)
                    Text(
                        selectedFormat == .image
                            ? "Preparing story image…"
                            : "Rendering video and Jam audio…"
                    )
                    .font(.custom("ZTTalk-Bold", size: 16, relativeTo: .subheadline))
                    .foregroundStyle(.white.opacity(0.74))
                }
            }
        case .ready(.image(let result)):
            Image(uiImage: result.image)
                .resizable()
                .scaledToFit()
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(.white.opacity(0.16), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.18), radius: 22, y: 12)
        case .ready(.video):
            previewFrame {
                if let player {
                    VideoPlayer(player: player)
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
        case .failed(let message):
            statusPreview(
                symbol: "exclamationmark.triangle",
                message: message
            )
        case .cancelled:
            statusPreview(
                symbol: "xmark.circle",
                message: "Video export was cancelled."
            )
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch renderState {
        case .ready(.image(let result)):
            sharingActions(
                instagramAction: {
                    Task { await shareImageToInstagram(result.image) }
                },
                shareLink: {
                    ShareLink(
                        item: JamStoryImageExport(data: result.pngData),
                        preview: SharePreview(
                            snapshot.jamName,
                            image: Image(uiImage: result.image)
                        )
                    ) {
                        shareLabel
                    }
                }
            )
        case .ready(.video(let result)):
            sharingActions(
                instagramAction: {
                    Task { await shareVideoToInstagram(result.fileURL) }
                },
                shareLink: {
                    ShareLink(
                        item: JamStoryVideoExport(fileURL: result.fileURL),
                        preview: SharePreview(snapshot.jamName)
                    ) {
                        shareLabel
                    }
                }
            )
        case .preparing:
            Button(action: cancelExport) {
                Label("Cancel", systemImage: "xmark")
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(JamStorySecondaryButtonStyle())
        case .idle, .failed, .cancelled:
            Button(action: prepareSelectedFormat) {
                Text("Try Again")
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(JamStorySecondaryButtonStyle())
        }
    }

    private func sharingActions<ShareContent: View>(
        instagramAction: @escaping () -> Void,
        @ViewBuilder shareLink: () -> ShareContent
    ) -> some View {
        let instagramAvailable = instagramExporter.isInstagramStoriesAvailable

        return VStack(spacing: 10) {
            Button(action: instagramAction) {
                Label(
                    instagramAvailable ? "Share to Instagram" : "Instagram Not Installed",
                    systemImage: "camera"
                )
                .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(JamStoryPrimaryButtonStyle())
            .opacity(instagramAvailable ? 1 : 0.58)
            .accessibilityHint(
                instagramAvailable
                    ? "Opens Instagram Stories."
                    : "Shows an Instagram availability message."
            )

            shareLink()
                .buttonStyle(JamStorySecondaryButtonStyle())
        }
    }

    private var shareLabel: some View {
        Label("Share…", systemImage: "square.and.arrow.up")
            .frame(maxWidth: .infinity, minHeight: 52)
    }

    private func statusPreview(symbol: String, message: String) -> some View {
        previewFrame {
            VStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .semibold))
                Text(message)
                    .font(.custom("ZTTalk-Bold", size: 16, relativeTo: .subheadline))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white.opacity(0.78))
            .padding(24)
        }
    }

    private func previewFrame<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack {
            LinearGradient(
                colors: [.black.opacity(0.88), .black.opacity(0.68)],
                startPoint: .top,
                endPoint: .bottom
            )
            content()
        }
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    @MainActor
    private func prepareSelectedFormat() {
        guard renderTask == nil else { return }
        releasePlayer()
        cleanupReadyVideo()
        renderState = .preparing
        let format = selectedFormat

        renderTask = Task {
            do {
                switch format {
                case .image:
                    let result = try await imageRenderer.render(snapshot: snapshot)
                    try Task.checkCancellation()
                    renderState = .ready(.image(result))
                case .video:
                    let result = try await videoRenderer.render(snapshot: snapshot)
                    try Task.checkCancellation()
                    player = AVPlayer(url: result.fileURL)
                    renderState = .ready(.video(result))
                }
            } catch is CancellationError {
                renderState = .cancelled
            } catch JamStoryVideoExportError.cancelled {
                renderState = .cancelled
            } catch {
                renderState = .failed(
                    (error as? LocalizedError)?.errorDescription
                        ?? "Could not prepare this story export."
                )
            }
            renderTask = nil
        }
    }

    @MainActor
    private func resetAndPrepareSelectedFormat() {
        guard !renderState.isPreparing else { return }
        releasePlayer()
        cleanupReadyVideo()
        renderState = .idle
        prepareSelectedFormat()
    }

    @MainActor
    private func cancelExport() {
        renderTask?.cancel()
    }

    @MainActor
    private func close() {
        cancelAndCleanup()
        isPresented = false
    }

    @MainActor
    private func cancelAndCleanup() {
        renderTask?.cancel()
        renderTask = nil
        releasePlayer()
        cleanupReadyVideo()
    }

    @MainActor
    private func releasePlayer() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    @MainActor
    private func cleanupReadyVideo() {
        guard case .ready(.video(let result)) = renderState else { return }
        JamStoryVideoRenderer.removeExport(at: result.fileURL)
    }

    @MainActor
    private func shareImageToInstagram(_ image: UIImage) async {
        do {
            try await instagramExporter.export(backgroundImage: image)
        } catch let error as InstagramStoryExportError {
            instagramError = error
        } catch {
            instagramError = .openFailed
        }
    }

    @MainActor
    private func shareVideoToInstagram(_ fileURL: URL) async {
        do {
            try await instagramExporter.export(backgroundVideoAt: fileURL)
        } catch let error as InstagramStoryExportError {
            instagramError = error
        } catch {
            instagramError = .openFailed
        }
    }

    private var instagramErrorPresented: Binding<Bool> {
        Binding(
            get: { instagramError != nil },
            set: { if !$0 { instagramError = nil } }
        )
    }

    private enum RenderState {
        case idle
        case preparing
        case ready(ExportResult)
        case failed(String)
        case cancelled

        var isPreparing: Bool {
            if case .preparing = self { true } else { false }
        }
    }

    private enum ExportResult {
        case image(JamStoryRenderResult)
        case video(JamStoryVideoRenderResult)
    }
}

private struct JamStoryImageExport: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { export in
            export.data
        }
    }
}

private struct JamStoryVideoExport: Transferable {
    let fileURL: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .mpeg4Movie) { export in
            SentTransferredFile(export.fileURL)
        }
    }
}

private struct JamStoryPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom("ZTTalk-Bold", size: 17, relativeTo: .headline))
            .foregroundStyle(.white)
            .background(
                Color.black.opacity(isEnabled ? (configuration.isPressed ? 0.78 : 0.92) : 0.34),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
    }
}

private struct JamStorySecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom("ZTTalk-Bold", size: 17, relativeTo: .headline))
            .foregroundStyle(.primary)
            .background(
                Color.secondary.opacity(configuration.isPressed ? 0.18 : 0.12),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
    }
}
