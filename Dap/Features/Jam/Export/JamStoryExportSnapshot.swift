import Foundation

enum JamStoryExportFormat: String, CaseIterable, Identifiable {
    case image
    case video

    var id: Self { self }

    var displayName: String {
        rawValue.capitalized
    }
}

enum JamStoryTemplate: String, CaseIterable, Identifiable, Sendable {
    case editorial

    var id: Self { self }

    var displayName: String {
        switch self {
        case .editorial: "Editorial"
        }
    }
}

struct JamStoryExportConfiguration: Equatable, Sendable {
    static let videoLoopOptions = [2, 4]

    var format = JamStoryExportFormat.image
    var template = JamStoryTemplate.editorial
    var videoLoopCount = 4

    func isValid(for snapshot: JamStoryExportSnapshot) -> Bool {
        switch format {
        case .image:
            return true
        case .video:
            return videoLoopCount > 0
                && snapshot.bpm > 0
                && snapshot.arrangement.sequence.harmony.bpm == snapshot.bpm
                && !snapshot.arrangement.sequence.notes.isEmpty
        }
    }
}

struct JamStoryExportProgress: Sendable {
    enum Stage: String, Sendable {
        case preparing
        case renderingFrames
        case composing
        case validating
        case complete

        var displayName: String {
            switch self {
            case .preparing: "Preparing"
            case .renderingFrames: "Rendering"
            case .composing: "Composing"
            case .validating: "Validating"
            case .complete: "Complete"
            }
        }
    }

    let stage: Stage
    let completedFrames: Int
    let totalFrames: Int
    let fractionCompleted: Double
    let elapsed: Duration
    let estimatedRemaining: Duration?
}

struct JamStoryExportSnapshot: Sendable {
    struct Photo: Identifiable, Sendable {
        let id: UUID
        let role: JamRole?
        let title: String
        let noteLabel: String
        let imageData: Data?
        let accentColor: RGBColor
    }

    let jamName: String
    let coverDescriptor: JamCoverDescriptor
    let photos: [Photo]
    let sequencerSnapshot: JamSequencerSnapshot
    let roleColors: [JamRole: RGBColor]
    let region: JamRegion
    let drumKit: MusicDrumKit
    let bpm: Int
    let arrangement: JamArrangement
    let effectSettings: JamEffectSettings
}

extension JamStoryExportSnapshot {
    static let fallbackAccent = RGBColor(red: 126, green: 134, blue: 164)
}
