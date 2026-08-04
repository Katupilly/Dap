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

        guard let frameImage = makeFrameImage(
            size: size,
            currentStep: currentStep,
            pulse: pulse
        ) else {
            throw JamStoryVideoExportError.frameRenderingFailed
        }

        try Self.copy(frameImage, into: pixelBuffer)
    }

    static func copy(_ frameImage: CGImage, into pixelBuffer: CVPixelBuffer) throws {
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
        context.saveGState()
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(frameImage, in: CGRect(origin: .zero, size: size))
        context.restoreGState()
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

    private func makeFrameImage(
        size: CGSize,
        currentStep: Int,
        pulse: CGFloat
    ) -> CGImage? {
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

        context.interpolationQuality = .high
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(baseImage, in: CGRect(origin: .zero, size: size))
        if template == .dap {
            drawPlayhead(step: currentStep, pulse: pulse, in: context)
            drawActiveRolePulses(step: currentStep, pulse: pulse, in: context)
        }
        return context.makeImage()
    }

#if DEBUG
    static func validateDiagnosticFrameCopy(into pixelBuffer: CVPixelBuffer) throws {
        let size = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        guard let diagnosticFrame = makeDiagnosticFrameImage(size: size),
              hasExpectedDiagnosticCorners(in: diagnosticFrame) else {
            throw JamStoryVideoExportError.frameRenderingFailed
        }

        try copy(diagnosticFrame, into: pixelBuffer)

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard isColor(pixelBufferColor(atX: 40, y: 40, in: pixelBuffer), closeTo: DiagnosticColor.topLeft),
              isColor(pixelBufferColor(atX: Int(size.width) - 40, y: 40, in: pixelBuffer), closeTo: DiagnosticColor.topRight),
              isColor(pixelBufferColor(atX: 40, y: Int(size.height) - 40, in: pixelBuffer), closeTo: DiagnosticColor.bottomLeft),
              isColor(pixelBufferColor(atX: Int(size.width) - 40, y: Int(size.height) - 40, in: pixelBuffer), closeTo: DiagnosticColor.bottomRight) else {
            throw JamStoryVideoExportError.frameRenderingFailed
        }
    }

    private static func makeDiagnosticFrameImage(size: CGSize) -> CGImage? {
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

        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(gray: 0.08, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))

        fillDiagnosticMarker(DiagnosticColor.topLeftColor, rect: CGRect(x: 0, y: 0, width: 120, height: 120), in: context)
        fillDiagnosticMarker(DiagnosticColor.topRightColor, rect: CGRect(x: size.width - 120, y: 0, width: 120, height: 120), in: context)
        fillDiagnosticMarker(DiagnosticColor.bottomLeftColor, rect: CGRect(x: 0, y: size.height - 120, width: 120, height: 120), in: context)
        fillDiagnosticMarker(DiagnosticColor.bottomRightColor, rect: CGRect(x: size.width - 120, y: size.height - 120, width: 120, height: 120), in: context)

        drawDiagnosticWord("TOP", x: 150, y: 40, in: context)
        drawDiagnosticWord("BOTTOM", x: size.width - 540, y: size.height - 104, in: context)
        context.setFillColor(CGColor(gray: 1, alpha: 0.72))
        context.fillRoundedRect(CGRect(x: Layout.sequencerX, y: Layout.sequencerY, width: Layout.sequencerWidth, height: Layout.sequencerHeight), radius: 18)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 0, alpha: 1))
        context.fillRoundedRect(CGRect(x: Layout.sequencerX + 240, y: Layout.sequencerY - 10, width: 16, height: Layout.sequencerHeight + 20), radius: 8)
        context.setStrokeColor(CGColor(red: 0, green: 1, blue: 1, alpha: 1))
        context.setLineWidth(8)
        context.strokeRoundedRect(Layout.photoRect(at: 0, count: 3), radius: 28)
        return context.makeImage()
    }

    private static func fillDiagnosticMarker(_ color: CGColor, rect: CGRect, in context: CGContext) {
        context.setFillColor(color)
        context.fill(rect)
    }

    private static func hasExpectedDiagnosticCorners(in image: CGImage) -> Bool {
        isColor(imageColor(atX: 40, y: 40, in: image), closeTo: DiagnosticColor.topLeft)
            && isColor(imageColor(atX: image.width - 40, y: 40, in: image), closeTo: DiagnosticColor.topRight)
            && isColor(imageColor(atX: 40, y: image.height - 40, in: image), closeTo: DiagnosticColor.bottomLeft)
            && isColor(imageColor(atX: image.width - 40, y: image.height - 40, in: image), closeTo: DiagnosticColor.bottomRight)
    }

    private static func drawDiagnosticWord(
        _ word: String,
        x: CGFloat,
        y: CGFloat,
        in context: CGContext
    ) {
        let scale: CGFloat = 12
        let glyphWidth: CGFloat = 5 * scale
        context.setFillColor(CGColor(gray: 1, alpha: 1))

        for (characterIndex, character) in word.enumerated() {
            guard let rows = diagnosticGlyphs[character] else { continue }
            for (row, bits) in rows.enumerated() {
                for column in 0..<5 where bits & (1 << (4 - column)) != 0 {
                    context.fill(CGRect(
                        x: x + CGFloat(characterIndex) * (glyphWidth + scale) + CGFloat(column) * scale,
                        y: y + CGFloat(row) * scale,
                        width: scale,
                        height: scale
                    ))
                }
            }
        }
    }

    private static func imageColor(
        atX x: Int,
        y: Int,
        in image: CGImage
    ) -> (red: UInt8, green: UInt8, blue: UInt8)? {
        guard let data = image.dataProvider?.data,
              let pointer = CFDataGetBytePtr(data) else {
            return nil
        }
        let offset = y * image.bytesPerRow + x * 4
        return (red: pointer[offset + 2], green: pointer[offset + 1], blue: pointer[offset])
    }

    private static func pixelBufferColor(
        atX x: Int,
        y: Int,
        in pixelBuffer: CVPixelBuffer
    ) -> (red: UInt8, green: UInt8, blue: UInt8)? {
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
        static let topLeft = (red: UInt8(255), green: UInt8(0), blue: UInt8(0))
        static let topRight = (red: UInt8(0), green: UInt8(255), blue: UInt8(0))
        static let bottomLeft = (red: UInt8(0), green: UInt8(0), blue: UInt8(255))
        static let bottomRight = (red: UInt8(255), green: UInt8(0), blue: UInt8(255))

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
    }

    private static let diagnosticGlyphs: [Character: [Int]] = [
        "T": [31, 4, 4, 4, 4, 4, 4],
        "O": [14, 17, 17, 17, 17, 17, 14],
        "P": [30, 17, 17, 30, 16, 16, 16],
        "B": [30, 17, 17, 30, 17, 17, 30],
        "M": [17, 27, 21, 21, 17, 17, 17]
    ]
#endif

    private func drawPlayhead(step: Int, pulse: CGFloat, in context: CGContext) {
        let stepWidth = Layout.sequencerWidth / CGFloat(MusicSequence.steps)
        let x = Layout.sequencerX + CGFloat(step) * stepWidth
        let glowRect = CGRect(
            x: x + 4,
            y: Layout.sequencerY - 8,
            width: stepWidth - 8,
            height: Layout.sequencerHeight + 16
        )
        let lineRect = CGRect(
            x: x + stepWidth * 0.5 - 3,
            y: Layout.sequencerY - 14,
            width: 6,
            height: Layout.sequencerHeight + 28
        )

        context.setFillColor(CGColor(gray: 1, alpha: 0.10 + pulse * 0.10))
        context.fillRoundedRect(glowRect, radius: 12)
        context.setFillColor(CGColor(gray: 1, alpha: 0.58 + pulse * 0.26))
        context.fillRoundedRect(lineRect, radius: 3)
    }

    private func drawActiveRolePulses(
        step: Int,
        pulse: CGFloat,
        in context: CGContext
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
            let rect = Layout.photoRect(at: index, count: snapshot.photos.count)
                .insetBy(dx: -expansion, dy: -expansion)

            context.setStrokeColor(photo.accentColor.cgColor(alpha: 0.34 + pulse * 0.28))
            context.setLineWidth(3 + pulse * 2)
            context.strokeRoundedRect(rect, radius: 28 + expansion)
        }
    }
}

private enum Layout {
    static let photoWidth: CGFloat = 210
    static let photoHeight: CGFloat = 252
    static let photoSpacing: CGFloat = 18
    static let photoY: CGFloat = 1041
    static let sequencerX: CGFloat = 228
    static let sequencerY: CGFloat = 1453
    static let sequencerWidth: CGFloat = 744
    static let sequencerHeight: CGFloat = 96

    static func photoRect(at index: Int, count: Int) -> CGRect {
        let visibleCount = CGFloat(max(1, min(3, count)))
        let totalWidth = visibleCount * photoWidth + max(0, visibleCount - 1) * photoSpacing
        let startX = (JamStoryVideoRenderer.outputPixelSize.width - totalWidth) / 2
        return CGRect(
            x: startX + CGFloat(index) * (photoWidth + photoSpacing),
            y: photoY,
            width: photoWidth,
            height: photoHeight
        )
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
