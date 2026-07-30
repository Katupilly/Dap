import Foundation
import Vision
import FoundationModels
import OSLog

// MARK: - Visual label (Sendable transport value)

struct VisualLabel: Sendable {
    let name: String
    let confidence: Float
}

// MARK: - Musical context (Sendable snapshot for cross-boundary transport)

struct MusicalContext: Sendable {
    let rootName: String
    let scaleName: String
    let bpm: Int
    let waveform: String
    let luminanceHint: String?  // "bright" | "mellow" | nil
}

// MARK: - Generated metadata (guided generation target)

@Generable
struct GeneratedPhotoMetadata {
    @Guide(description: "A playful, evocative name in English using one to four words.")
    var name: String

    @Guide(description: "One short playful sentence describing the connection between the image and its sound.")
    var description: String
}

// MARK: - PhotoMetadataGenerator

enum PhotoMetadataGenerationResult: Sendable {
    case generated(GeneratedPhotoMetadata)
    case unavailable
    case empty
    case failed
    case cancelled
}

enum PhotoMetadataGenerator {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Dap",
        category: "PhotoMetadata"
    )

    // MARK: Public entry point

    /// Runs Vision classification off-main, then asks Foundation Models for
    /// a name and description.
    static func generate(
        imageData: Data,
        musicalContext: MusicalContext
    ) async -> PhotoMetadataGenerationResult {
        logger.log("Starting metadata generation")
        guard !Task.isCancelled else {
            logger.log("Metadata generation cancelled before start")
            return .cancelled
        }

        let labels = await classifyImage(imageData: imageData)
        guard !Task.isCancelled else {
            logger.log("Metadata generation cancelled after classification")
            return .cancelled
        }

        return await generateMetadata(labels: labels, context: musicalContext)
    }

    // MARK: - Vision classification

    private static func classifyImage(imageData: Data) async -> [VisualLabel] {
        // Run entirely inside a detached task so Vision never touches MainActor.
        await Task.detached(priority: .userInitiated) {
            guard let cgImage = makeCGImage(from: imageData) else { return [] }

            let request = VNClassifyImageRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
                guard let observations = request.results else {
                    return []
                }
                return observations
                    .filter { $0.confidence >= 0.12 }           // discard very low confidence
                    .sorted { $0.confidence > $1.confidence }   // highest first
                    .prefix(5)                                  // at most five labels
                    .map { VisualLabel(name: $0.identifier, confidence: $0.confidence) }
            } catch {
                logger.error("Vision classification failed: \(error.localizedDescription, privacy: .public)")
                return []
            }
        }.value
    }

    // MARK: - Foundation Models generation

    private static func generateMetadata(
        labels: [VisualLabel],
        context: MusicalContext
    ) async -> PhotoMetadataGenerationResult {
        let model = SystemLanguageModel.default

        switch model.availability {
        case .available:
            break
        case .unavailable:
            logger.log("Metadata generation unavailable")
            return .unavailable
        @unknown default:
            logger.log("Metadata generation unavailable due to unknown model state")
            return .unavailable
        }

        let prompt = buildPrompt(labels: labels, context: context)

        // New session per photo — prevents context contamination across imports.
        let session = LanguageModelSession(
            instructions: Instructions("""
                You name musical photographs for a playful creative app.
                Use the visual labels and musical properties provided.
                Be evocative but concrete.
                Do not mention technical image analysis.
                Do not claim to see objects that are not present.
                Do not explain your reasoning.
                """)
        )

        do {
            let response = try await session.respond(
                to: prompt,
                generating: GeneratedPhotoMetadata.self
            )
            guard !Task.isCancelled else {
                logger.log("Metadata generation cancelled after model response")
                return .cancelled
            }
            guard let metadata = sanitize(response.content) else {
                logger.log("Metadata generation completed without a usable name")
                return .empty
            }
            logger.log("Metadata generation completed successfully")
            return .generated(metadata)
        } catch is CancellationError {
            logger.log("Metadata generation cancelled during model response")
            return .cancelled
        } catch {
            logger.error("Metadata generation failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    // MARK: - Prompt builder

    private static func buildPrompt(
        labels: [VisualLabel],
        context: MusicalContext
    ) -> String {
        var parts: [String] = []

        if labels.isEmpty {
            parts.append("Visual content: unclassified")
        } else {
            let labelList = labels.map { $0.name }.joined(separator: ", ")
            parts.append("Visual labels: \(labelList)")
        }

        parts.append("Root: \(context.rootName)")
        parts.append("Scale: \(context.scaleName)")
        parts.append("BPM: \(context.bpm)")
        parts.append("Sound: \(context.waveform)")

        if let hint = context.luminanceHint {
            parts.append("Mood: \(hint)")
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - Sanitization

    private static func sanitize(_ raw: GeneratedPhotoMetadata) -> GeneratedPhotoMetadata? {
        let name = clean(raw.name, maxLength: 40)
        let desc = clean(raw.description, maxLength: 140)

        guard !name.isEmpty, !desc.isEmpty else { return nil }

        return GeneratedPhotoMetadata(name: name, description: desc)
    }

    private static func clean(_ text: String, maxLength: Int) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove wrapping quotes
        if s.count >= 2,
           (s.hasPrefix("\"") && s.hasSuffix("\"")) ||
           (s.hasPrefix("'")  && s.hasSuffix("'")) {
            s = String(s.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Remove markdown bold/italic markers
        s = s.replacingOccurrences(of: "**", with: "")
        s = s.replacingOccurrences(of: "*",  with: "")
        s = s.replacingOccurrences(of: "__", with: "")

        // Truncate to reasonable length
        if s.count > maxLength {
            s = String(s.prefix(maxLength))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    // MARK: - CGImage helper (runs inside detached task, no UIImage)

    private static func makeCGImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

// MARK: - MusicalContext convenience init

extension MusicalContext {
    init(sound: PhotoSound) {
        let harmony = sound.sequence.harmony
        let profile = sound.sequence.soundProfile

        let luminance: String?
        switch profile.waveform {
        case .square:   luminance = "bright"
        case .triangle: luminance = "mellow"
        }

        self.init(
            rootName: harmony.rootName,
            scaleName: harmony.scale.displayName,
            bpm: harmony.bpm,
            waveform: profile.waveform.rawValue,
            luminanceHint: luminance
        )
    }
}
