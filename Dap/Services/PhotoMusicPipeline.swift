import CoreGraphics
import OSLog
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

struct PhotoMusicColorProfile: Sendable {
    let hue: Double
    let saturation: Double
    let luminance: Double
    let hueVarianceDegrees: Double
    let edgeDensity: Double
    let rootPitchClass: PitchClass
    let selectorSeed: UInt64?
    let hasReliableRoot: Bool
}

struct PreparedPhotoInput: Sendable {
    let originalImageData: Data
    let analysisInputData: Data
    let processedPreviewData: Data
    let colorProfile: PhotoMusicColorProfile
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
    private static let colorPipelineAlgorithmVersion = 2
    private static let weightedHueFallbackRatio      = 0.003
    private static let weightedHueSofteningExponent  = 0.85
    private static let toneAnalysisMaximumDimension  = 256

    #if DEBUG
    private static let performanceLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Dap",
        category: "PhotoPipeline"
    )

    private static func logFallback(
        _ mode: SequenceFallback,
        rootSource: String,
        root: Int,
        scale: MusicScale,
        variation: Int,
        sequence: MusicSequence
    ) {
        performanceLogger.debug(
            "sequence fallback: stage=\(mode.rawValue, privacy: .public), preserved=color-profile,bpm,seed, rootSource=\(rootSource, privacy: .public), root=\(root, privacy: .public), scale=\(scale.rawValue, privacy: .public), variation=\(variation, privacy: .public), bpm=\(sequence.harmony.bpm, privacy: .public), steps=\(MusicSequence.steps, privacy: .public), duration=\(sequence.nominalDuration, privacy: .public)"
        )
    }

    private static func logDuration(
        _ label: String,
        startedAt: ContinuousClock.Instant,
        clock: ContinuousClock
    ) {
        performanceLogger.debug(
            "\(label, privacy: .public): \(String(describing: startedAt.duration(to: clock.now)), privacy: .public)"
        )
    }
    #endif

    private enum SequenceFallback: String {
        case none
        case emptyToneGrid
        case toneAnalysisFailed
        case invalidProfile
    }

    private static let fallbackSteps = [0, 3, 6, 10, 14]
    private static let fallbackMotifs = [
        [0, 1, 2, 1, 0],
        [0, 1, 3, 2, 0],
        [0, 2, 1, 2, 0]
    ]

    // MARK: Public entry point

    static func process(imageData: Data) async throws -> ProcessedPhotoSound {
        let prepared = try await prepare(imageData: imageData)
        return try await process(prepared: prepared)
    }

    static func prepare(imageData: Data) async throws -> PreparedPhotoInput {
        let worker = Task.detached(priority: .userInitiated) {
            let clock = ContinuousClock()
            let totalStart = clock.now
            let normalizationStart = clock.now

            // Decode + normalize orientation via UIImage draw (thread-safe per UIKit docs).
            guard let uiImage = UIImage(data: imageData) else {
                throw PhotoMusicPipelineError.decodeFailed
            }
            let normalized = try normalizedCGImage(
                from: uiImage,
                maximumDimension: RetroCoverRenderer.coverMaximumDimension
            )
            guard let analysisInputData = UIImage(cgImage: normalized).pngData() else {
                throw PhotoMusicPipelineError.encodeFailed
            }
            try Task.checkCancellation()
            #if DEBUG
            logDuration("normalization + analysis input", startedAt: normalizationStart, clock: clock)
            #endif

            // The root pitch is needed to select the canonical Cover palette.
            let colorAnalysisStart = clock.now
            let colorProfile = try analyzeColor(cgImage: normalized)
            try Task.checkCancellation()
            #if DEBUG
            logDuration("downsample + color analysis", startedAt: colorAnalysisStart, clock: clock)
            #endif

            let visualStart = clock.now
            let palette = RetroCoverRenderer.tonalPalette(for: colorProfile.rootPitchClass)
            let coverCG = try RetroCoverRenderer.patternHalftone(cgImage: normalized, palette: palette)
            guard let pngData = UIImage(cgImage: coverCG).pngData() else {
                throw PhotoMusicPipelineError.encodeFailed
            }
            try Task.checkCancellation()
            #if DEBUG
            logDuration("Dap visual preview", startedAt: visualStart, clock: clock)
            logDuration("visual preparation total", startedAt: totalStart, clock: clock)
            #endif

            return PreparedPhotoInput(
                originalImageData: imageData,
                analysisInputData: analysisInputData,
                processedPreviewData: pngData,
                colorProfile: colorProfile
            )
        }
        return try await withTaskCancellationHandler(operation: {
            try await worker.value
        }, onCancel: {
            worker.cancel()
        })
    }

    static func process(prepared: PreparedPhotoInput) async throws -> ProcessedPhotoSound {
        let worker = Task.detached(priority: .userInitiated) {
            let clock = ContinuousClock()
            let musicalStart = clock.now

            try Task.checkCancellation()

            let normalized = UIImage(data: prepared.analysisInputData)?.cgImage
            let gridLevels: [Int]
            let significantToneCount: Int
            let fallback: SequenceFallback

            if let normalized {
                // Tone analysis stays on direct source luminance so Cover tuning does not change music.
                let toneAnalysisStart = clock.now
                do {
                    let analyzed = try analyzeTones(cgImage: normalized)
                    gridLevels = analyzed.0
                    significantToneCount = analyzed.1
                    fallback = gridLevels.contains(where: { $0 > 0 }) ? .none : .emptyToneGrid
                    #if DEBUG
                    logDuration("musical downsample + tone analysis", startedAt: toneAnalysisStart, clock: clock)
                    #endif
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    gridLevels = []
                    significantToneCount = 0
                    fallback = .toneAnalysisFailed
                    #if DEBUG
                    performanceLogger.debug(
                        "sequence fallback: stage=tone-analysis-error, error=\(String(describing: error), privacy: .public)"
                    )
                    #endif
                }
            } else {
                gridLevels = []
                significantToneCount = 0
                fallback = .toneAnalysisFailed
                #if DEBUG
                performanceLogger.debug(
                    "sequence fallback: stage=analysis-input-decode, preserved=color-profile, privacy=public"
                )
                #endif
            }

            let sequenceStart = clock.now
            let sequence = buildSequence(
                colorProfile: prepared.colorProfile,
                gridLevels: gridLevels,
                significantToneCount: significantToneCount,
                fallback: fallback
            )
            try Task.checkCancellation()
            #if DEBUG
            logDuration("sequence", startedAt: sequenceStart, clock: clock)
            logDuration("musical analysis total", startedAt: musicalStart, clock: clock)
            #endif

            let id    = UUID()
            let sound = PhotoSound(
                id: id,
                name: nil,
                nameSource: nil,
                description: nil,
                createdAt: .now,
                coverFilename: "\(id.uuidString).png",
                sequence: sequence
            )
            return ProcessedPhotoSound(sound: sound, coverData: prepared.processedPreviewData)
        }
        return try await withTaskCancellationHandler(operation: {
            try await worker.value
        }, onCancel: {
            worker.cancel()
        })
    }

    // MARK: - Image normalization

    /// Draws the UIImage into a fresh CGContext so EXIF orientation is applied.
    /// UIGraphicsPushContext and UIImage.draw are thread-safe per UIKit documentation.
    private static func normalizedCGImage(
        from image: UIImage,
        maximumDimension: Int
    ) throws -> CGImage {
        let size   = image.size
        let scale  = image.scale
        let sourceWidth = max(1, Int(size.width * scale))
        let sourceHeight = max(1, Int(size.height * scale))
        let sourceMaximum = max(sourceWidth, sourceHeight)
        let dimensionScale = sourceMaximum > maximumDimension
            ? Double(maximumDimension) / Double(sourceMaximum)
            : 1
        let width = max(1, Int((Double(sourceWidth) * dimensionScale).rounded()))
        let height = max(1, Int((Double(sourceHeight) * dimensionScale).rounded()))

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

    private static func analyzeColor(cgImage source: CGImage) throws -> PhotoMusicColorProfile {
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
        var hueBins = [Double](repeating: 0, count: 12)
        var totalChromaticWeight = 0.0
        let selectorSeed = stableSelectorSeed(bytes: pixels)

        for i in 0..<side * side {
            let p     = i * 4
            let alpha = Double(pixels[p + 3]) / 255
            guard alpha > 0 else { continue }
            let pr = Double(pixels[p])     / 255
            let pg = Double(pixels[p + 1]) / 255
            let pb = Double(pixels[p + 2]) / 255
            r += pr * alpha; g += pg * alpha; b += pb * alpha; weight += alpha
            let luminance = 0.2126 * pr + 0.7152 * pg + 0.0722 * pb
            gray[i] = luminance
            let (hue, sat) = hsb(r: pr, g: pg, b: pb)
            if sat >= minimumSaturationForHue { hues.append(hue) }

            let saturationWeight = pow(max(0, (sat - 0.08) / 0.92), 2.0)
            let luminanceConfidence = 0.25 + 0.75 * max(0, 1 - abs(luminance - 0.5) / 0.5)
            let hueWeight = alpha * saturationWeight * luminanceConfidence
            if hueWeight > 0 {
                let bin = min(11, max(0, Int((hue / 30).rounded(.down))))
                hueBins[bin] += hueWeight
                totalChromaticWeight += hueWeight
            }
        }

        guard weight > 0 else {
            return PhotoMusicColorProfile(hue: 0, saturation: 0, luminance: 0,
                                          hueVarianceDegrees: 0, edgeDensity: 0,
                                          rootPitchClass: .c,
                                          selectorSeed: selectorSeed,
                                          hasReliableRoot: false)
        }
        r /= weight; g /= weight; b /= weight
        let (meanHue, meanSat) = hsb(r: r, g: g, b: b)
        let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return PhotoMusicColorProfile(
            hue: meanHue, saturation: meanSat, luminance: lum,
            hueVarianceDegrees: circularVarianceDegrees(hues),
            edgeDensity: sobelEdgeDensity(gray, side: side),
            rootPitchClass: selectRootPitchClass(hueBins: hueBins,
                                                 totalChromaticWeight: totalChromaticWeight,
                                                 seed: selectorSeed),
            selectorSeed: selectorSeed,
            hasReliableRoot: totalChromaticWeight > 0.0001
        )
    }

    // MARK: - Tone analysis (adapted from ImageSequenceGenerator.analyzeTones)

    private static func analyzeTones(cgImage source: CGImage) throws -> ([Int], Int) {
        let significantSize = toneAnalysisSize(for: source)
        let fullLevels = try toneLevels(source, width: significantSize.width, height: significantSize.height)
        let total = max(1, fullLevels.count)
        var counts = [Int](repeating: 0, count: 4)
        for level in fullLevels {
            counts[level] += 1
        }
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
        ctx.interpolationQuality = .medium
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (0..<width * height).map { i in
            let p   = i * 4
            let alpha = Double(pixels[p + 3]) / 255
            guard alpha > 0 else { return 0 }
            let red = min(max(Double(pixels[p]) / 255 / alpha, 0), 1)
            let green = min(max(Double(pixels[p + 1]) / 255 / alpha, 0), 1)
            let blue = min(max(Double(pixels[p + 2]) / 255 / alpha, 0), 1)
            let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            let normalized = normalizedToneAnalysisLuminance(luminance)
            return min(3, max(0, Int((normalized * 4).rounded(.down))))
        }
    }

    private static func toneAnalysisSize(for source: CGImage) -> (width: Int, height: Int) {
        let width = source.width
        let height = source.height
        let maximum = max(width, height)
        guard maximum > toneAnalysisMaximumDimension else {
            return (max(1, width), max(1, height))
        }

        let scale = Double(toneAnalysisMaximumDimension) / Double(maximum)
        return (
            width: max(1, Int((Double(width) * scale).rounded())),
            height: max(1, Int((Double(height) * scale).rounded()))
        )
    }

    private static func normalizedToneAnalysisLuminance(_ luminance: Double) -> Double {
        let contrast = ((luminance - 0.5) * 1.12 + 0.5).clamped(to: 0...1)
        let shadowBias = contrast + max(0, 0.24 - contrast) * 0.10
        return (shadowBias - max(0, shadowBias - 0.82) * 0.08).clamped(to: 0...1)
    }

    // MARK: - Sequence builder (adapted from ImageSequenceGenerator)

    private static func buildSequence(colorProfile p: PhotoMusicColorProfile,
                                      gridLevels: [Int],
                                      significantToneCount: Int,
                                      fallback: SequenceFallback) -> MusicSequence {
        let mode = fallback == .none && !p.isFinite ? .invalidProfile : fallback
        let isFallback = mode != .none
        let rootContext: (root: Int, source: String)
        if isFallback {
            rootContext = fallbackRoot(for: p)
        } else {
            rootContext = (
                root: p.rootPitchClass.rawValue,
                source: p.hasReliableRoot ? "partial-color" : "seed"
            )
        }
        let root     = rootContext.root
        let scale    = isFallback ? fallbackScale(for: p) : musicScale(for: p)
        let bpm      = safeBPM(for: p.luminance)
        let harmony  = MusicHarmony(rootPitchClass: root, scale: scale, bpm: bpm)
        let octRange = isFallback ? 1 : octaveRange(for: significantToneCount)
        let gate     = isFallback
            ? fallbackGate(for: p.edgeDensity)
            : computeGate(edgeDensity: p.edgeDensity.isFinite ? p.edgeDensity : 0.12)
        let waveform: MusicWaveform = isFallback
            ? .triangle
            : ((p.hue.isFinite && p.hue >= 90 && p.hue < 300) ? .square : .triangle)
        let profile  = SoundProfile(gate: gate, octaveRange: octRange, waveform: waveform)

        let notes: [MusicNote]
        if isFallback {
            let seed = p.selectorSeed ?? 0
            let variation = Int(seed % UInt64(fallbackMotifs.count))
            notes = fallbackNotes(root: root, scale: scale, seed: seed, variation: variation)
        } else {
            var generated: [MusicNote] = []
            for row in 0..<MusicSequence.rows {
                for step in 0..<MusicSequence.steps {
                    let level = gridLevels[row * MusicSequence.steps + step]
                    guard level > 0 else { continue }
                    let offset = pitchOffset(row: row, scale: scale, octaveRange: octRange)
                    generated.append(MusicNote(
                        step: step, row: row,
                        midiNote: 60 + root + offset,
                        velocity: Float(level) / 3
                    ))
                }
            }
            notes = generated
        }

        let sequence = MusicSequence(harmony: harmony, notes: notes, soundProfile: profile)
        if isFallback {
            #if DEBUG
            let seed = p.selectorSeed ?? 0
            let variation = Int(seed % UInt64(fallbackMotifs.count))
            logFallback(
                mode,
                rootSource: rootContext.source,
                root: root,
                scale: scale,
                variation: variation,
                sequence: sequence
            )
            assertValidFallback(sequence)
            #endif
        }
        return sequence
    }

    private static func fallbackRoot(for p: PhotoMusicColorProfile) -> (root: Int, source: String) {
        if p.isFinite, p.hasReliableRoot {
            return (p.rootPitchClass.rawValue, "partial-color")
        }
        if let seed = p.selectorSeed {
            return (Int(seed % 12), "seed")
        }
        return (PitchClass.c.rawValue, "default")
    }

    private static func fallbackScale(for p: PhotoMusicColorProfile) -> MusicScale {
        guard p.saturation.isFinite else { return .majorPentatonic }
        return p.saturation >= 0.45 ? .majorPentatonic : .minorPentatonic
    }

    private static func safeBPM(for luminance: Double) -> Int {
        guard luminance.isFinite else { return 96 }
        let normalized = luminance.clamped(to: 0...1)
        return min(140, max(70, Int((70 + normalized * 70).rounded())))
    }

    private static func fallbackGate(for edgeDensity: Double) -> Double {
        guard edgeDensity.isFinite else { return 0.68 }
        return computeGate(edgeDensity: edgeDensity).clamped(to: 0.45...0.82)
    }

    private static func fallbackNotes(
        root: Int,
        scale: MusicScale,
        seed: UInt64,
        variation: Int
    ) -> [MusicNote] {
        let motif = fallbackMotifs[variation]
        let maximumDegree = scale.degrees.max() ?? 0
        let registerTarget = 68 + Int((seed >> 8) % 9)
        let rootMIDINote = (60...84)
            .filter {
                PitchClass(normalizing: $0).rawValue == root
                    && $0 + maximumDegree <= 84
            }
            .min { abs($0 - registerTarget) < abs($1 - registerTarget) }
            ?? 60 + root

        return fallbackSteps.enumerated().map { index, step in
            let degreeIndex = motif[index]
            let midiNote = rootMIDINote + scale.degrees[degreeIndex]
            return MusicNote(
                step: step,
                row: min(MusicSequence.rows - 1, max(0, MusicSequence.rows / 2 - degreeIndex)),
                midiNote: midiNote,
                velocity: [0.58, 0.66, 0.74, 0.62, 0.70][index]
            )
        }
    }

    #if DEBUG
    private static func assertValidFallback(_ sequence: MusicSequence) {
        let root = sequence.harmony.rootPitchClass
        let validNotes = sequence.notes.allSatisfy { note in
            let degree = (PitchClass(normalizing: note.midiNote).rawValue - root + 12) % 12
            return (60...84).contains(note.midiNote)
                && sequence.harmony.scale.degrees.contains(degree)
        }
        assert(sequence.notes.count == fallbackSteps.count)
        assert(Set(sequence.notes.map(\.step)).count == fallbackSteps.count)
        assert(validNotes)
        assert(sequence.notes.last.map { PitchClass(normalizing: $0.midiNote).rawValue == root } == true)
    }
    #endif

    // MARK: - Musical heuristics

    private static func musicScale(for p: PhotoMusicColorProfile) -> MusicScale {
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

    private static func stableSelectorSeed(bytes: [UInt8]) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }

    private static func selectRootPitchClass(hueBins: [Double],
                                             totalChromaticWeight: Double,
                                             seed: UInt64) -> PitchClass {
        let softenedWeights: [Double]

        if totalChromaticWeight > 0.0001 {
            let fallback = totalChromaticWeight * weightedHueFallbackRatio / 12
            softenedWeights = hueBins.map { pow($0 + fallback, weightedHueSofteningExponent) }
        } else {
            softenedWeights = Array(repeating: 1, count: 12)
        }

        let totalWeight = max(softenedWeights.reduce(0, +), 0.0001)
        let selector = Double(seed) / Double(UInt64.max)
        let target = selector * totalWeight

        var cumulative = 0.0
        for (index, weight) in softenedWeights.enumerated() {
            cumulative += weight
            if target <= cumulative {
                return PitchClass(rawValue: index) ?? .c
            }
        }

        return .b
    }
}

// MARK: - Helpers

private extension PhotoMusicColorProfile {
    var isFinite: Bool {
        hue.isFinite
            && saturation.isFinite
            && luminance.isFinite
            && hueVarianceDegrees.isFinite
            && edgeDensity.isFinite
            && rootPitchClass.rawValue >= 0
            && rootPitchClass.rawValue < 12
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
