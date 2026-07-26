import CoreGraphics
import UIKit

// MARK: - Color primitives (no SwiftUI/UIKit dependency in the types themselves)

struct RGBColor: Sendable, Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    var luminance: Double {
        0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)
    }

    func mixed(with other: RGBColor, ratio: Double) -> RGBColor {
        let r = min(max(ratio, 0), 1)
        return RGBColor(
            red:   mixByte(red,   other.red,   ratio: r),
            green: mixByte(green, other.green, ratio: r),
            blue:  mixByte(blue,  other.blue,  ratio: r)
        )
    }

    private func mixByte(_ a: UInt8, _ b: UInt8, ratio: Double) -> UInt8 {
        UInt8(min(255, max(0, Int((Double(a) + (Double(b) - Double(a)) * ratio).rounded()))))
    }

    static let black = RGBColor(red: 0,   green: 0,   blue: 0)
    static let white = RGBColor(red: 255, green: 255, blue: 255)
}

struct ColorPalette: Sendable, Equatable {
    let shadow:    RGBColor
    let dark:      RGBColor
    let base:      RGBColor
    let highlight: RGBColor

    var all: [RGBColor] { [shadow, dark, base, highlight] }
}

// MARK: - Renderer errors

enum RetroCoverRendererError: Error {
    case invalidImage, contextFailed, pngEncodeFailed
}

// MARK: - RetroCoverRenderer

enum RetroCoverRenderer {

    /// Four-tone green-gray palette used before note-based recoloring.
    static let defaultPalette: [RGBColor] = [
        RGBColor(red: 20,  green: 24,  blue: 20),
        RGBColor(red: 74,  green: 82,  blue: 66),
        RGBColor(red: 154, green: 166, blue: 126),
        RGBColor(red: 226, green: 234, blue: 194),
    ]

    static let targetWidth = 160
    private static let coverMaximumDimension = 1024
    private static let clusteredDotThresholds: [UInt8] = [
        12, 5, 6, 13,
        4, 0, 1, 7,
        11, 3, 2, 8,
        15, 10, 9, 14,
    ]
    private static let clusteredDotMatrixSize = 4
    private static let clusteredDotPixelScale = 2

    static func pitchClass(forHueDegrees hue: Double) -> Int {
        let normalized = hue.truncatingRemainder(dividingBy: 360)
        let wrapped = normalized >= 0 ? normalized : normalized + 360
        return min(11, Int((wrapped / 30).rounded(.down)))
    }

    // MARK: Pitch → Palette (circle of fifths perceptual mapping)

    static func tonalPalette(for pitchClass: PitchClass) -> ColorPalette {
        let note = pitchClass.canonicalColor
        let ink = RGBColor(red: 18, green: 20, blue: 24).mixed(with: note, ratio: 0.24)
        let shadow = note.mixed(with: ink, ratio: 0.40)
        let paper = RGBColor(red: 245, green: 241, blue: 236).mixed(with: note, ratio: 0.22)
        return ColorPalette(
            shadow:    ink,
            dark:      shadow,
            base:      note,
            highlight: paper
        )
    }

    // MARK: Pattern halftone cover → CGImage

    static func patternHalftone(cgImage source: CGImage,
                                palette: ColorPalette) throws -> CGImage {
        let outputSize = targetCoverSize(for: source)
        let width = outputSize.width
        let height = outputSize.height
        let bytesPerRow = width * 4
        let bytes = bytesPerRow * height

        var src = [UInt8](repeating: 0, count: bytes)
        guard let srcCtx = CGContext(
            data: &src, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw RetroCoverRendererError.contextFailed }
        srcCtx.interpolationQuality = .medium
        srcCtx.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

        var out = [UInt8](repeating: 0, count: bytes)
        let colors = [palette.shadow, palette.dark, palette.base, palette.highlight]

        for y in 0..<height {
            for x in 0..<width {
                let pixelIndex = (y * width + x) * 4
                let alpha = src[pixelIndex + 3]
                guard alpha > 0 else { continue }

                let red = Double(src[pixelIndex]) / 255
                let green = Double(src[pixelIndex + 1]) / 255
                let blue = Double(src[pixelIndex + 2]) / 255
                let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
                let adjustedLuminance = min(max((luminance - 0.5) * 1.12 + 0.5, 0), 1)
                let scaledTone = adjustedLuminance * 3.0
                let lowerIndex = min(2, max(0, Int(floor(scaledTone))))
                let fraction = scaledTone - Double(lowerIndex)

                let matrixX = (x / clusteredDotPixelScale) % clusteredDotMatrixSize
                let matrixY = (y / clusteredDotPixelScale) % clusteredDotMatrixSize
                let matrixIndex = matrixY * clusteredDotMatrixSize + matrixX
                let threshold = (Double(clusteredDotThresholds[matrixIndex]) + 0.5) / 16.0
                let color = fraction > threshold ? colors[lowerIndex + 1] : colors[lowerIndex]

                let opacity = Double(alpha) / 255
                out[pixelIndex] = UInt8((Double(color.red) * opacity).rounded())
                out[pixelIndex + 1] = UInt8((Double(color.green) * opacity).rounded())
                out[pixelIndex + 2] = UInt8((Double(color.blue) * opacity).rounded())
                out[pixelIndex + 3] = alpha
            }
        }

        guard let outCtx = CGContext(
            data: &out, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let result = outCtx.makeImage() else {
            throw RetroCoverRendererError.contextFailed
        }
        return result
    }

    // MARK: Floyd–Steinberg dithering → CGImage

    /// Renders a four-tone dithered image using Floyd–Steinberg.
    /// Called from Task.detached — no actor boundary crossing.
    static func floydSteinberg(cgImage source: CGImage,
                               palette: [RGBColor] = RetroCoverRenderer.defaultPalette) throws -> CGImage {
        guard palette.count == 4 else { throw RetroCoverRendererError.invalidImage }

        let aspect = CGFloat(source.height) / CGFloat(source.width)
        let width  = targetWidth
        let height = max(1, Int((CGFloat(width) * aspect).rounded()))
        let bpr    = width * 4
        let bytes  = bpr * height

        var src = [UInt8](repeating: 0, count: bytes)
        guard let srcCtx = CGContext(
            data: &src, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bpr,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw RetroCoverRendererError.contextFailed }
        srcCtx.interpolationQuality = .none
        srcCtx.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

        var lum   = [Double](repeating: 0, count: width * height)
        var alpha = [UInt8](repeating: 0, count: width * height)
        for i in lum.indices {
            let p = i * 4
            let a = src[p + 3]
            alpha[i] = a
            guard a > 0 else { continue }
            let op = Double(a) / 255
            lum[i] = (0.2126 * Double(src[p]) + 0.7152 * Double(src[p + 1]) + 0.0722 * Double(src[p + 2])) / op
        }

        var out = [UInt8](repeating: 0, count: bytes)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                guard alpha[i] > 0 else { continue }
                let old   = lum[i]
                let color = palette.min { abs($0.luminance - old) < abs($1.luminance - old) }!
                let p     = i * 4
                let op    = Double(alpha[i]) / 255
                out[p]     = UInt8((Double(color.red)   * op).rounded())
                out[p + 1] = UInt8((Double(color.green) * op).rounded())
                out[p + 2] = UInt8((Double(color.blue)  * op).rounded())
                out[p + 3] = alpha[i]
                let err = old - color.luminance
                distribute(err, x: x+1, y: y,   w: 7/16, width: width, height: height, alpha: alpha, lum: &lum)
                distribute(err, x: x-1, y: y+1, w: 3/16, width: width, height: height, alpha: alpha, lum: &lum)
                distribute(err, x: x,   y: y+1, w: 5/16, width: width, height: height, alpha: alpha, lum: &lum)
                distribute(err, x: x+1, y: y+1, w: 1/16, width: width, height: height, alpha: alpha, lum: &lum)
            }
        }

        guard let outCtx = CGContext(
            data: &out, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bpr,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let result = outCtx.makeImage() else {
            throw RetroCoverRendererError.contextFailed
        }
        return result
    }

    // MARK: Recolor by luminance match

    /// Replaces each pixel with the closest palette color by luminance.
    /// Input is the dithered CGImage; output is the note-colored CGImage.
    static func recolor(cgImage source: CGImage, palette: [RGBColor]) throws -> CGImage {
        guard palette.count == 4 else { throw RetroCoverRendererError.invalidImage }

        let width  = source.width
        let height = source.height
        let bpr    = width * 4
        let bytes  = bpr * height

        var src = [UInt8](repeating: 0, count: bytes)
        guard let srcCtx = CGContext(
            data: &src, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bpr,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw RetroCoverRendererError.contextFailed }
        srcCtx.interpolationQuality = .none
        srcCtx.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

        var out = [UInt8](repeating: 0, count: bytes)
        for i in 0..<width * height {
            let p = i * 4
            let a = src[p + 3]
            guard a > 0 else { continue }
            let op  = Double(a) / 255
            let lum = (0.2126 * Double(src[p]) + 0.7152 * Double(src[p+1]) + 0.0722 * Double(src[p+2])) / op
            let c   = palette.min { abs($0.luminance - lum) < abs($1.luminance - lum) }!
            out[p]     = UInt8((Double(c.red)   * op).rounded())
            out[p + 1] = UInt8((Double(c.green) * op).rounded())
            out[p + 2] = UInt8((Double(c.blue)  * op).rounded())
            out[p + 3] = a
        }

        guard let outCtx = CGContext(
            data: &out, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bpr,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let result = outCtx.makeImage() else {
            throw RetroCoverRendererError.contextFailed
        }
        return result
    }

    // MARK: Private helpers

    private static func distribute(_ error: Double,
                                   x: Int, y: Int, w: Double,
                                   width: Int, height: Int,
                                   alpha: [UInt8], lum: inout [Double]) {
        guard x >= 0, x < width, y >= 0, y < height else { return }
        let i = y * width + x
        guard alpha[i] > 0 else { return }
        lum[i] += error * w
    }

    private static func targetCoverSize(for source: CGImage) -> (width: Int, height: Int) {
        let width = source.width
        let height = source.height
        let maximum = max(width, height)
        guard maximum > coverMaximumDimension else {
            return (width, height)
        }

        let scale = Double(coverMaximumDimension) / Double(maximum)
        return (
            max(1, Int((Double(width) * scale).rounded())),
            max(1, Int((Double(height) * scale).rounded()))
        )
    }
}

private extension PitchClass {
    var canonicalColor: RGBColor {
        switch self {
        case .c:      RGBColor(red: 224, green: 86,  blue: 72)
        case .cSharp: RGBColor(red: 195, green: 98,  blue: 222)
        case .d:      RGBColor(red: 230, green: 123, blue: 53)
        case .dSharp: RGBColor(red: 162, green: 86,  blue: 214)
        case .e:      RGBColor(red: 81,  green: 176, blue: 86)
        case .f:      RGBColor(red: 209, green: 75,  blue: 138)
        case .fSharp: RGBColor(red: 0,   green: 140, blue: 196)
        case .g:      RGBColor(red: 210, green: 158, blue: 42)
        case .gSharp: RGBColor(red: 86,  green: 93,  blue: 212)
        case .a:      RGBColor(red: 136, green: 170, blue: 42)
        case .aSharp: RGBColor(red: 182, green: 73,  blue: 183)
        case .b:      RGBColor(red: 0,   green: 164, blue: 148)
        }
    }
}
