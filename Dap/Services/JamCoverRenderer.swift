import CoreGraphics
import Foundation
@preconcurrency import UIKit

struct JamCoverDescriptor: Hashable, Sendable {
    static let currentRecipeVersion = 1

    let jamID: UUID
    let bassPhotoID: UUID?
    let harmonyPhotoID: UUID?
    let melodyPhotoID: UUID?
    let reservePhotoIDs: [UUID]
    let bassPitch: PitchClass?
    let harmonyPitch: PitchClass?
    let melodyPitch: PitchClass?
    let reservePitches: [PitchClass]
    let recipeVersion: Int

    init(
        jamID: UUID,
        bassPhotoID: UUID?,
        harmonyPhotoID: UUID?,
        melodyPhotoID: UUID?,
        reservePhotoIDs: [UUID],
        bassPitch: PitchClass?,
        harmonyPitch: PitchClass?,
        melodyPitch: PitchClass?,
        reservePitches: [PitchClass],
        recipeVersion: Int = JamCoverDescriptor.currentRecipeVersion
    ) {
        self.jamID = jamID
        self.bassPhotoID = bassPhotoID
        self.harmonyPhotoID = harmonyPhotoID
        self.melodyPhotoID = melodyPhotoID
        self.reservePhotoIDs = reservePhotoIDs
        self.bassPitch = bassPitch
        self.harmonyPitch = harmonyPitch
        self.melodyPitch = melodyPitch
        self.reservePitches = reservePitches
        self.recipeVersion = recipeVersion
    }

    static func empty(jamID: UUID) -> JamCoverDescriptor {
        JamCoverDescriptor(
            jamID: jamID,
            bassPhotoID: nil,
            harmonyPhotoID: nil,
            melodyPhotoID: nil,
            reservePhotoIDs: [],
            bassPitch: nil,
            harmonyPitch: nil,
            melodyPitch: nil,
            reservePitches: []
        )
    }

    init(jam: PersistedJam, sounds: [PhotoSound]) {
        self.init(
            jamID: jam.id,
            bassID: jam.slotAssignments.bass,
            harmonyID: jam.slotAssignments.harmony,
            melodyID: jam.slotAssignments.melody,
            reserveIDs: jam.slotAssignments.reserve,
            sounds: sounds
        )
    }

    init(jamID: UUID, slotAssignments: JamSlotAssignments, sounds: [PhotoSound]) {
        self.init(
            jamID: jamID,
            bassID: slotAssignments.bass,
            harmonyID: slotAssignments.harmony,
            melodyID: slotAssignments.melody,
            reserveIDs: slotAssignments.reserve,
            sounds: sounds
        )
    }

    private init(
        jamID: UUID,
        bassID: UUID?,
        harmonyID: UUID?,
        melodyID: UUID?,
        reserveIDs: [UUID],
        sounds: [PhotoSound]
    ) {
        let soundsByID = Dictionary(uniqueKeysWithValues: sounds.map { ($0.id, $0) })
        self.init(
            jamID: jamID,
            bassPhotoID: bassID,
            harmonyPhotoID: harmonyID,
            melodyPhotoID: melodyID,
            reservePhotoIDs: reserveIDs,
            bassPitch: bassID.flatMap { soundsByID[$0] }.flatMap(Self.pitchClass(for:)),
            harmonyPitch: harmonyID.flatMap { soundsByID[$0] }.flatMap(Self.pitchClass(for:)),
            melodyPitch: melodyID.flatMap { soundsByID[$0] }.flatMap(Self.pitchClass(for:)),
            reservePitches: reserveIDs.compactMap { id in
                soundsByID[id].flatMap(Self.pitchClass(for:))
            }
        )
    }

    private static func pitchClass(for sound: PhotoSound) -> PitchClass? {
        PitchClass(rawValue: sound.sequence.harmony.rootPitchClass) ?? sound.sequence.dominantPitchClass
    }
}

actor JamCoverRenderer {
    static let shared = JamCoverRenderer()

    private struct CacheKey: Hashable {
        let descriptor: JamCoverDescriptor
        let pixelWidth: Int
        let pixelHeight: Int
    }

    private struct RoleColors {
        let shadow: RGBColor
        let dark: RGBColor
        let base: RGBColor
        let highlight: RGBColor
    }

    private var cache: [CacheKey: Data] = [:]
    private var inFlight: [CacheKey: Task<Data, Never>] = [:]

    func data(
        for descriptor: JamCoverDescriptor,
        size: CGSize,
        scale: CGFloat
    ) async -> Data {
        let pixelWidth = max(1, Int((size.width * scale).rounded()))
        let pixelHeight = max(1, Int((size.height * scale).rounded()))
        let key = CacheKey(descriptor: descriptor, pixelWidth: pixelWidth, pixelHeight: pixelHeight)

        if let cached = cache[key] {
            return cached
        }

        if let task = inFlight[key] {
            return await task.value
        }

        let task = Task.detached(priority: .utility) {
            Self.renderCoverData(
                descriptor: descriptor,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            )
        }

        inFlight[key] = task
        let data = await task.value

        cache[key] = data
        inFlight[key] = nil
        return data
    }

    private static func renderCoverData(
        descriptor: JamCoverDescriptor,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> Data {
        let bytesPerRow = pixelWidth * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * pixelHeight)

        guard let context = CGContext(
            data: &pixels,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return Data()
        }

        context.interpolationQuality = .high

        let prioritizedRoles = prioritizedColors(for: descriptor)
        let background = coverBackground(from: prioritizedRoles)
        let paper = coverHighlight(from: prioritizedRoles, background: background)
        let accentDark = coverAccentDark(from: prioritizedRoles, background: background)

        let rect = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        context.setFillColor(background.cgColor)
        context.fill(rect)

        if let backgroundGradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                background.withBrightness(multiplier: 0.90).cgColor,
                accentDark.withBrightness(multiplier: 1.03).cgColor,
                paper.mixed(with: accentDark, ratio: 0.84).cgColor
            ] as CFArray,
            locations: [0, 0.58, 1]
        ) {
            context.drawLinearGradient(
                backgroundGradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: pixelWidth, y: pixelHeight),
                options: []
            )
        }

        var generator = SeededGenerator(seed: stableSeed(for: descriptor))
        let blobColors = blobFillColors(prioritizedRoles: prioritizedRoles, paper: paper)
        let baseCenters = [
            CGPoint(x: 0.66, y: 0.36),
            CGPoint(x: 0.28, y: 0.70),
            CGPoint(x: 0.82, y: 0.76),
        ]

        for (index, color) in blobColors.enumerated() {
            let center = jitteredCenter(baseCenters[index % baseCenters.count], generator: &generator)
            let radiusRange: ClosedRange<CGFloat>
            switch index {
            case 0: radiusRange = 0.58...0.74
            case 1: radiusRange = 0.42...0.56
            default: radiusRange = 0.28...0.38
            }
            let radius = generator.nextCGFloat(in: radiusRange) * CGFloat(min(pixelWidth, pixelHeight))
            drawBlob(
                color: color,
                center: CGPoint(
                    x: center.x * CGFloat(pixelWidth),
                    y: center.y * CGFloat(pixelHeight)
                ),
                radius: radius,
                in: context
            )
        }

        drawHighlightBloom(color: paper, seed: &generator, in: context, rect: rect)
        drawSoftWash(color: paper.mixed(with: background, ratio: 0.32), seed: &generator, in: context, rect: rect)
        applyTexture(to: &pixels, width: pixelWidth, height: pixelHeight, descriptor: descriptor)

        guard let image = context.makeImage(),
              let data = UIImage(cgImage: image).pngData() else {
            return Data()
        }
        return data
    }

    private static func prioritizedColors(for descriptor: JamCoverDescriptor) -> [RoleColors] {
        let prioritizedPitches = [descriptor.bassPitch, descriptor.harmonyPitch, descriptor.melodyPitch]
            + descriptor.reservePitches.map(Optional.some)

        let palettes = prioritizedPitches.compactMap { pitch -> RoleColors? in
            guard let pitch else { return nil }
            let palette = RetroCoverRenderer.tonalPalette(for: pitch)
            return RoleColors(
                shadow: palette.shadow,
                dark: palette.dark,
                base: palette.base,
                highlight: palette.highlight
            )
        }

        guard !palettes.isEmpty else {
            return [
                RoleColors(
                    shadow: RGBColor(red: 31, green: 37, blue: 48),
                    dark: RGBColor(red: 58, green: 72, blue: 98),
                    base: RGBColor(red: 84, green: 99, blue: 129),
                    highlight: RGBColor(red: 194, green: 201, blue: 216)
                ),
                RoleColors(
                    shadow: RGBColor(red: 39, green: 34, blue: 52),
                    dark: RGBColor(red: 72, green: 63, blue: 94),
                    base: RGBColor(red: 103, green: 93, blue: 132),
                    highlight: RGBColor(red: 200, green: 206, blue: 220)
                )
            ]
        }

        return palettes
    }

    private static func blobFillColors(prioritizedRoles: [RoleColors], paper: RGBColor) -> [RGBColor] {
        let background = coverBackground(from: prioritizedRoles)
        let softenedBaseColors = prioritizedRoles.map {
            softenedColor($0.base, background: background, paper: paper, saturationMix: 0.34, backgroundMix: 0.20)
        }
        let accent = blendedColor(softenedBaseColors, fallback: paper).mixed(with: paper, ratio: 0.26)

        var colors = Array(softenedBaseColors.prefix(3))
        while colors.count < 3 {
            colors.append(accent)
        }
        return colors
    }

    private static func drawBlob(
        color: RGBColor,
        center: CGPoint,
        radius: CGFloat,
        in context: CGContext
    ) {
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                color.withAlpha(0.62),
                color.withAlpha(0.26),
                color.withAlpha(0.0)
            ] as CFArray,
            locations: [0, 0.58, 1]
        ) else {
            return
        }

        context.saveGState()
        context.setBlendMode(.screen)
        context.drawRadialGradient(
            gradient,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: radius,
            options: [.drawsAfterEndLocation]
        )
        context.restoreGState()
    }

    private static func drawHighlightBloom(
        color: RGBColor,
        seed: inout SeededGenerator,
        in context: CGContext,
        rect: CGRect
    ) {
        let center = CGPoint(
            x: rect.minX + rect.width * seed.nextCGFloat(in: 0.44...0.62),
            y: rect.minY + rect.height * seed.nextCGFloat(in: 0.28...0.48)
        )
        let radius = min(rect.width, rect.height) * seed.nextCGFloat(in: 0.22...0.30)

        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                color.withAlpha(0.18),
                color.withAlpha(0.07),
                color.withAlpha(0.0)
            ] as CFArray,
            locations: [0, 0.42, 1]
        ) else {
            return
        }

        context.saveGState()
        context.setBlendMode(.screen)
        context.drawRadialGradient(
            gradient,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: radius,
            options: [.drawsAfterEndLocation]
        )
        context.restoreGState()
    }

    private static func drawSoftWash(
        color: RGBColor,
        seed: inout SeededGenerator,
        in context: CGContext,
        rect: CGRect
    ) {
        let inset = rect.width * 0.06
        let washRect = rect.insetBy(dx: inset, dy: inset)
        let start = CGPoint(
            x: washRect.minX + washRect.width * seed.nextCGFloat(in: 0.18...0.30),
            y: washRect.maxY
        )
        let end = CGPoint(
            x: washRect.maxX - washRect.width * seed.nextCGFloat(in: 0.18...0.30),
            y: washRect.minY
        )

        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                color.withAlpha(0.0),
                color.withAlpha(0.11),
                color.withAlpha(0.0)
            ] as CFArray,
            locations: [0, 0.5, 1]
        ) else {
            return
        }

        context.saveGState()
        context.setBlendMode(.screen)
        context.drawLinearGradient(gradient, start: start, end: end, options: [])
        context.restoreGState()
    }

    private static func jitteredCenter(
        _ base: CGPoint,
        generator: inout SeededGenerator
    ) -> CGPoint {
        CGPoint(
            x: min(max(base.x + generator.nextCGFloat(in: -0.05...0.05), 0.12), 0.88),
            y: min(max(base.y + generator.nextCGFloat(in: -0.05...0.05), 0.12), 0.88)
        )
    }

    private static func applyTexture(
        to pixels: inout [UInt8],
        width: Int,
        height: Int,
        descriptor: JamCoverDescriptor
    ) {
        let halftoneMatrix: [Double] = [
            0.05, 0.55, 0.15, 0.65,
            0.75, 0.25, 0.85, 0.35,
            0.20, 0.70, 0.10, 0.60,
            0.90, 0.40, 0.80, 0.30,
        ]
        let seed = stableSeed(for: descriptor)

        for y in 0..<height {
            for x in 0..<width {
                let pixelIndex = (y * width + x) * 4
                let alpha = Double(pixels[pixelIndex + 3]) / 255
                guard alpha > 0 else { continue }

                let red = Double(pixels[pixelIndex]) / 255
                let green = Double(pixels[pixelIndex + 1]) / 255
                let blue = Double(pixels[pixelIndex + 2]) / 255
                let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue

                let halftoneWeight = max(0, min(1, (0.72 - luminance) / 0.42)) * 0.030
                let matrixIndex = ((y / 2) % 4) * 4 + ((x / 2) % 4)
                let threshold = halftoneMatrix[matrixIndex]
                let halftoneDelta = (threshold < luminance ? -1 : 1) * halftoneWeight
                let grain = hashedUnit(seed: seed, x: x, y: y, salt: 0x9E37) * 0.007
                let adjustment = halftoneDelta + grain

                pixels[pixelIndex] = adjustedByte(pixels[pixelIndex], by: adjustment, alpha: alpha)
                pixels[pixelIndex + 1] = adjustedByte(pixels[pixelIndex + 1], by: adjustment, alpha: alpha)
                pixels[pixelIndex + 2] = adjustedByte(pixels[pixelIndex + 2], by: adjustment, alpha: alpha)
            }
        }
    }

    private static func adjustedByte(_ value: UInt8, by delta: Double, alpha: Double) -> UInt8 {
        let unpremultiplied = Double(value) / max(alpha, 0.001)
        let adjusted = min(255, max(0, (unpremultiplied * (1 + delta)).rounded()))
        return UInt8(min(255, max(0, (adjusted * alpha).rounded())))
    }

    private static func blendedColor(_ colors: [RGBColor], fallback: RGBColor) -> RGBColor {
        guard !colors.isEmpty else { return fallback }
        let red = colors.reduce(0) { $0 + Int($1.red) } / colors.count
        let green = colors.reduce(0) { $0 + Int($1.green) } / colors.count
        let blue = colors.reduce(0) { $0 + Int($1.blue) } / colors.count
        return RGBColor(red: UInt8(red), green: UInt8(green), blue: UInt8(blue))
    }

    private static func coverBackground(from roles: [RoleColors]) -> RGBColor {
        let fallback = RGBColor(red: 34, green: 38, blue: 49)
        let shadowBlend = blendedColor(roles.map(\.shadow), fallback: fallback)
        let darkBlend = blendedColor(roles.map(\.dark), fallback: fallback)
        let mixed = shadowBlend.mixed(with: darkBlend, ratio: 0.34)
        return softenedColor(
            mixed,
            background: fallback,
            paper: RGBColor(red: 196, green: 203, blue: 218),
            saturationMix: 0.48,
            backgroundMix: 0.24
        ).withBrightness(multiplier: 0.76)
    }

    private static func coverAccentDark(from roles: [RoleColors], background: RGBColor) -> RGBColor {
        let darkBlend = blendedColor(roles.map(\.dark), fallback: background.withBrightness(multiplier: 1.14))
        return softenedColor(
            darkBlend,
            background: background,
            paper: RGBColor(red: 198, green: 204, blue: 220),
            saturationMix: 0.38,
            backgroundMix: 0.18
        ).withBrightness(multiplier: 0.94)
    }

    private static func coverHighlight(from roles: [RoleColors], background: RGBColor) -> RGBColor {
        let coolPaper = RGBColor(red: 204, green: 210, blue: 224)
        let highlightBlend = blendedColor(roles.map(\.highlight), fallback: coolPaper)
        return softenedColor(
            highlightBlend.mixed(with: coolPaper, ratio: 0.42),
            background: background,
            paper: coolPaper,
            saturationMix: 0.52,
            backgroundMix: 0.10
        )
    }

    private static func softenedColor(
        _ color: RGBColor,
        background: RGBColor,
        paper: RGBColor,
        saturationMix: Double,
        backgroundMix: Double
    ) -> RGBColor {
        let neutral = grayscale(color)
        let desaturated = color.mixed(with: neutral, ratio: saturationMix)
        let balanced = desaturated.mixed(with: background, ratio: backgroundMix)
        return balanced.mixed(with: paper, ratio: 0.08)
    }

    private static func grayscale(_ color: RGBColor) -> RGBColor {
        let value = UInt8(min(255, max(0, Int(color.luminance.rounded()))))
        return RGBColor(red: value, green: value, blue: value)
    }

    private static func stableSeed(for descriptor: JamCoverDescriptor) -> UInt64 {
        let reservePhotoIDs = descriptor.reservePhotoIDs.map(\.uuidString).joined(separator: ",")
        let reservePitches = descriptor.reservePitches.map { String($0.rawValue) }.joined(separator: ",")
        let bassPitch = descriptor.bassPitch.map { String($0.rawValue) } ?? "-"
        let harmonyPitch = descriptor.harmonyPitch.map { String($0.rawValue) } ?? "-"
        let melodyPitch = descriptor.melodyPitch.map { String($0.rawValue) } ?? "-"
        let components = [
            descriptor.jamID.uuidString,
            descriptor.bassPhotoID?.uuidString ?? "-",
            bassPitch,
            descriptor.harmonyPhotoID?.uuidString ?? "-",
            harmonyPitch,
            descriptor.melodyPhotoID?.uuidString ?? "-",
            melodyPitch,
            reservePhotoIDs,
            reservePitches,
            String(descriptor.recipeVersion)
        ]

        var hash: UInt64 = 1469598103934665603
        for byte in components.joined(separator: "|").utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return hash
    }

    private static func hashedUnit(seed: UInt64, x: Int, y: Int, salt: UInt64) -> Double {
        var value = seed
        value ^= UInt64(bitPattern: Int64(x &* 73856093))
        value ^= UInt64(bitPattern: Int64(y &* 19349663))
        value ^= salt
        value = jamCoverMix64(value)
        let normalized = Double(value & 0xFFFF) / Double(0xFFFF)
        return normalized * 2 - 1
    }
}

private struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0xA0761D6478BD642F : seed
    }

    mutating func nextCGFloat(in range: ClosedRange<CGFloat>) -> CGFloat {
        let unit = CGFloat(nextUnit())
        return range.lowerBound + (range.upperBound - range.lowerBound) * unit
    }

    private mutating func nextUnit() -> Double {
        state = jamCoverMix64(state)
        return Double(state & 0xFFFF_FFFF) / Double(UInt32.max)
    }
}

private func jamCoverMix64(_ value: UInt64) -> UInt64 {
    var z = value &+ 0x9E3779B97F4A7C15
    z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
    z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
    return z ^ (z >> 31)
}

private extension RGBColor {
    var cgColor: CGColor {
        UIColor(
            red: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: 1
        ).cgColor
    }

    func withAlpha(_ alpha: CGFloat) -> CGColor {
        UIColor(
            red: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: alpha
        ).cgColor
    }

    func withBrightness(multiplier: Double) -> RGBColor {
        RGBColor(
            red: adjustedChannel(red, multiplier: multiplier),
            green: adjustedChannel(green, multiplier: multiplier),
            blue: adjustedChannel(blue, multiplier: multiplier)
        )
    }

    private func adjustedChannel(_ value: UInt8, multiplier: Double) -> UInt8 {
        UInt8(min(255, max(0, Int((Double(value) * multiplier).rounded()))))
    }
}
