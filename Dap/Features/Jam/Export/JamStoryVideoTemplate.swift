import CoreGraphics
import CoreVideo
import Foundation

struct JamStoryVideoTemplate: Sendable {
    let snapshot: JamStoryExportSnapshot
    let baseImage: CGImage

    func render(
        into pixelBuffer: CVPixelBuffer,
        time: Double,
        stepDuration: Double
    ) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let context = Self.makeContext(for: pixelBuffer) else {
            throw JamStoryVideoExportError.frameRenderingFailed
        }

        let size = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        context.interpolationQuality = .high
        context.draw(baseImage, in: CGRect(origin: .zero, size: size))

        let stepPosition = time / stepDuration
        let currentStep = Int(floor(stepPosition)) % MusicSequence.steps
        let stepProgress = stepPosition - floor(stepPosition)
        let pulse = CGFloat(1 - stepProgress)

        context.saveGState()
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        drawPlayhead(step: currentStep, pulse: pulse, in: context)
        drawActivePhotoPulses(step: currentStep, pulse: pulse, in: context)
        context.restoreGState()
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
    static func validatePixelBufferOrientation(_ pixelBuffer: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let context = makeContext(for: pixelBuffer) else {
            throw JamStoryVideoExportError.frameRenderingFailed
        }

        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        guard let diagnosticContext = CGContext(
            data: nil,
            width: Int(width),
            height: Int(height),
            bitsPerComponent: 8,
            bytesPerRow: Int(width) * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw JamStoryVideoExportError.frameRenderingFailed
        }

        diagnosticContext.translateBy(x: 0, y: height)
        diagnosticContext.scaleBy(x: 1, y: -1)
        diagnosticContext.setFillColor(CGColor(gray: 0.08, alpha: 1))
        diagnosticContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
        diagnosticContext.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        diagnosticContext.fill(CGRect(x: 0, y: 0, width: width, height: 180))
        diagnosticContext.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        diagnosticContext.fill(CGRect(x: 0, y: height - 180, width: width, height: 180))
        drawDiagnosticWord("TOP", x: 420, y: 48, in: diagnosticContext)
        drawDiagnosticWord("BOTTOM", x: 330, y: height - 132, in: diagnosticContext)

        guard let diagnosticImage = diagnosticContext.makeImage() else {
            throw JamStoryVideoExportError.frameRenderingFailed
        }
        context.draw(
            diagnosticImage,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )

        context.saveGState()
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 24, y: 24, width: 72, height: 72))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: width - 96, y: height - 96, width: 72, height: 72))
        context.restoreGState()
        context.flush()

        guard isRed(pixelColor(atX: 200, y: 60, in: pixelBuffer)),
              isBlue(pixelColor(atX: 200, y: Int(height) - 60, in: pixelBuffer)),
              isGreen(pixelColor(atX: 48, y: 48, in: pixelBuffer)),
              isMagenta(
            pixelColor(
                atX: Int(width) - 48,
                y: Int(height) - 48,
                in: pixelBuffer
            )
        ) else {
            throw JamStoryVideoExportError.frameRenderingFailed
        }
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

    private static func pixelColor(
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

    private static func isRed(
        _ color: (red: UInt8, green: UInt8, blue: UInt8)?
    ) -> Bool {
        guard let color else { return false }
        return color.red > 200 && color.green < 100 && color.blue < 100
    }

    private static func isBlue(
        _ color: (red: UInt8, green: UInt8, blue: UInt8)?
    ) -> Bool {
        guard let color else { return false }
        return color.blue > 200 && color.red < 100 && color.green < 100
    }

    private static func isGreen(
        _ color: (red: UInt8, green: UInt8, blue: UInt8)?
    ) -> Bool {
        guard let color else { return false }
        return color.green > 200 && color.red < 100 && color.blue < 100
    }

    private static func isMagenta(
        _ color: (red: UInt8, green: UInt8, blue: UInt8)?
    ) -> Bool {
        guard let color else { return false }
        return color.red > 200 && color.blue > 200 && color.green < 100
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
        let gridX: CGFloat = 228
        let gridWidth: CGFloat = 744
        let stepWidth = gridWidth / CGFloat(MusicSequence.steps)
        let rect = CGRect(
            x: gridX + CGFloat(step) * stepWidth + 2,
            y: 1453,
            width: stepWidth - 4,
            height: 96
        )

        context.setFillColor(CGColor(gray: 1, alpha: 0.16 + pulse * 0.22))
        context.fillEllipse(in: CGRect(
            x: rect.midX - 7,
            y: rect.minY - 22,
            width: 14,
            height: 14
        ))
        context.fill(rect)
    }

    private func drawActivePhotoPulses(
        step: Int,
        pulse: CGFloat,
        in context: CGContext
    ) {
        let photos = snapshot.photos
        guard !photos.isEmpty else { return }

        let tileWidth: CGFloat = 210
        let spacing: CGFloat = 18
        let totalWidth = CGFloat(photos.count) * tileWidth
            + CGFloat(max(photos.count - 1, 0)) * spacing
        let startX = (1080 - totalWidth) / 2

        for (index, photo) in photos.enumerated() {
            guard let role = photo.role,
                  snapshot.sequencerSnapshot.steps(for: role).contains(step) else {
                continue
            }

            let expansion = 5 + pulse * 9
            let rect = CGRect(
                x: startX + CGFloat(index) * (tileWidth + spacing) - expansion,
                y: 1041 - expansion,
                width: tileWidth + expansion * 2,
                height: 252 + expansion * 2
            )
            context.setStrokeColor(photo.accentColor.cgColor(alpha: 0.56 + pulse * 0.34))
            context.setLineWidth(5 + pulse * 3)
            context.stroke(rect.insetBy(dx: 2, dy: 2))
        }
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
