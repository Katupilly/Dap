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

    static func pitchClass(forHueDegrees hue: Double) -> Int {
        let normalized = hue.truncatingRemainder(dividingBy: 360)
        let wrapped = normalized >= 0 ? normalized : normalized + 360
        return min(11, Int((wrapped / 30).rounded(.down)))
    }

    // MARK: Pitch → Palette (circle of fifths perceptual mapping)

    static func tonalPalette(for pitchClass: PitchClass) -> ColorPalette {
        let base = baseColor(for: pitchClass)
        return ColorPalette(
            shadow:    base.mixed(with: .black, ratio: 0.72),
            dark:      base.mixed(with: .black, ratio: 0.45),
            base:      base,
            highlight: base.mixed(with: .white, ratio: 0.38)
        )
    }

    private static func baseColor(for pitchClass: PitchClass) -> RGBColor {
        switch pitchClass {
        case .c:      RGBColor(red: 228, green: 87,  blue: 46)
        case .g:      RGBColor(red: 217, green: 142, blue: 4)
        case .d:      RGBColor(red: 181, green: 161, blue: 0)
        case .a:      RGBColor(red: 123, green: 174, blue: 0)
        case .e:      RGBColor(red: 45,  green: 173, blue: 85)
        case .b:      RGBColor(red: 0,   green: 169, blue: 154)
        case .fSharp: RGBColor(red: 0,   green: 143, blue: 207)
        case .cSharp: RGBColor(red: 45,  green: 108, blue: 223)
        case .gSharp: RGBColor(red: 91,  green: 86,  blue: 214)
        case .dSharp: RGBColor(red: 138, green: 79,  blue: 208)
        case .aSharp: RGBColor(red: 179, green: 74,  blue: 184)
        case .f:      RGBColor(red: 210, green: 74,  blue: 136)
        }
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
}
