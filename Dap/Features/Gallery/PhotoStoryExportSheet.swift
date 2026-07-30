import SwiftUI
import UIKit

struct PhotoStoryExportSnapshot: Identifiable, Sendable {
    struct Note: Identifiable, Sendable {
        let step: Int
        let row: Int

        var id: String { "\(step)-\(row)" }
    }

    let id: UUID
    let imageData: Data
    let title: String
    let root: String
    let scale: String
    let bpm: Int
    let notes: [Note]
    let palette: ColorPalette
}

struct PhotoStoryExportSheet: View {
    let snapshot: PhotoStoryExportSnapshot

    @Environment(\.dismiss) private var dismiss
    @State private var phase = Phase.preparing
    @State private var result: PhotoStoryRenderResult?
    @State private var errorMessage: String?

    private let renderer = PhotoStoryRenderer()
    private let instagramExporter = InstagramStoryExporter()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header

                content
            }
        }
        .task {
            await prepare()
        }
    }

    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")

            Spacer(minLength: 0)

            Text("Share Photo")
                .font(.custom("ZTTalk-Bold", size: 18, relativeTo: .headline))

            Spacer(minLength: 0)

            Color.clear
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .preparing:
            VStack(spacing: 14) {
                ProgressView()
                Text("Preparing story image")
                    .font(.custom("ZTTalk-Bold", size: 16, relativeTo: .subheadline))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            if let result {
                PhotoStoryReadyView(
                    title: snapshot.title,
                    result: result,
                    isInstagramAvailable: instagramExporter.isInstagramStoriesAvailable,
                    onInstagram: { Task { await shareToInstagram(result.image) } }
                )
            }
        case .failed:
            StoryExportErrorView(
                message: errorMessage ?? "Could not prepare this photo story.",
                onTryAgain: { Task { await prepare() } }
            )
        }
    }

    @MainActor
    private func prepare() async {
        phase = .preparing
        errorMessage = nil

        do {
            let rendered = try await renderer.render(snapshot: snapshot)
            guard !Task.isCancelled else { return }
            result = rendered
            phase = .ready
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Could not prepare this photo story."
            phase = .failed
        }
    }

    @MainActor
    private func shareToInstagram(_ image: UIImage) async {
        do {
            try await instagramExporter.export(backgroundImage: image)
        } catch let error as InstagramStoryExportError {
            errorMessage = error.localizedDescription
            phase = .failed
        } catch {
            errorMessage = InstagramStoryExportError.openFailed.localizedDescription
            phase = .failed
        }
    }

    private enum Phase {
        case preparing
        case ready
        case failed
    }
}

private struct PhotoStoryReadyView: View {
    let title: String
    let result: PhotoStoryRenderResult
    let isInstagramAvailable: Bool
    let onInstagram: () -> Void

    var body: some View {
        VStack(spacing: 18) {
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

            StoryShareActions(
                isInstagramAvailable: isInstagramAvailable,
                onInstagram: onInstagram
            ) {
                ShareLink(
                    item: StoryImageExport(data: result.pngData),
                    preview: SharePreview(title, image: Image(uiImage: result.image))
                ) {
                    Label("Share...", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 28)
    }
}

struct StoryExportErrorView: View {
    let message: String
    let onTryAgain: () -> Void

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

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 28)
    }
}

struct PhotoStoryRenderResult {
    let image: UIImage
    let pngData: Data
    let pixelSize: CGSize
}

enum PhotoStoryRenderError: Error, LocalizedError {
    case invalidImage
    case renderFailed
    case pngEncodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            "Could not read this photo's image."
        case .renderFailed:
            "Could not render this photo story."
        case .pngEncodingFailed:
            "Could not prepare this photo story for sharing."
        }
    }
}

struct PhotoStoryRenderer {
    static let outputPixelSize = CGSize(width: 1080, height: 1920)

    @MainActor
    func render(snapshot: PhotoStoryExportSnapshot) async throws -> PhotoStoryRenderResult {
        guard let image = UIImage(data: snapshot.imageData, scale: 1) else {
            throw PhotoStoryRenderError.invalidImage
        }

        let content = PhotoStoryExportView(snapshot: snapshot, image: image)
            .frame(width: Self.outputPixelSize.width, height: Self.outputPixelSize.height)
            .environment(\.colorScheme, .dark)
            .environment(\.displayScale, 1)

        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(Self.outputPixelSize)
        renderer.scale = 1
        renderer.isOpaque = true

        guard let renderedImage = renderer.uiImage,
              let cgImage = renderedImage.cgImage else {
            throw PhotoStoryRenderError.renderFailed
        }
        guard let pngData = renderedImage.pngData() else {
            throw PhotoStoryRenderError.pngEncodingFailed
        }

        return PhotoStoryRenderResult(
            image: renderedImage,
            pngData: pngData,
            pixelSize: CGSize(width: cgImage.width, height: cgImage.height)
        )
    }
}

private struct PhotoStoryExportView: View {
    let snapshot: PhotoStoryExportSnapshot
    let image: UIImage

    var body: some View {
        ZStack {
            background

            VStack(alignment: .leading, spacing: 38) {
                titleBlock

                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 708, height: 844)
                    .clipShape(RoundedRectangle(cornerRadius: 42, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 42, style: .continuous)
                            .stroke(.white.opacity(0.18), lineWidth: 2)
                    }
                    .shadow(color: .black.opacity(0.34), radius: 48, y: 30)
                    .frame(maxWidth: .infinity)

                facts

                sequencer

                Spacer(minLength: 0)

                signature
            }
            .padding(.top, 180)
            .padding(.horizontal, 82)
            .padding(.bottom, 190)
        }
        .frame(width: PhotoStoryRenderer.outputPixelSize.width, height: PhotoStoryRenderer.outputPixelSize.height)
        .environment(\.colorScheme, .dark)
    }

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(jamRGB: snapshot.palette.shadow),
                    Color(jamRGB: snapshot.palette.dark).opacity(0.92),
                    Color(jamRGB: snapshot.palette.base).opacity(0.74)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            LinearGradient(
                colors: [.black.opacity(0.06), .black.opacity(0.36)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("DAP PHOTO")
                .font(.custom("ZTTalk-Bold", size: 24, relativeTo: .caption))
                .tracking(3.8)
                .foregroundStyle(.white.opacity(0.52))

            Text(snapshot.title)
                .font(.custom("ZTTalk-Bold", size: 82, relativeTo: .largeTitle))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
        }
    }

    private var facts: some View {
        HStack(spacing: 14) {
            fact("ROOT", snapshot.root)
            fact("SCALE", snapshot.scale)
            fact("BPM", "\(snapshot.bpm)")
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.custom("ZTTalk-Bold", size: 16, relativeTo: .caption))
                .tracking(1.1)
                .foregroundStyle(.white.opacity(0.48))
            Text(value)
                .font(.custom("ZTTalk-Bold", size: 27, relativeTo: .headline))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sequencer: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("SEQUENCE")
                .font(.custom("ZTTalk-Bold", size: 22, relativeTo: .headline))
                .tracking(1.4)
                .foregroundStyle(.white)

            VStack(spacing: 8) {
                ForEach((0..<MusicSequence.rows).reversed(), id: \.self) { row in
                    HStack(spacing: 5) {
                        ForEach(0..<MusicSequence.steps, id: \.self) { step in
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(isActive(step: step, row: row) ? Color(jamRGB: snapshot.palette.highlight).opacity(0.92) : .white.opacity(0.14))
                                .frame(maxWidth: .infinity)
                                .frame(height: 12)
                        }
                    }
                }
            }
        }
        .padding(26)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 1.5)
        }
    }

    private var signature: some View {
        Text("Made with Dap")
            .font(.custom("ZTTalk-Bold", size: 24, relativeTo: .footnote))
            .foregroundStyle(.white.opacity(0.62))
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private func isActive(step: Int, row: Int) -> Bool {
        snapshot.notes.contains { $0.step == step && $0.row == row }
    }
}
