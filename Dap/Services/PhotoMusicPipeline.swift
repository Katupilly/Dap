import CoreGraphics
import OSLog
import UIKit
import Vision

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
    let palette: PhotoMusicPalette
    let visualSignature: UInt64
    let hasReliableRoot: Bool
    let isPortraitDominant: Bool
}

struct PhotoPaletteColor: Sendable {
    let hue: Double
    let saturation: Double
    let luminance: Double
    let sector: Int
    let proportion: Double
}

struct PhotoMusicPalette: Sendable {
    let dominant: PhotoPaletteColor?
    let secondary: PhotoPaletteColor?
    let contrast: PhotoPaletteColor?
    let accent: PhotoPaletteColor?
    let chromaticProportion: Double
    let contrastAmount: Double

    var entries: [PhotoPaletteColor] {
        [dominant, secondary, contrast, accent].compactMap { $0 }
    }

    var diversity: Int {
        Set(entries.map(\.sector)).count
    }
}

struct PhotoMusicAnalysisOverrides: Sendable, Equatable {
    let portraitDominant: Bool?

    init(portraitDominant: Bool? = nil) {
        self.portraitDominant = portraitDominant
    }
}

enum PortraitDetectionStatus: String, Sendable {
    case detected
    case none
    case timeout
    case error
}

struct PortraitDetectionResult: Sendable {
    let faceAreaProportion: Double
    let status: PortraitDetectionStatus
}

struct PreparedPhotoInput: Sendable {
    let originalImageData: Data
    let analysisInputData: Data
    let processedPreviewData: Data
    let colorProfile: PhotoMusicColorProfile
}

private struct PhotoStepFeature: Sendable {
    let step: Int
    let row: Int
    let hueSector: Int?
    let saturation: Double
    let luminance: Double
    let localContrast: Double
}

// MARK: - PhotoMusicPipeline

/// Deterministic photo → music pipeline.
/// Receives Data, executes all heavy work off-main in a single Task.detached,
/// returns only Sendable values.
enum PhotoMusicPipeline {

    // MARK: Constants (adapted from PedalHeuristics)

    private static let analysisSide              = 64
    private static let minimumSaturationForHue   = 0.10
    private static let edgeGradientThreshold     = 0.18
    private static let lowEdgeDensity            = 0.03
    private static let highEdgeDensity           = 0.25
    private static let shortGate                 = 0.25
    private static let longGate                  = 0.98
    static let currentAlgorithmVersion = 6
    private static let portraitAreaThreshold = 0.08
    private static let proceduralRootSalt: UInt64 = 0x726F6F74_73656564
    private static let minimumChromaticProportion = 0.02
    private static let minimumLocalContrast = 0.06
    private static let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        ?? CGColorSpaceCreateDeviceRGB()
    /// Hue sectors map around the circle of fifths so neighboring visual hues
    /// remain neighboring tonal functions without a seed deciding the root.
    private static let circleOfFifths: [PitchClass] = [
        .c, .g, .d, .a, .e, .b, .fSharp,
        .cSharp, .gSharp, .dSharp, .aSharp, .f
    ]

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
        sequence: MusicSequence
    ) {
        performanceLogger.debug(
            "sequence fallback: stage=\(mode.rawValue, privacy: .public), preserved=color-profile,bpm, rootSource=\(rootSource, privacy: .public), root=\(root, privacy: .public), scale=\(scale.rawValue, privacy: .public), bpm=\(sequence.harmony.bpm, privacy: .public), steps=\(MusicSequence.steps, privacy: .public), duration=\(sequence.nominalDuration, privacy: .public)"
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

    private static func logRootSelection(
        _ result: PortraitDetectionResult,
        isPortraitDominant: Bool
    ) {
        let mode = isPortraitDominant ? "portrait" : "color"
        performanceLogger.debug(
            "root mode selected: mode=\(mode, privacy: .public), visionStatus=\(result.status.rawValue, privacy: .public)"
        )
    }
    #endif

    private enum SequenceFallback: String {
        case none
        case emptyVisualStructure
        case visualAnalysisFailed
        case invalidProfile
    }

    private static let fallbackSteps = [0, 4, 8, 12]

    // MARK: Public entry point

    static func process(
        imageData: Data,
        overrides: PhotoMusicAnalysisOverrides = .init()
    ) async throws -> ProcessedPhotoSound {
        let prepared = try await prepare(imageData: imageData, overrides: overrides)
        return try await process(prepared: prepared)
    }

    static func prepare(
        imageData: Data,
        overrides: PhotoMusicAnalysisOverrides = .init()
    ) async throws -> PreparedPhotoInput {
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
            let colorProfile = try await analyzeColor(cgImage: normalized, overrides: overrides)
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
            let stepFeatures: [PhotoStepFeature]
            let fallback: SequenceFallback

            if let normalized {
                // Musical analysis reads the normalized source, not the Cover preview.
                let toneAnalysisStart = clock.now
                do {
                    stepFeatures = try analyzeSteps(
                        cgImage: normalized,
                        palette: prepared.colorProfile.palette
                    )
                    fallback = stepFeatures.isEmpty ? .emptyVisualStructure : .none
                    #if DEBUG
                    logDuration("musical color/contrast analysis", startedAt: toneAnalysisStart, clock: clock)
                    #endif
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    stepFeatures = []
                    fallback = .visualAnalysisFailed
                    #if DEBUG
                    performanceLogger.debug(
                        "sequence fallback: stage=visual-analysis-error, error=\(String(describing: error), privacy: .public)"
                    )
                    #endif
                }
            } else {
                stepFeatures = []
                fallback = .visualAnalysisFailed
                #if DEBUG
                performanceLogger.debug(
                    "sequence fallback: stage=analysis-input-decode, preserved=color-profile, privacy=public"
                )
                #endif
            }

            let sequenceStart = clock.now
            let sequence = buildSequence(
                colorProfile: prepared.colorProfile,
                stepFeatures: stepFeatures,
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
                sequence: sequence,
                algorithmVersion: currentAlgorithmVersion,
                visualSignature: prepared.colorProfile.visualSignature
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
            space: sRGBColorSpace,
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

    // MARK: - Color analysis

    private static func analyzeColor(
        cgImage source: CGImage,
        overrides: PhotoMusicAnalysisOverrides
    ) async throws -> PhotoMusicColorProfile {
        let side = analysisSide
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(
            data: &pixels, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4,
            space: sRGBColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw PhotoMusicPipelineError.decodeFailed }
        ctx.interpolationQuality = .medium
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))

        let visualSignature = stableContentSignature(bytes: pixels)
        let portraitDetection = await detectPortrait(cgImage: source, timeout: .milliseconds(150))
        let isPortraitDominant = overrides.portraitDominant
            ?? (portraitDetection.status == .detected
                && portraitDetection.faceAreaProportion >= portraitAreaThreshold)

        #if DEBUG
        logRootSelection(portraitDetection, isPortraitDominant: isPortraitDominant)
        #endif

        var r = 0.0, g = 0.0, b = 0.0, weight = 0.0
        var hues: [Double] = []
        var gray = [Double](repeating: 0, count: side * side)
        var sectorWeights = [Double](repeating: 0, count: 12)
        var sectorLuminance = [Double](repeating: 0, count: 12)
        var sectorSaturation = [Double](repeating: 0, count: 12)
        var totalChromaticWeight = 0.0
        var luminanceMinimum = 1.0
        var luminanceMaximum = 0.0
        var luminanceDeviation = 0.0

        for i in 0..<side * side {
            guard let sample = rgbaComponents(from: pixels, at: i) else { continue }
            r += sample.red * sample.alpha
            g += sample.green * sample.alpha
            b += sample.blue * sample.alpha
            weight += sample.alpha
            let luminance = sample.luminance
            gray[i] = luminance
            luminanceMinimum = min(luminanceMinimum, luminance)
            luminanceMaximum = max(luminanceMaximum, luminance)
            let (hue, saturation) = hsb(r: sample.red, g: sample.green, b: sample.blue)
            if saturation >= minimumSaturationForHue {
                hues.append(hue)
            }

            let chromaticWeight = sample.alpha * max(0, saturation - minimumSaturationForHue)
            guard chromaticWeight > 0 else { continue }
            let sector = hueSector(for: hue)
            sectorWeights[sector] += chromaticWeight
            sectorLuminance[sector] += luminance * chromaticWeight
            sectorSaturation[sector] += saturation * chromaticWeight
            totalChromaticWeight += chromaticWeight
        }

        guard weight > 0 else {
            let rootPitchClass = isPortraitDominant
                ? PitchClass(normalizing: proceduralRootPitchClass(from: visualSignature))
                : .c
            return PhotoMusicColorProfile(hue: 0, saturation: 0, luminance: 0,
                                          hueVarianceDegrees: 0, edgeDensity: 0,
                                          rootPitchClass: rootPitchClass,
                                          palette: emptyPalette,
                                          visualSignature: visualSignature,
                                          hasReliableRoot: isPortraitDominant,
                                          isPortraitDominant: isPortraitDominant)
        }
        r /= weight
        g /= weight
        b /= weight
        let (meanHue, meanSat) = hsb(r: r, g: g, b: b)
        let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        for value in gray {
            luminanceDeviation += abs(value - lum)
        }
        let palette = makePalette(
            sectorWeights: sectorWeights,
            sectorLuminance: sectorLuminance,
            sectorSaturation: sectorSaturation,
            totalAlpha: weight,
            totalChromaticWeight: totalChromaticWeight,
            luminanceContrast: min(
                1,
                (luminanceMaximum - luminanceMinimum) * 0.55
                    + (luminanceDeviation / Double(gray.count)) * 1.2
            )
        )
        let rootPitchClass = isPortraitDominant
            ? PitchClass(normalizing: proceduralRootPitchClass(from: visualSignature))
            : colorBasedRootPitchClass(from: palette)
        return PhotoMusicColorProfile(
            hue: meanHue, saturation: meanSat, luminance: lum,
            hueVarianceDegrees: circularVarianceDegrees(hues),
            edgeDensity: sobelEdgeDensity(gray, side: side),
            rootPitchClass: rootPitchClass,
            palette: palette,
            visualSignature: visualSignature,
            hasReliableRoot: palette.dominant != nil || isPortraitDominant,
            isPortraitDominant: isPortraitDominant
        )
    }

    // MARK: - Portrait detection

    /// Runs Vision face detection and races it against a short timeout. The
    /// returned result contains only a normalized area and status.
    ///
    /// The function is `async` so callers can `await` it without a second
    /// layer of concurrency. Vision runs in an unstructured detached task so
    /// a synchronous `VNImageRequestHandler.perform` cannot keep the timeout
    /// path waiting. The late task retains its input until Vision returns, and
    /// the gate discards its result after the fallback has fired.
    private static func detectPortrait(
        cgImage: CGImage,
        timeout: Duration
    ) async -> PortraitDetectionResult {
        let timeoutResult = PortraitDetectionResult(faceAreaProportion: 0, status: .timeout)
        return await runWithTimeout(timeout: timeout, fallback: timeoutResult) {
            let request = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
            do {
                try handler.perform([request])
                let faceArea = min(1, (request.results ?? []).reduce(0) { result, observation in
                    result + observation.boundingBox.width * observation.boundingBox.height
                })
                return PortraitDetectionResult(
                    faceAreaProportion: faceArea,
                    status: request.results?.isEmpty == false ? .detected : .none
                )
            } catch {
                return PortraitDetectionResult(faceAreaProportion: 0, status: .error)
            }
        }
    }

    private static func colorBasedRootPitchClass(from palette: PhotoMusicPalette) -> PitchClass {
        guard let dominant = palette.dominant else { return .c }
        return colorBasedRootPitchClass(fromHue: dominant.hue)
    }

    static func colorBasedRootPitchClass(fromHue hue: Double) -> PitchClass {
        circleOfFifths[hueSector(for: hue)]
    }

    /// SplitMix64 finalizer used only for deterministic portrait roots.
    /// It is intentionally salted so the root seed cannot be reused as a Jam seed.
    static func splitMix64(_ value: UInt64) -> UInt64 {
        var mixed = value &+ 0x9E3779B97F4A7C15
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58476D1CE4E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D049BB133111EB
        return mixed ^ (mixed >> 31)
    }

    /// Stable portrait root derived only from normalized visual content.
    static func proceduralRootPitchClass(from visualSignature: UInt64) -> Int {
        Int(splitMix64(visualSignature ^ proceduralRootSalt) % 12)
    }

    /// Small internal seam for racing an operation against a real timeout.
    /// The operation is detached because it may contain synchronous work that
    /// does not observe task cancellation, such as Vision's `perform`. External
    /// cancellation takes the same fallback path; the detached operation may
    /// still finish later and is discarded by the gate.
    static func runWithTimeout<T: Sendable>(
        timeout: Duration,
        fallback: T,
        operation: @escaping @Sendable () async -> T
    ) async -> T {
        let gate = SingleCompletionGate()
        let cancellation = CancellationRelay()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
                let operationTask = Task.detached(priority: .userInitiated) {
                    let value = await operation()
                    guard gate.tryFire() else { return }
                    cancellation.cancel()
                    continuation.resume(returning: value)
                }

                let timeoutTask = Task.detached(priority: .userInitiated) {
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    guard gate.tryFire() else { return }
                    cancellation.cancel()
                    continuation.resume(returning: fallback)
                }

                cancellation.install {
                    operationTask.cancel()
                    timeoutTask.cancel()
                    guard gate.tryFire() else { return }
                    continuation.resume(returning: fallback)
                }
            }
        }, onCancel: {
            cancellation.cancel()
        })
    }

    /// Installs a cancellation action without racing the caller's cancellation
    /// against continuation setup. The action is always invoked outside the
    /// lock, and is released as soon as cancellation wins.
    private final class CancellationRelay: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var action: (@Sendable () -> Void)?

        func install(_ action: @escaping @Sendable () -> Void) {
            lock.lock()
            guard !cancelled else {
                lock.unlock()
                action()
                return
            }
            self.action = action
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let action = self.action
            self.action = nil
            lock.unlock()
            action?()
        }
    }

    /// Single-completion gate for the two concurrent race callers. The state
    /// is protected by the lock; callers run their continuation callback only
    /// after `tryFire()` has released it.
    final class SingleCompletionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false

        func tryFire() -> Bool {
            lock.lock()
            guard !fired else {
                lock.unlock()
                return false
            }
            fired = true
            lock.unlock()
            return true
        }
    }

    // MARK: - Spatial color/contrast analysis

    private static func analyzeSteps(
        cgImage source: CGImage,
        palette: PhotoMusicPalette
    ) throws -> [PhotoStepFeature] {
        let width = MusicSequence.steps
        let height = MusicSequence.rows
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: sRGBColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw PhotoMusicPipelineError.renderFailed }
        ctx.interpolationQuality = .medium
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

        var luminances = [Double](repeating: 0, count: width * height)
        var cells = [PhotoStepFeature?](repeating: nil, count: width * height)
        for index in 0..<(width * height) {
            guard let sample = rgbaComponents(from: pixels, at: index) else { continue }
            let (hue, saturation) = hsb(r: sample.red, g: sample.green, b: sample.blue)
            luminances[index] = sample.luminance
            cells[index] = PhotoStepFeature(
                step: index % width,
                row: index / width,
                hueSector: saturation >= minimumSaturationForHue ? hueSector(for: hue) : nil,
                saturation: saturation,
                luminance: sample.luminance,
                localContrast: 0
            )
        }

        var contrastedCells: [PhotoStepFeature] = []
        var maximumContrast = 0.0
        for index in 0..<(width * height) {
            guard let cell = cells[index] else { continue }
            let x = index % width
            let y = index / width
            var differences: [Double] = []
            for (neighborX, neighborY) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                where (0..<width).contains(neighborX) && (0..<height).contains(neighborY)
            {
                let neighborIndex = neighborY * width + neighborX
                let luminanceDifference = abs(cell.luminance - luminances[neighborIndex])
                let chromaticDifference: Double
                if let cellSector = cell.hueSector,
                   let neighborSector = cells[neighborIndex]?.hueSector
                {
                    let hueDistance = Double(circularHueDistance(cellSector, neighborSector)) / 6
                    chromaticDifference = hueDistance * min(cell.saturation, cells[neighborIndex]?.saturation ?? 0) * 0.35
                } else {
                    chromaticDifference = abs(cell.saturation - (cells[neighborIndex]?.saturation ?? 0)) * 0.35
                }
                differences.append(max(luminanceDifference, chromaticDifference))
            }
            let localContrast = differences.isEmpty
                ? 0
                : min(1, (differences.max() ?? 0) * 0.7 + (differences.reduce(0, +) / Double(differences.count)) * 0.3)
            maximumContrast = max(maximumContrast, localContrast)
            contrastedCells.append(PhotoStepFeature(
                step: cell.step,
                row: cell.row,
                hueSector: cell.hueSector,
                saturation: cell.saturation,
                luminance: cell.luminance,
                localContrast: localContrast
            ))
        }

        guard maximumContrast >= minimumLocalContrast else { return [] }
        let presenceThreshold = max(minimumLocalContrast, maximumContrast * 0.30)
        var result: [PhotoStepFeature] = []
        for step in 0..<width {
            let candidates = contrastedCells.filter { $0.step == step }
            guard let selected = candidates.max(by: { lhs, rhs in
                let lhsScore = lhs.localContrast * 1.4 + lhs.saturation * 0.12
                let rhsScore = rhs.localContrast * 1.4 + rhs.saturation * 0.12
                if lhsScore != rhsScore { return lhsScore < rhsScore }
                return lhs.row > rhs.row
            }), selected.localContrast >= presenceThreshold else { continue }
            result.append(selected)
        }

        // Palette is intentionally part of this analysis contract: color is
        // read per region below, while palette relevance controls neutral rest.
        if palette.dominant == nil {
            return result.filter { $0.localContrast >= presenceThreshold }
        }
        return result
    }

    // MARK: - Sequence builder (adapted from ImageSequenceGenerator)

    private static func buildSequence(
        colorProfile p: PhotoMusicColorProfile,
        stepFeatures: [PhotoStepFeature],
        fallback: SequenceFallback
    ) -> MusicSequence {
        let mode = fallback == .none && !p.isFinite ? .invalidProfile : fallback
        let isFallback = mode != .none
        let root = p.isFinite && p.hasReliableRoot
            ? p.rootPitchClass.rawValue
            : PitchClass.c.rawValue
        let rootSource: String
        if p.isFinite && p.hasReliableRoot {
            rootSource = p.isPortraitDominant ? "procedural-signature" : "dominant-color"
        } else {
            rootSource = "neutral-default"
        }
        let scale = isFallback ? fallbackScale(for: p) : musicScale(for: p)
        let bpm = safeBPM(for: p.luminance)
        let harmony = MusicHarmony(rootPitchClass: root, scale: scale, bpm: bpm)
        let octRange = isFallback ? 1 : octaveRange(for: stepFeatures)
        let gate = isFallback
            ? fallbackGate(for: p.edgeDensity)
            : computeGate(edgeDensity: p.edgeDensity.isFinite ? p.edgeDensity : 0.12)
        let waveform: MusicWaveform =
            p.hue.isFinite && p.hue >= 90 && p.hue < 300 ? .square : .triangle
        let profile = SoundProfile(gate: gate, octaveRange: octRange, waveform: waveform)

        let notes: [MusicNote]
        if isFallback {
            notes = fallbackNotes(root: root, scale: scale)
        } else {
            var generated: [MusicNote] = []
            var previousMIDINote: Int?
            for feature in stepFeatures {
                let degree = safeScaleDegree(for: feature, profile: p, scale: scale)
                let midiNote = melodicMIDINote(
                    root: root,
                    degree: degree,
                    feature: feature,
                    previousMIDINote: previousMIDINote
                )
                previousMIDINote = midiNote
                let accent = feature.localContrast >= 0.30 ? 1.08 : 1.0
                let velocity = Float(
                    (0.24 + feature.saturation * 0.38 + feature.localContrast * 0.50) * accent
                ).clamped(to: 0.20...0.92)
                generated.append(MusicNote(
                    step: feature.step,
                    row: feature.row,
                    midiNote: midiNote,
                    velocity: velocity
                ))
            }
            notes = generated
        }

        let sequence = MusicSequence(harmony: harmony, notes: notes, soundProfile: profile)
        if isFallback {
            #if DEBUG
            logFallback(
                mode,
                rootSource: rootSource,
                root: root,
                scale: scale,
                sequence: sequence
            )
            assertValidFallback(sequence)
            #endif
        }
        return sequence
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
        scale: MusicScale
    ) -> [MusicNote] {
        let rootMIDINote = (60...72).first {
            PitchClass(normalizing: $0).rawValue == root
        } ?? 60
        let degreeIndices = [0, min(1, scale.degrees.count - 1), min(2, scale.degrees.count - 1), 0]
        return fallbackSteps.enumerated().map { index, step in
            let degree = scale.degrees[degreeIndices[index]]
            let midiNote = rootMIDINote + degree
            return MusicNote(
                step: step,
                row: [4, 3, 2, 4][index],
                midiNote: min(84, midiNote),
                velocity: [0.42, 0.52, 0.60, 0.48][index]
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
        // Jam understands both pentatonic families without discarding degrees;
        // keep the photo scale inside that safe vocabulary.
        let energy = p.saturation * 0.55
            + p.palette.contrastAmount * 0.25
            + min(1, Double(p.palette.diversity) / 4) * 0.20
        return energy >= 0.46 ? .majorPentatonic : .minorPentatonic
    }

    private static func octaveRange(for features: [PhotoStepFeature]) -> Double {
        guard let minimumRow = features.map(\.row).min(),
              let maximumRow = features.map(\.row).max()
        else { return 1 }
        switch maximumRow - minimumRow {
        case 5...: return 2
        case 3...: return 1.5
        default: return 1
        }
    }

    private static func computeGate(edgeDensity: Double) -> Double {
        let n = ((edgeDensity - lowEdgeDensity) / (highEdgeDensity - lowEdgeDensity)).clamped(to: 0...1)
        return longGate + (shortGate - longGate) * n
    }

    private static func safeScaleDegree(
        for feature: PhotoStepFeature,
        profile: PhotoMusicColorProfile,
        scale: MusicScale
    ) -> Int {
        let rawPitchClass: Int
        if let sector = feature.hueSector {
            let localPalette = profile.palette.entries.min { lhs, rhs in
                circularHueDistance(sector, lhs.sector) < circularHueDistance(sector, rhs.sector)
            }
            let referenceSector = localPalette?.sector ?? sector
            let distance = circularHueDistance(sector, referenceSector)
            rawPitchClass = circleOfFifths[distance <= 2 ? sector : referenceSector].rawValue
        } else {
            rawPitchClass = profile.rootPitchClass.rawValue
        }

        let relative = (rawPitchClass - profile.rootPitchClass.rawValue + 12) % 12
        return scale.degrees.min { lhs, rhs in
            let lhsDistance = pitchClassDistance(relative, lhs)
            let rhsDistance = pitchClassDistance(relative, rhs)
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            return lhs < rhs
        } ?? 0
    }

    private static func melodicMIDINote(
        root: Int,
        degree: Int,
        feature: PhotoStepFeature,
        previousMIDINote: Int?
    ) -> Int {
        let target = 52
            + Int((Double(MusicSequence.rows - 1 - feature.row) / Double(MusicSequence.rows - 1) * 28).rounded())
            + Int(((feature.luminance - 0.5) * 8).rounded())
        let pitchClass = (root + degree) % 12
        let candidates = (48...96).filter {
            PitchClass(normalizing: $0).rawValue == pitchClass
        }
        let boundedCandidates: [Int]
        if let previousMIDINote {
            let nearby = candidates.filter { abs($0 - previousMIDINote) <= 12 }
            boundedCandidates = nearby.isEmpty ? candidates : nearby
        } else {
            boundedCandidates = candidates
        }
        return boundedCandidates.min { lhs, rhs in
            let lhsDistance = abs(lhs - target)
            let rhsDistance = abs(rhs - target)
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            return lhs < rhs
        } ?? 60 + root
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

    private static func rgbaComponents(
        from pixels: [UInt8],
        at index: Int
    ) -> (red: Double, green: Double, blue: Double, alpha: Double, luminance: Double)? {
        let offset = index * 4
        guard pixels.indices.contains(offset + 3) else { return nil }
        let alpha = Double(pixels[offset + 3]) / 255
        guard alpha > 0 else { return nil }
        let red = min(1, max(0, Double(pixels[offset]) / 255 / alpha))
        let green = min(1, max(0, Double(pixels[offset + 1]) / 255 / alpha))
        let blue = min(1, max(0, Double(pixels[offset + 2]) / 255 / alpha))
        return (
            red: red,
            green: green,
            blue: blue,
            alpha: alpha,
            luminance: 0.2126 * red + 0.7152 * green + 0.0722 * blue
        )
    }

    private static let emptyPalette = PhotoMusicPalette(
        dominant: nil,
        secondary: nil,
        contrast: nil,
        accent: nil,
        chromaticProportion: 0,
        contrastAmount: 0
    )

    private static func makePalette(
        sectorWeights: [Double],
        sectorLuminance: [Double],
        sectorSaturation: [Double],
        totalAlpha: Double,
        totalChromaticWeight: Double,
        luminanceContrast: Double
    ) -> PhotoMusicPalette {
        let chromaticProportion = (totalChromaticWeight / max(totalAlpha, 1e-6)).clamped(to: 0...1)
        guard chromaticProportion >= minimumChromaticProportion,
              totalChromaticWeight > 0
        else {
            return PhotoMusicPalette(
                dominant: nil,
                secondary: nil,
                contrast: nil,
                accent: nil,
                chromaticProportion: chromaticProportion,
                contrastAmount: luminanceContrast
            )
        }

        let rankedSectors = sectorWeights.indices
            .filter { sectorWeights[$0] > totalChromaticWeight * 0.03 }
            .sorted {
                if sectorWeights[$0] != sectorWeights[$1] {
                    return sectorWeights[$0] > sectorWeights[$1]
                }
                return $0 < $1
            }
        guard let dominantSector = rankedSectors.first else { return emptyPalette }

        func color(for sector: Int) -> PhotoPaletteColor {
            let weight = sectorWeights[sector]
            return PhotoPaletteColor(
                hue: (Double(sector) + 0.5) * 30,
                saturation: sectorSaturation[sector] / max(weight, 1e-6),
                luminance: sectorLuminance[sector] / max(weight, 1e-6),
                sector: sector,
                proportion: weight / totalChromaticWeight
            )
        }

        let dominant = color(for: dominantSector)
        let secondarySector = rankedSectors.first { $0 != dominantSector }
        let secondary = secondarySector.map(color)
        let contrastSector = rankedSectors
            .filter { $0 != dominantSector && $0 != secondarySector }
            .max {
                abs(color(for: $0).luminance - dominant.luminance) * sectorWeights[$0]
                    < abs(color(for: $1).luminance - dominant.luminance) * sectorWeights[$1]
            }
        let contrast = contrastSector.map(color)
        let accentSector = rankedSectors
            .filter { $0 != dominantSector && $0 != secondarySector && $0 != contrastSector }
            .max {
                sectorSaturation[$0] < sectorSaturation[$1]
            }
        let accent = accentSector.map(color)

        return PhotoMusicPalette(
            dominant: dominant,
            secondary: secondary,
            contrast: contrast,
            accent: accent,
            chromaticProportion: chromaticProportion,
            contrastAmount: luminanceContrast
        )
    }

    private static func hueSector(for hue: Double) -> Int {
        min(11, max(0, Int(hue.truncatingRemainder(dividingBy: 360) / 30)))
    }

    private static func circularHueDistance(_ lhs: Int, _ rhs: Int) -> Int {
        let direct = abs(lhs - rhs)
        return min(direct, 12 - direct)
    }

    private static func pitchClassDistance(_ lhs: Int, _ rhs: Int) -> Int {
        let direct = abs(lhs - rhs)
        return min(direct, 12 - direct)
    }

    /// Stable signature of the normalized 64×64 visual raster. It is the only
    /// input to the procedural portrait root and remains independent of Cover,
    /// sequence construction, and Jam variation selection.
    private static func stableContentSignature(bytes: [UInt8]) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in bytes {
            hash ^= UInt64(byte >> 4)
            hash &*= 0x100000001b3
        }
        return hash
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

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
