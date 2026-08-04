import Foundation

struct JamStoryExportConfiguration: Equatable, Sendable {
    var template = StoryShareTemplate.plain
    var videoLoopCount = JamStoryVideoRenderer.defaultLoopCount

    func isValid(for snapshot: JamStoryExportSnapshot) -> Bool {
        videoLoopCount > 0
            && snapshot.bpm > 0
            && snapshot.arrangement.sequence.harmony.bpm == snapshot.bpm
            && !snapshot.arrangement.sequence.notes.isEmpty
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
