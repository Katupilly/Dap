import SwiftUI
import UIKit

struct JamStoryRenderResult {
    let image: UIImage
    let pngData: Data
    let pixelSize: CGSize
}

enum JamStoryRenderError: Error, Equatable {
    case jamCoverRenderFailed
    case renderFailed
    case pngEncodingFailed
    case unexpectedPixelSize(width: Int, height: Int)
}

struct JamStoryRenderer {
    static let outputPixelSize = JamStoryExportLayout.canvasSize

    @MainActor
    func render(
        snapshot: JamStoryExportSnapshot,
        template: StoryShareTemplate = .dap,
        currentStep: Int? = nil,
        pulse: CGFloat = 0
    ) async throws -> JamStoryRenderResult {
        let coverData = await JamCoverRenderer.shared.data(
            for: snapshot.coverDescriptor,
            size: CGSize(width: 720, height: 720),
            scale: 1
        )
        guard let coverImage = UIImage(data: coverData, scale: 1) else {
            throw JamStoryRenderError.jamCoverRenderFailed
        }

        if template == .plain {
            let content = JamPlainStoryExportView(coverImage: coverImage)
                .frame(width: Self.outputPixelSize.width, height: Self.outputPixelSize.height)
                .environment(\.colorScheme, .dark)
                .environment(\.displayScale, 1)
            let renderer = ImageRenderer(content: content)
            renderer.proposedSize = ProposedViewSize(Self.outputPixelSize)
            renderer.scale = 1
            renderer.isOpaque = true

            guard let image = renderer.uiImage,
                  let cgImage = image.cgImage else {
                throw JamStoryRenderError.renderFailed
            }
            guard let pngData = image.pngData() else {
                throw JamStoryRenderError.pngEncodingFailed
            }
            return JamStoryRenderResult(
                image: image,
                pngData: pngData,
                pixelSize: CGSize(width: cgImage.width, height: cgImage.height)
            )
        }

        let photoImagesByID = Dictionary(
            uniqueKeysWithValues: snapshot.photos.compactMap { photo in
                photo.imageData.flatMap { UIImage(data: $0, scale: 1) }.map { (photo.id, $0) }
            }
        )

        let content = JamSnippetExportView(
            snapshot: snapshot,
            coverImage: coverImage,
            photoImagesByID: photoImagesByID,
            currentStep: currentStep,
            pulse: pulse
        )
            .frame(width: Self.outputPixelSize.width, height: Self.outputPixelSize.height)
            .environment(\.colorScheme, .dark)
            .environment(\.displayScale, 1)

        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(Self.outputPixelSize)
        renderer.scale = 1
        renderer.isOpaque = true

        guard let image = renderer.uiImage else {
            throw JamStoryRenderError.renderFailed
        }
        guard let cgImage = image.cgImage else {
            throw JamStoryRenderError.renderFailed
        }
        guard cgImage.width == Int(Self.outputPixelSize.width),
              cgImage.height == Int(Self.outputPixelSize.height) else {
            throw JamStoryRenderError.unexpectedPixelSize(width: cgImage.width, height: cgImage.height)
        }
        guard let pngData = image.pngData() else {
            throw JamStoryRenderError.pngEncodingFailed
        }

        return JamStoryRenderResult(
            image: image,
            pngData: pngData,
            pixelSize: CGSize(width: cgImage.width, height: cgImage.height)
        )
    }
}

private struct JamPlainStoryExportView: View {
    let coverImage: UIImage

    var body: some View {
        Image(uiImage: coverImage)
            .resizable()
            .scaledToFill()
            .frame(width: JamStoryExportLayout.canvasSize.width, height: JamStoryExportLayout.canvasSize.height)
            .clipped()
    }
}
