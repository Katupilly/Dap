import CoreGraphics
import CoreVideo
import Foundation
import SwiftUI
import UIKit

struct JamStoryVideoTemplate: Sendable {
    let snapshot: JamStoryExportSnapshot
    let coverImageData: Data
    let photoImageDataByID: [UUID: Data]
    let template: StoryShareTemplate

    @MainActor
    func render(
        into pixelBuffer: CVPixelBuffer,
        time: Double,
        stepDuration: Double
    ) throws {
        let stepPosition = time / stepDuration
        let currentStep = Int(floor(stepPosition)) % MusicSequence.steps
        let stepProgress = stepPosition - floor(stepPosition)
        let pulse = CGFloat(1 - stepProgress)
        let frameImage = try renderedFrame(
            currentStep: currentStep,
            stepProgress: stepProgress,
            pulse: pulse
        )
        try Self.copy(frameImage, into: pixelBuffer)
    }

    @MainActor
    private func renderedFrame(
        currentStep: Int,
        stepProgress: Double,
        pulse: CGFloat
    ) throws -> CGImage {
        guard let coverImage = UIImage(data: coverImageData, scale: 1) else {
            throw JamStoryVideoExportError.frameRenderingFailed
        }

        let photoImagesByID = Dictionary(
            uniqueKeysWithValues: photoImageDataByID.compactMap { id, data in
                UIImage(data: data, scale: 1).map { (id, $0) }
            }
        )

        let content: AnyView
        switch template {
        case .plain:
            content = AnyView(
                JamPlainStoryVideoFrame(coverImage: coverImage)
                    .frame(
                        width: JamStoryExportLayout.canvasSize.width,
                        height: JamStoryExportLayout.canvasSize.height
                    )
                    .environment(\.colorScheme, .dark)
            )
        case .dap:
            let activeRoles = Set(
                JamRole.allCases.filter {
                    snapshot.sequencerSnapshot.steps(for: $0).contains(currentStep)
                }
            )
            content = AnyView(
                JamSnippetExportView(
                    snapshot: snapshot,
                    photoImagesByID: photoImagesByID,
                    frameState: JamSnippetFrameState(
                        currentStep: currentStep,
                        stepProgress: stepProgress,
                        activeRoles: activeRoles,
                        pulseIntensity: Double(pulse)
                    )
                )
            )
        }

        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(JamStoryExportLayout.canvasSize)
        renderer.scale = 1
        renderer.isOpaque = true

        guard let image = renderer.uiImage,
              let cgImage = image.cgImage else {
            throw JamStoryVideoExportError.frameRenderingFailed
        }
        return cgImage
    }

    private static func copy(_ image: CGImage, into pixelBuffer: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(
                  data: baseAddress,
                  width: CVPixelBufferGetWidth(pixelBuffer),
                  height: CVPixelBufferGetHeight(pixelBuffer),
                  bitsPerComponent: 8,
                  bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            throw JamStoryVideoExportError.frameRenderingFailed
        }

        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(
                x: 0,
                y: 0,
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer)
            )
        )
        context.flush()
    }
}

private struct JamPlainStoryVideoFrame: View {
    let coverImage: UIImage

    var body: some View {
        Image(uiImage: coverImage)
            .resizable()
            .scaledToFill()
            .frame(
                width: JamStoryExportLayout.canvasSize.width,
                height: JamStoryExportLayout.canvasSize.height
            )
            .clipped()
    }
}
