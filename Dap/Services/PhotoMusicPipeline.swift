import CoreGraphics
import UIKit

// MARK: - Pipeline errors

enum PhotoMusicPipelineError: Error, LocalizedError {
    case decodeFailed
    case renderFailed
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .decodeFailed: "Não foi possível decodificar a imagem."
        case .renderFailed: "Não foi possível gerar a capa."
        case .encodeFailed: "Não foi possível codificar a capa."
        }
    }
}

// MARK: - PhotoMusicPipeline

/// Deterministic photo → music pipeline.
/// Receives Data, executes all heavy work off-main in a single Task.detached,
/// returns only Sendable values.
enum PhotoMusicPipeline {

    // MARK: Constants (adapted from PedalHeuristics)

    private static let analysisSide              = 64
    private static let minimumSaturationForHue   = 0.10
    private static let lowHueVarianceDegrees     = 30.0
    private static let highHueVarianceDegrees    = 70.0
    private static let significantToneFraction   = 0.05
    private static let edgeGradientThreshold     = 0.18
    private static let lowEdgeDensity            = 0.03
    private static let highEdgeDensity           = 0.25
    private static let shortGate                 = 0.25
    private static let longGate                  = 0.98

    // MARK: Color analysis result (local, not persisted)

    private struct ColorProfile {
        let hue:                Double
        let saturation:         Double
        let luminance:          Double
        let hueVarianceDegrees: Double
        let edgeDensity:        Double
    }

    // MARK: Public entry point

    static func process(imageData: Data) async throws -> ProcessedPhotoSound {
        try await Task.detached(priority: .userInitiated) {
            // 1. Decode + normalize orientation via UIImage draw (thread-safe per UIKit docs).
            guard let uiImage = UIImage(data: imageData) else {
                throw PhotoMusicPipelineError.decodeFailed
            }
            let normalized = try normalizedCGImage(from: uiImage)

            // 2. Analyze color on a 64×64 scaled version of the shared CGImage.
            let colorProfile = try analyzeColor(cgImage: normalized)

            // 3. Floyd–Steinberg retro cover with default palette.
            let retroCG = try RetroCoverRenderer.floydSteinberg(cgImage: normalized)

            // 4. Tone analysis on the retro image (shared CGImage, no re-decode).
            let (gridLevels, significantToneCount) = try analyzeTones(cgImage: retroCG)

            // 5. Build musical sequence from color profile + tone grid.
            let sequence = buildSequence(
                colorProfile: colorProfile,
                gridLevels: gridLevels,
                significantToneCount: significantToneCount
            )

            // 6. Resolve dominant pitch class → tonal palette.
            let dominant = sequence.dominantPitchClass
            let palette  = RetroCoverRenderer.tonalPalette(for: dominant)

            // 7. Recolor the retro image with the tonal palette.
            let recoloredCG = try RetroCoverRenderer.recolor(cgImage: retroCG, palette: palette.all)
            guard let pngData = UIImage(cgImage: recoloredCG).pngData() else {
                throw PhotoMusicPipelineError.encodeFailed
            }

            // 8. Assemble result — only Sendable values cross out of this task.
            let id    = UUID()
            let sound = PhotoSound(
                id: id,
                name: nil,
                description: nil,
                createdAt: .now,
                coverFilename: "\(id.uuidString).png",
                sequence: sequence
            )
            return ProcessedPhotoSound(sound: sound, coverData: pngData)
        }.value
    }

    // MARK: - Image normalization

    /// Draws the UIImage into a fresh CGContext so EXIF orientation is applied.
    /// UIGraphicsPushContext and UIImage.draw are thread-safe per UIKit documentation.
    private static func normalizedCGImage(from image: UIImage) throws -> CGImage {
        let size   = image.size
        let scale  = image.scale
        let width  = max(1, Int(size.width  * scale))
        let height = max(1, Int(size.height * scale))

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw PhotoMusicPipelineError.decodeFailed }

        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)
        image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        UIGraphicsPopContext()

        guard let result = ctx.makeImage() else {
            throw PhotoMusicPipelineError.decodeFailed
        }
        return result
    }

    // MARK: - Color analysis (adapted from PhotoColorAnalyzer)

    private static func analyzeColor(cgImage source: CGImage) throws -> ColorProfile {
        let side = analysisSide
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(
            data: &pixels, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw PhotoMusicPipelineError.decodeFailed }
        ctx.interpolationQuality = .medium
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))

        var r = 0.0, g = 0.0, b = 0.0, weight = 0.0
        var hues: [Double] = []
        var gray = [Double](repeating: 0, count: side * side)

        for i in 0..<side * side {
            let p     = i * 4
            let alpha = Double(pixels[p + 3]) / 255
            guard alpha > 0 else { continue }
            let pr = Double(pixels[p])     / 255
            let pg = Double(pixels[p + 1]) / 255
            let pb = Double(pixels[p + 2]) / 255
            r += pr * alpha; g += pg * alpha; b += pb * alpha; weight += alpha
            gray[i] = 0.2126 * pr + 0.7152 * pg + 0.0722 * pb
            let (hue, sat) = hsb(r: pr, g: pg, b: pb)
            if sat >= minimumSaturationForHue { hues.append(hue) }
        }

        guard weight > 0 else {
            return ColorProfile(hue: 0, saturation: 0, luminance: 0,
                                hueVarianceDegrees: 0, edgeDensity: 0)
        }
        r /= weight; g /= weight; b /= weight
        let (meanHue, meanSat) = hsb(r: r, g: g, b: b)
        let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return ColorProfile(
            hue: meanHue, saturation: meanSat, luminance: lum,
            hueVarianceDegrees: circularVarianceDegrees(hues),
            edgeDensity: sobelEdgeDensity(gray, side: side)
        )
    }

    // MARK: - Tone analysis (adapted from ImageSequenceGenerator.analyzeTones)

    private static func analyzeTones(cgImage source: CGImage) throws -> ([Int], Int) {
        let fullLevels = try toneLevels(source, width: source.width, height: source.height)
        let total      = fullLevels.count
        let counts     = (0...3).map { lv in fullLevels.filter { $0 == lv }.count }
        let significant = counts.filter { Double($0) / Double(total) >= significantToneFraction }.count
        let gridLevels  = try toneLevels(source, width: MusicSequence.steps, height: MusicSequence.rows)
        return (gridLevels, significant)
    }

    private static func toneLevels(_ source: CGImage, width: Int, height: Int) throws -> [Int] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw PhotoMusicPipelineError.renderFailed }
        ctx.interpolationQuality = .none
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (0..<width * height).map { i in
            let p   = i * 4
            let lum = 0.2126 * Double(pixels[p]) + 0.7152 * Double(pixels[p+1]) + 0.0722 * Double(pixels[p+2])
            return min(3, max(0, Int((lum / 256 * 4).rounded(.down))))
        }
    }

    // MARK: - Sequence builder (adapted from ImageSequenceGenerator)

    private static func buildSequence(colorProfile p: ColorProfile,
                                      gridLevels: [Int],
                                      significantToneCount: Int) -> MusicSequence {
        let root     = min(11, max(0, Int((p.hue / 360 * 12).rounded(.down))))
        let scale    = musicScale(for: p)
        let bpm      = min(140, max(70, Int((70 + p.luminance * 70).rounded())))
        let harmony  = MusicHarmony(rootPitchClass: root, scale: scale, bpm: bpm)
        let octRange = octaveRange(for: significantToneCount)
        let gate     = computeGate(edgeDensity: p.edgeDensity)
        let waveform: MusicWaveform = (p.hue >= 90 && p.hue < 300) ? .square : .triangle
        let profile  = SoundProfile(gate: gate, octaveRange: octRange, waveform: waveform)

        var notes: [MusicNote] = []
        for row in 0..<MusicSequence.rows {
            for step in 0..<MusicSequence.steps {
                let level = gridLevels[row * MusicSequence.steps + step]
                guard level > 0 else { continue }
                let offset = pitchOffset(row: row, scale: scale, octaveRange: octRange)
                notes.append(MusicNote(
                    step: step, row: row,
                    midiNote: 60 + root + offset,
                    velocity: Float(level) / 3
                ))
            }
        }
        return MusicSequence(harmony: harmony, notes: notes, soundProfile: profile)
    }

    // MARK: - Musical heuristics

    private static func musicScale(for p: ColorProfile) -> MusicScale {
        if p.hueVarianceDegrees > highHueVarianceDegrees  { return .wholeTone }
        if p.hueVarianceDegrees >= lowHueVarianceDegrees  { return .dorian }
        return p.saturation >= 0.45 ? .majorPentatonic : .minorPentatonic
    }

    private static func octaveRange(for significantToneCount: Int) -> Double {
        switch significantToneCount { case 4...: 2; case 3: 1.5; default: 1 }
    }

    private static func computeGate(edgeDensity: Double) -> Double {
        let n = ((edgeDensity - lowEdgeDensity) / (highEdgeDensity - lowEdgeDensity)).clamped(to: 0...1)
        return longGate + (shortGate - longGate) * n
    }

    private static func pitchOffset(row: Int, scale: MusicScale, octaveRange: Double) -> Int {
        let reversed    = MusicSequence.rows - 1 - row
        let span        = Int((12 * octaveRange).rounded())
        let target      = Double(reversed) / Double(MusicSequence.rows - 1) * Double(span)
        let candidates  = (0...Int(ceil(octaveRange))).flatMap { oct in scale.degrees.map { $0 + oct * 12 } }
        return candidates.min { abs(Double($0) - target) < abs(Double($1) - target) } ?? 0
    }

    // MARK: - Color math

    private static func hsb(r: Double, g: Double, b: Double) -> (hue: Double, saturation: Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        let hue: Double
        if d == 0           { hue = 0 }
        else if mx == r     { hue = (60 * ((g - b) / d) + 360).truncatingRemainder(dividingBy: 360) }
        else if mx == g     { hue = 60 * ((b - r) / d + 2) }
        else                { hue = 60 * ((r - g) / d + 4) }
        return (hue, mx == 0 ? 0 : d / mx)
    }

    private static func circularVarianceDegrees(_ hues: [Double]) -> Double {
        guard !hues.isEmpty else { return 0 }
        let n  = Double(hues.count)
        let sn = hues.map { sin($0 * .pi / 180) }.reduce(0, +) / n
        let cs = hues.map { cos($0 * .pi / 180) }.reduce(0, +) / n
        let R  = min(1, sqrt(sn * sn + cs * cs))
        return sqrt(max(0, -2 * log(max(R, 1e-6)))) * 180 / .pi
    }

    private static func sobelEdgeDensity(_ gray: [Double], side: Int) -> Double {
        guard side >= 3, gray.count == side * side else { return 0 }
        var edges = 0, count = 0
        for y in 1..<side - 1 {
            for x in 1..<side - 1 {
                let i  = y * side + x
                let gx = -gray[i-side-1] + gray[i-side+1] - 2*gray[i-1] + 2*gray[i+1] - gray[i+side-1] + gray[i+side+1]
                let gy = -gray[i-side-1] - 2*gray[i-side] - gray[i-side+1] + gray[i+side-1] + 2*gray[i+side] + gray[i+side+1]
                if sqrt(gx*gx + gy*gy) >= edgeGradientThreshold { edges += 1 }
                count += 1
            }
        }
        return count == 0 ? 0 : Double(edges) / Double(count)
    }
}

// MARK: - Helpers

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
