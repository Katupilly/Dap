import CoreGraphics
import CoreVideo
import Foundation

struct JamStoryVideoTemplate: Sendable {
    let snapshot: JamStoryExportSnapshot
    let baseImage: CGImage
    let template: StoryShareTemplate

    func render(
        into pixelBuffer: CVPixelBuffer,
        time: Double,
        stepDuration: Double
    ) throws {
        let size = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        let stepPosition = time / stepDuration
        let currentStep = Int(floor(stepPosition)) % MusicSequence.steps
        let stepProgress = stepPosition - floor(stepPosition)
        let pulse = CGFloat(1 - stepProgress)

        let layout = JamStoryExportLayout(canvasSize: size)
        try Self.copy(baseImage, into: pixelBuffer)

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let context = Self.makeContext(for: pixelBuffer) else {
            throw JamStoryVideoExportError.frameRenderingFailed
        }

        context.saveGState()
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        if template == .dap {
            drawPlayhead(step: currentStep, pulse: pulse, in: context, layout: layout)
            drawActiveRolePulses(
                step: currentStep,
                pulse: pulse,
                in: context,
                layout: layout
            )
        }
        context.restoreGState()
        context.flush()
    }

    private static func copy(_ baseImage: CGImage, into pixelBuffer: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let context = makeContext(for: pixelBuffer) else {
            throw JamStoryVideoExportError.frameRenderingFailed
        }

        let size = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        context.interpolationQuality = .high
        // ImageRenderer already supplies the static frame in the export's
        // visual orientation. Keep the Core Graphics conversion local to the
        // top-left overlay coordinates instead of flipping the base image.
        context.draw(baseImage, in: CGRect(origin: .zero, size: size))
        context.flush()
    }

    private static func makeContext(for pixelBuffer: CVPixelBuffer) -> CGContext? {
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }

        return CGContext(
            data: baseAddress,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )
    }

#if DEBUG
    static func validateDiagnosticFrame(into pixelBuffer: CVPixelBuffer) throws {
        let size = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )

        guard let baseImage = makeDiagnosticBaseImage(size: size) else {
            throw JamStoryVideoExportError.frameRenderingFailed
        }
        try copy(baseImage, into: pixelBuffer)

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard let context = makeContext(for: pixelBuffer) else {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            throw JamStoryVideoExportError.frameRenderingFailed
        }
        drawDiagnosticOverlays(size: size, in: context)
        context.flush()
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        let layout = JamStoryExportLayout(canvasSize: size)
        let baseMarkers = diagnosticBaseMarkers(for: size)
        let overlayMarkers = diagnosticMarkers(for: layout)

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let expectedColors: [(point: CGPoint, color: (red: UInt8, green: UInt8, blue: UInt8))] = [
            (baseMarkers.top.midPoint, DiagnosticColor.top),
            (baseMarkers.bottom.midPoint, DiagnosticColor.bottom),
            (baseMarkers.topLeft.midPoint, DiagnosticColor.topLeft),
            (baseMarkers.topRight.midPoint, DiagnosticColor.topRight),
            (baseMarkers.bottomLeft.midPoint, DiagnosticColor.bottomLeft),
            (baseMarkers.bottomRight.midPoint, DiagnosticColor.bottomRight),
            (overlayMarkers.sequencer.midPoint, DiagnosticColor.sequencer),
            (overlayMarkers.photo.midPoint, DiagnosticColor.photo)
        ]
        guard expectedColors.allSatisfy({ marker in
            isColor(pixelBufferColor(at: marker.point, in: pixelBuffer), closeTo: marker.color)
        }), expectedColors.allSatisfy({ marker in
            !isColor(
                pixelBufferColor(
                    at: CGRect(origin: marker.point, size: .zero).mirrored(in: size),
                    in: pixelBuffer
                ),
                closeTo: marker.color
            )
        }) else {
            throw JamStoryVideoExportError.frameRenderingFailed
        }
    }

    private static func makeDiagnosticBaseImage(size: CGSize) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: Int(size.width) * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }

        let markers = diagnosticBaseMarkers(for: size)
        context.saveGState()
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(gray: 0.08, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))

        fillDiagnosticMarker(DiagnosticColor.topColor, rect: markers.top, in: context)
        fillDiagnosticMarker(DiagnosticColor.bottomColor, rect: markers.bottom, in: context)
        fillDiagnosticMarker(DiagnosticColor.topLeftColor, rect: markers.topLeft, in: context)
        fillDiagnosticMarker(DiagnosticColor.topRightColor, rect: markers.topRight, in: context)
        fillDiagnosticMarker(DiagnosticColor.bottomLeftColor, rect: markers.bottomLeft, in: context)
        fillDiagnosticMarker(DiagnosticColor.bottomRightColor, rect: markers.bottomRight, in: context)
        context.restoreGState()
        return context.makeImage()
    }

    private static func drawDiagnosticOverlays(size: CGSize, in context: CGContext) {
        let layout = JamStoryExportLayout(canvasSize: size)
        let markers = diagnosticMarkers(for: layout)

        context.saveGState()
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        fillDiagnosticMarker(DiagnosticColor.sequencerColor, rect: markers.sequencer, in: context)
        fillDiagnosticMarker(DiagnosticColor.photoColor, rect: markers.photo, in: context)
        context.restoreGState()
    }

    private static func fillDiagnosticMarker(_ color: CGColor, rect: CGRect, in context: CGContext) {
        context.setFillColor(color)
        context.fill(rect)
    }

    private static func diagnosticMarkers(
        for layout: JamStoryExportLayout
    ) -> (top: CGRect, sequencer: CGRect, photo: CGRect) {
        (
            top: CGRect(x: 40, y: 180, width: 80, height: 80),
            sequencer: CGRect(
                x: layout.sequencerGridRect.minX + 20,
                y: layout.sequencerGridRect.minY + 20,
                width: 48,
                height: 24
            ),
            photo: layout.photoRect(at: 0, count: 3).insetBy(dx: 20, dy: 20)
        )
    }

    private static func diagnosticBaseMarkers(
        for size: CGSize
    ) -> (
        top: CGRect,
        bottom: CGRect,
        topLeft: CGRect,
        topRight: CGRect,
        bottomLeft: CGRect,
        bottomRight: CGRect
    ) {
        let cornerSize = min(96, min(size.width, size.height) * 0.08)
        let edgeInset: CGFloat = 24
        let bandWidth = size.width * 0.46
        let bandHeight = max(48, min(88, size.height * 0.05))
        let bandX = (size.width - bandWidth) / 2

        return (
            top: CGRect(x: bandX, y: 56, width: bandWidth, height: bandHeight),
            bottom: CGRect(
                x: bandX,
                y: size.height - 56 - bandHeight,
                width: bandWidth,
                height: bandHeight
            ),
            topLeft: CGRect(x: edgeInset, y: edgeInset, width: cornerSize, height: cornerSize),
            topRight: CGRect(
                x: size.width - edgeInset - cornerSize,
                y: edgeInset,
                width: cornerSize,
                height: cornerSize
            ),
            bottomLeft: CGRect(
                x: edgeInset,
                y: size.height - edgeInset - cornerSize,
                width: cornerSize,
                height: cornerSize
            ),
            bottomRight: CGRect(
                x: size.width - edgeInset - cornerSize,
                y: size.height - edgeInset - cornerSize,
                width: cornerSize,
                height: cornerSize
            )
        )
    }

    private static func pixelBufferColor(
        at point: CGPoint,
        in pixelBuffer: CVPixelBuffer
    ) -> (red: UInt8, green: UInt8, blue: UInt8)? {
        let x = Int(point.x.rounded())
        let y = Int(point.y.rounded())
        guard x >= 0, x < CVPixelBufferGetWidth(pixelBuffer),
              y >= 0, y < CVPixelBufferGetHeight(pixelBuffer) else {
            return nil
        }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }
        let offset = y * CVPixelBufferGetBytesPerRow(pixelBuffer) + x * 4
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        return (red: bytes[offset + 2], green: bytes[offset + 1], blue: bytes[offset])
    }

    private static func isColor(
        _ color: (red: UInt8, green: UInt8, blue: UInt8)?,
        closeTo expected: (red: UInt8, green: UInt8, blue: UInt8)
    ) -> Bool {
        guard let color else { return false }
        return abs(Int(color.red) - Int(expected.red)) < 8
            && abs(Int(color.green) - Int(expected.green)) < 8
            && abs(Int(color.blue) - Int(expected.blue)) < 8
    }

    private enum DiagnosticColor {
        static let top = (red: UInt8(255), green: UInt8(128), blue: UInt8(0))
        static let bottom = (red: UInt8(0), green: UInt8(255), blue: UInt8(128))
        static let topLeft = (red: UInt8(255), green: UInt8(0), blue: UInt8(0))
        static let topRight = (red: UInt8(0), green: UInt8(255), blue: UInt8(0))
        static let bottomLeft = (red: UInt8(0), green: UInt8(0), blue: UInt8(255))
        static let bottomRight = (red: UInt8(255), green: UInt8(0), blue: UInt8(255))
        static let sequencer = (red: UInt8(255), green: UInt8(255), blue: UInt8(0))
        static let photo = (red: UInt8(0), green: UInt8(255), blue: UInt8(255))

        static var topColor: CGColor {
            CGColor(red: 1, green: 0.5, blue: 0, alpha: 1)
        }

        static var bottomColor: CGColor {
            CGColor(red: 0, green: 1, blue: 0.5, alpha: 1)
        }

        static var topLeftColor: CGColor {
            CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        }

        static var topRightColor: CGColor {
            CGColor(red: 0, green: 1, blue: 0, alpha: 1)
        }

        static var bottomLeftColor: CGColor {
            CGColor(red: 0, green: 0, blue: 1, alpha: 1)
        }

        static var bottomRightColor: CGColor {
            CGColor(red: 1, green: 0, blue: 1, alpha: 1)
        }

        static var sequencerColor: CGColor {
            CGColor(red: 1, green: 1, blue: 0, alpha: 1)
        }

        static var photoColor: CGColor {
            CGColor(red: 0, green: 1, blue: 1, alpha: 1)
        }
    }

#endif

    private func drawPlayhead(
        step: Int,
        pulse: CGFloat,
        in context: CGContext,
        layout: JamStoryExportLayout
    ) {
        let stepWidth = layout.sequencerGridWidth / CGFloat(MusicSequence.steps)
        let x = layout.sequencerGridX + CGFloat(step) * stepWidth
        let glowRect = CGRect(
            x: x + 4,
            y: layout.sequencerGridRect.minY - 8,
            width: stepWidth - 8,
            height: layout.sequencerGridHeight + 16
        )
        let lineRect = CGRect(
            x: x + stepWidth * 0.5 - 3,
            y: layout.sequencerGridRect.minY - 14,
            width: 6,
            height: layout.sequencerGridHeight + 28
        )
#if DEBUG
        let playheadRect = glowRect.union(lineRect)
        assert(layout.sequencerRect.minY > layout.heroImageRect.maxY)
        assert(playheadRect.intersects(layout.sequencerRect))
        assert(!playheadRect.intersects(layout.heroImageRect))
#endif

        context.setFillColor(CGColor(gray: 1, alpha: 0.10 + pulse * 0.10))
        context.fillRoundedRect(glowRect, radius: 12)
        context.setFillColor(CGColor(gray: 1, alpha: 0.58 + pulse * 0.26))
        context.fillRoundedRect(lineRect, radius: 3)
    }

    private func drawActiveRolePulses(
        step: Int,
        pulse: CGFloat,
        in context: CGContext,
        layout: JamStoryExportLayout
    ) {
        let activeRoles = Set(
            JamRole.allCases.filter { role in
                snapshot.sequencerSnapshot.steps(for: role).contains(step)
            }
        )
        guard !activeRoles.isEmpty else { return }

        for (index, photo) in snapshot.photos.enumerated() {
            guard let role = photo.role, activeRoles.contains(role) else { continue }

            let expansion = 3 + pulse * 7
            let photoRect = layout.photoRect(at: index, count: snapshot.photos.count)
            let pulseRect = photoRect
                .insetBy(dx: -expansion, dy: -expansion)
#if DEBUG
            assert(pulseRect.intersects(photoRect))
            assert(!pulseRect.intersects(layout.heroImageRect))
#endif

            context.setStrokeColor(photo.accentColor.cgColor(alpha: 0.34 + pulse * 0.28))
            context.setLineWidth(3 + pulse * 2)
            context.strokeRoundedRect(pulseRect, radius: 28 + expansion)
        }
    }
}

private extension CGRect {
    var midPoint: CGPoint {
        CGPoint(x: midX, y: midY)
    }

    func mirrored(in size: CGSize) -> CGPoint {
        CGPoint(x: midX, y: size.height - midY)
    }
}

private extension CGContext {
    func fillRoundedRect(_ rect: CGRect, radius: CGFloat) {
        addPath(CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        ))
        fillPath()
    }

    func strokeRoundedRect(_ rect: CGRect, radius: CGFloat) {
        addPath(CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        ))
        strokePath()
    }
}

private extension RGBColor {
    func cgColor(alpha: CGFloat) -> CGColor {
        CGColor(
            red: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: alpha
        )
    }
}
